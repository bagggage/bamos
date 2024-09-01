#include "dhcp.h"

#include "arp.h"
#include "assert.h"
#include "mem.h"
#include "net_utils.h"
#include "udp.h"
#include "utils.h"

#define LOG_PREFIX "DHCP: "

#define BAMOS_XID 0x32285252
#define SERVER_NAME "Bamos"

#define MAGIC_NUMBER 0x63825363

static uint32_t lease_time_in_seconds = 0;

static uint8_t dhcp_server_ipv4[IPV4_ADDRESS_SIZE] = { 0, 0, 0, 0 };

static bool_t is_ipv4_assigned = FALSE;

typedef enum DhcpPacketType {
    DhcpPacketTypeRequest = 1,
    DhcpPacketTypeReply,
} DhcpPacketType;

typedef enum DhcpHardwareType {
    DhcpHardwareTypeEthernet = 1,
} DhcpHardwareType;

typedef enum DhcpMessageType {
    DhcpMessageTypeUnknow = 0,
    DhcpMessageTypeDiscover,
    DhcpMessageTypeOffer,
    DhcpMessageTypeRequest,
    DhcpMessageTypeDecline,
    DhcpMessageTypeAck,
    DhcpMessageTypeNack,
    DhcpMessageTypeRelease,
    DhcpMessageTypeInform,
} DhcpMessageType;

typedef enum DhcpOptionOperationId {
    DhcpOperationUnknown = 0,
    DhcpOperationRoutersIpAddresses = 3,
    DhcpOperationDnsServersIpAddresses = 6,
    DhcpOperationRequestedIpAddress = 50,
    DhcpOperationLeaseTime = 51,
    DhcpOperationIdTypeOfPacket = 53,
    DhcpOperationDhcpIpAddress = 54,
    DhcpOperationIdEndOfOptions = 255,
} DhcpOptionOperationId;

static size_t get_options_count(const DhcpV4Options** const options) {
    kassert(options != NULL);

    size_t count = 0;
    while (options[count++]->operation_id != DhcpOperationIdEndOfOptions);

    return count;
}

static void free_options(const DhcpV4Options** const options) {
    kassert(options != NULL);

    size_t options_count = get_options_count(options);
    for (size_t i = 0; i < options_count; ++i) kfree(options[i]);
}

static DhcpV4Options* get_dhcpv4_data_by_option_id(const DhcpV4Packet* const dhcp_packet, const DhcpOptionOperationId id) {
    kassert(dhcp_packet != NULL);

    const DhcpV4Options* options = dhcp_packet->options;

    while (options->operation_id != DhcpOperationIdEndOfOptions) {
        if (options->operation_id == id) return options;

        options = (((uint8_t*)options) + offsetof(DhcpV4Options, data) + options->data_size);
    }

    return NULL;
}

static DhcpV4Options* make_dhcpv4_options(const DhcpOptionOperationId id, const uint8_t data_size, const uint8_t* const data) {
    DhcpV4Options* new_option = (DhcpV4Options*)kmalloc(sizeof(DhcpV4Options) + data_size);

    if (new_option == NULL) return NULL;

    new_option->operation_id = id;

    if (id == DhcpOperationIdEndOfOptions) return new_option;

    new_option->data_size = data_size;
    memcpy(data, new_option->data, new_option->data_size);

    return new_option;
}

static DhcpV4Packet make_dhcpv4_request_packet(const NetworkDevice* const network_device,
                                           const DhcpHardwareType hardware_type,
                                           const uint8_t client_ip[IPV4_ADDRESS_SIZE],
                                           const DhcpV4Options** const options) {
    kassert(network_device != NULL && options != NULL);

    DhcpV4Packet dhcp_packet;

    dhcp_packet.opcode = DhcpPacketTypeRequest;
    dhcp_packet.hardware_type = hardware_type;
    dhcp_packet.hardware_len = MAC_ADDRESS_SIZE;
    dhcp_packet.hops = 0;
    dhcp_packet.xid = flip_int(BAMOS_XID);
    dhcp_packet.seconds = 0;
    dhcp_packet.flags = 0;
    dhcp_packet.magic_cookie = flip_int(MAGIC_NUMBER);
    memcpy(client_ip, dhcp_packet.client_ip, IPV4_ADDRESS_SIZE);
    memset(dhcp_packet.your_ip, sizeof(dhcp_packet.your_ip), 0);
    memset(dhcp_packet.server_ip, sizeof(dhcp_packet.server_ip), 0);
    memset(dhcp_packet.gateway_ip, sizeof(dhcp_packet.gateway_ip), 0);
    memset(dhcp_packet.gateway_ip, sizeof(dhcp_packet.gateway_ip), 0);
    memset(dhcp_packet.client_hardware_address, sizeof(dhcp_packet.client_hardware_address), 0);
    memset(dhcp_packet.server_name, sizeof(dhcp_packet.server_name), 0);
    memcpy(network_device->mac_address, dhcp_packet.client_hardware_address, MAC_ADDRESS_SIZE);
    memcpy(SERVER_NAME, dhcp_packet.server_name, strlen(SERVER_NAME));
    memset(dhcp_packet.options, sizeof(dhcp_packet.options) / sizeof(dhcp_packet.options[0]), 0);

    size_t total_options_size = 0;
    const size_t total_options_count = get_options_count(options);
    for (size_t i = 0; i < total_options_count; ++i) {
        memcpy(options[i], dhcp_packet.options + total_options_size, offsetof(DhcpV4Options, data) + options[i]->data_size);
        total_options_size += offsetof(DhcpV4Options, data) + options[i]->data_size;
    }

    return dhcp_packet;
}

static bool_t dhcp_sendv4_request_packet(const NetworkDevice* const network_device,
                                const uint8_t ip_to_request[IPV4_ADDRESS_SIZE],
                                const uint8_t server_ip[IPV4_ADDRESS_SIZE]) {
    kassert(network_device != NULL);

    DhcpV4Options** options = (DhcpV4Options**)kmalloc(4 * sizeof(DhcpV4Options*));

    if (options == NULL) {
        kernel_error(LOG_PREFIX "cannot allocate memory for an option\n");
        return FALSE;
    }

    const DhcpMessageType message_type = DhcpMessageTypeRequest;
    options[0] = make_dhcpv4_options(DhcpOperationIdTypeOfPacket, 1, &message_type);
    options[1] = make_dhcpv4_options(DhcpOperationRequestedIpAddress, IPV4_ADDRESS_SIZE, ip_to_request);
    options[2] = make_dhcpv4_options(DhcpOperationDhcpIpAddress, IPV4_ADDRESS_SIZE, server_ip);
    options[3] = make_dhcpv4_options(DhcpOperationIdEndOfOptions, 0, 0);

    const uint8_t ip[IPV4_ADDRESS_SIZE] = { 0,0,0,0 };
    DhcpV4Packet dhcp_packet = make_dhcpv4_request_packet(network_device, DhcpHardwareTypeEthernet, ip, options);

    free_options(options);
    kfree(options);

    const bool_t status = udp_send_packet(network_device, broadcast_ipv4, IPV4_ADDRESS_SIZE,
                                        UdpDhcpClientPort, UdpDhcpServerPort, sizeof(dhcp_packet), &dhcp_packet);

    return status;
}

// This packet should be send after 'lease_time_in_seconds' / 2
static bool_t dhcpv4_continue_lease(const NetworkDevice* const network_device) {
    kassert(network_device != NULL);

    DhcpV4Options** options = (DhcpV4Options**)kmalloc(2 * sizeof(DhcpV4Options*));

    if (options == NULL) return FALSE;

    const DhcpMessageType message_type = DhcpMessageTypeRequest;
    options[0] = make_dhcpv4_options(DhcpOperationIdTypeOfPacket, 1, &message_type);
    options[1] = make_dhcpv4_options(DhcpOperationIdEndOfOptions, 0, 0);

    DhcpV4Packet dhcp_packet = make_dhcpv4_request_packet(network_device, DhcpHardwareTypeEthernet, client_ipv4, options);

    free_options(options);
    kfree(options);

    //dhcp server ip should be changed to broadcast ip after 'lease_time_in_seconds' / (7/8)
    const bool_t status = udp_send_packet(network_device, dhcp_server_ipv4, IPV4_ADDRESS_SIZE,
                                        UdpDhcpClientPort, UdpDhcpServerPort, sizeof(dhcp_packet), &dhcp_packet);

    return status;
}

// This packet should be send after when OS is shutting down
static bool_t dhcpv4_release(const NetworkDevice* const network_device) {
    kassert(network_device != NULL);

    DhcpV4Options** options = (DhcpV4Options**)kmalloc(2 * sizeof(DhcpV4Options*));

    if (options == NULL) return FALSE;

    const DhcpMessageType message_type = DhcpMessageTypeRelease;
    options[0] = make_dhcpv4_options(DhcpOperationIdTypeOfPacket, 1, &message_type);
    options[1] = make_dhcpv4_options(DhcpOperationIdEndOfOptions, 0, 0);

    DhcpV4Packet dhcp_packet = make_dhcpv4_request_packet(network_device, DhcpHardwareTypeEthernet, client_ipv4, options);

    free_options(options);
    kfree(options);

    const bool_t status = udp_send_packet(network_device, dhcp_server_ipv4, IPV4_ADDRESS_SIZE,
                                        UdpDhcpClientPort, UdpDhcpServerPort, sizeof(dhcp_packet), &dhcp_packet);

    if (status) is_ipv4_assigned = FALSE;

    return status;
}

void dhcp_handle_packet(const NetworkDevice* const network_device, const DhcpV4Packet* const dhcp_packet) {
    kassert(network_device != NULL && dhcp_packet != NULL);

    if (dhcp_packet->opcode == DhcpPacketTypeReply) {
        DhcpV4Options* option = get_dhcpv4_data_by_option_id(dhcp_packet, DhcpOperationIdTypeOfPacket);

        DhcpMessageType message_type = DhcpMessageTypeUnknow;

        memcpy(option->data, &message_type, option->data_size);

        switch (message_type) {
        case DhcpMessageTypeOffer:
            kernel_msg("Dhcp offer\n");

            option = get_dhcpv4_data_by_option_id(dhcp_packet, DhcpOperationDhcpIpAddress);

            memcpy(option->data, dhcp_server_ipv4, option->data_size);

            dhcp_sendv4_request_packet(network_device, dhcp_packet->your_ip, dhcp_server_ipv4);

            break;
        case DhcpMessageTypeAck:
            kernel_msg("Dhcp ack\n");

            if (!is_ipv4_assigned) {
                memcpy(dhcp_packet->your_ip, client_ipv4, IPV4_ADDRESS_SIZE);
                kernel_msg("My ip %d.%d.%d.%d\n", client_ipv4[0], client_ipv4[1], client_ipv4[2], client_ipv4[3]);

                option = get_dhcpv4_data_by_option_id(dhcp_packet, DhcpOperationDnsServersIpAddresses);
                dns_servers_count = option->data_size / IPV4_ADDRESS_SIZE;
                dns_servers_ipv4 = kmalloc(dns_servers_count * sizeof(dns_servers_ipv4[0]));

                for (size_t i = 0; i < dns_servers_count; ++i) {
                    dns_servers_ipv4[i] = kmalloc(IPV4_ADDRESS_SIZE);
                    memcpy(option->data + (i * IPV4_ADDRESS_SIZE), dns_servers_ipv4[i], IPV4_ADDRESS_SIZE);
                    arp_send_request(network_device, dns_servers_ipv4[i]);
                }

                option = get_dhcpv4_data_by_option_id(dhcp_packet, DhcpOperationRoutersIpAddresses);
                routers_count = option->data_size / IPV4_ADDRESS_SIZE;
                routers_ipv4 = kmalloc(routers_count * sizeof(routers_ipv4[0]));

                for (size_t i = 0; i < routers_count; ++i) {
                    routers_ipv4[i] = kmalloc(IPV4_ADDRESS_SIZE);
                    memcpy(option->data + (i * IPV4_ADDRESS_SIZE), routers_ipv4[i], IPV4_ADDRESS_SIZE);
                    arp_send_request(network_device, routers_ipv4[i]);
                }

                is_ipv4_assigned = TRUE;
            }

            option = get_dhcpv4_data_by_option_id(dhcp_packet, DhcpOperationLeaseTime);
            memcpy(option->data, &lease_time_in_seconds, option->data_size);

            break;
        case DhcpMessageTypeNack:
            kernel_msg("Dhcp nack\n");

            dhcpv4_send_discover_packet(network_device);

            break;
        case DhcpMessageTypeDecline:
            kernel_msg("Dhcp decline\n");

            dhcpv4_send_discover_packet(network_device);

            break;
        default:
            kernel_msg("dhcp unhandled option %d\n", message_type);
            break;
        }
    }
}

bool_t dhcpv4_send_discover_packet(const NetworkDevice* const network_device) {
    kassert(network_device != NULL);

    DhcpV4Options** options = (DhcpV4Options**)kmalloc(2 * sizeof(DhcpV4Options*));

    if (options == NULL) return FALSE;

    const DhcpMessageType message_type = DhcpMessageTypeDiscover;
    options[0] = make_dhcpv4_options(DhcpOperationIdTypeOfPacket, 1, &message_type);
    options[1] = make_dhcpv4_options(DhcpOperationIdEndOfOptions, 0, 0);

    const uint8_t ip[IPV4_ADDRESS_SIZE] = { 0,0,0,0 };
    DhcpV4Packet dhcp_packet = make_dhcpv4_request_packet(network_device, DhcpHardwareTypeEthernet, ip, options);

    free_options(options);
    kfree(options);

    const bool_t status = udp_send_packet(network_device, broadcast_ipv4, IPV4_ADDRESS_SIZE,
                                        UdpDhcpClientPort, UdpDhcpServerPort, sizeof(dhcp_packet), &dhcp_packet);

    return status;
}
