#include "ip.h"

#include "arp.h"
#include "assert.h"
#include "ethernet.h"
#include "icmp.h"
#include "mem.h"
#include "net_utils.h"
#include "tcp.h"
#include "udp.h"
#include "utils.h"

#include "utils/list.h"

#define LOG_PREFIX "IP: "

#define MIN_IPV4_HEADER_SIZE 20

#define FRAGMENT_OFFSET_MULTIPLIER 8

typedef enum IpFragmentationFlags {
    IpFragmentationFlagDoNothing = 0,
    IpFragmentationFlagDoNotFragment = 2,
    IpFragmentationFlagMoreFragments = 4,
} IpFragmentationFlags;

typedef struct FragmentNode {
    uint16_t id;
    IpFragmentationFlags fragment_type;
    uint16_t fragment_offset;
    uint16_t data_size;
    uint8_t* data;

    LIST_STRUCT_IMPL(FragmentNode);
} FragmentNode;

typedef struct FragmentsList {
    FragmentNode nodes;
} FragmentsList;

static FragmentsList global_fragment_list;

// TODO: maybe add mutex
static void add_to_fragment_list(const IpV4Header* const ipv4_header, const uint16_t data_size, const void* const data) {
    kassert(ipv4_header != NULL && data != NULL);

    FragmentNode* new_node = (FragmentNode*)kcalloc(sizeof(FragmentNode));

    if (new_node == NULL) {
        kernel_error(LOG_PREFIX"Cant allocate memory for ip fragment node\n");
        return;
    }

    new_node->id = ipv4_header->id;
    new_node->fragment_offset = ipv4_header->fragment_offset;
    new_node->data_size = data_size;
    new_node->fragment_type = ipv4_header->flags;
    new_node->data = (uint8_t*)kcalloc(data_size);

    if (new_node->data == NULL) {
        kernel_error(LOG_PREFIX"Cant allocate memory for data field of ip fragment node\n");
        kfree(new_node);
        return;
    }

    memcpy(data, new_node->data, data_size);

    if (global_fragment_list.nodes.next == NULL) {
        global_fragment_list.nodes.next = new_node;
        global_fragment_list.nodes.prev = new_node;
    }
    else {
        new_node->prev = global_fragment_list.nodes.prev;

        global_fragment_list.nodes.prev->next = new_node;
        global_fragment_list.nodes.prev = new_node;
    }
}

// TODO: maybe add mutex
static void remove_from_fragment_list(FragmentNode* fragment_node) {
    kassert(fragment_node != NULL);

    if (global_fragment_list.nodes.next == global_fragment_list.nodes.prev) {
        global_fragment_list.nodes.next = NULL;
        global_fragment_list.nodes.prev = NULL;
    }
    else if ((void*)fragment_node == (void*)global_fragment_list.nodes.next) {
        fragment_node->next->prev = NULL;
        global_fragment_list.nodes.next = (void*)fragment_node->next;
    }
    else if ((void*)fragment_node == (void*)global_fragment_list.nodes.prev) {
        fragment_node->prev->next = NULL;
        global_fragment_list.nodes.prev = (void*)fragment_node->prev;
    }
    else {
        fragment_node->next->prev = fragment_node->prev;
        fragment_node->prev->next = fragment_node->next;
    }

    kfree((void*)fragment_node->data);
    kfree((void*)fragment_node);
}

static bool_t is_all_fragments_in_list(const uint16_t fragments_id) {
    FragmentNode* head = global_fragment_list.nodes.next;

    if (head == NULL) return FALSE;

    uint16_t total_fragment_offset = 0;
    int16_t expected_fragment_offset = -1;
    while (head != NULL) {
        if (head->id == fragments_id && head->fragment_type == IpFragmentationFlagMoreFragments) {
            total_fragment_offset += head->fragment_offset;
        }
        else if (head->id == fragments_id && head->fragment_type == IpFragmentationFlagDoNothing) { // last fragment
            expected_fragment_offset = head->fragment_offset;
        }

        head = head->next;
    }

    return expected_fragment_offset == total_fragment_offset;
}

// TODO: maybe add mutex
static uint8_t* assemble_ipv4_fragmented_packet(const IpV4Header* const ip_packet, const uint16_t data_size,
                                                const void* const last_fragment_data) {
    kassert(ip_packet != NULL);

    kernel_msg(LOG_PREFIX"assemble function called\n");

    FragmentNode* head = global_fragment_list.nodes.next;

    if (head == NULL) return NULL;

    uint8_t* data = kmalloc((ip_packet->fragment_offset * FRAGMENT_OFFSET_MULTIPLIER) + data_size);

    if (data == NULL) {
        kernel_error(LOG_PREFIX"Cant allocate memory for data packet\n");
        return NULL;
    }

    uint16_t current_fragment_offset = 0;
    while (TRUE) {
        if (head->id == ip_packet->id && head->fragment_offset == current_fragment_offset) {
            memcpy(head->data, data + (current_fragment_offset * FRAGMENT_OFFSET_MULTIPLIER), head->data_size);

            current_fragment_offset += head->data_size / FRAGMENT_OFFSET_MULTIPLIER;

            remove_from_fragment_list(head);
            head = NULL;
        }

        if (current_fragment_offset == ip_packet->fragment_offset) {
            memcpy(last_fragment_data, data + (current_fragment_offset * FRAGMENT_OFFSET_MULTIPLIER), data_size);
            break;
        }

        if (head == NULL || head->next == NULL)     head = global_fragment_list.nodes.next;
        else                                        head = head->next;
    }

    return data;
}

static bool_t disassemble_and_send_ipv4_packets(const NetworkDevice* const network_device, const uint8_t destination_mac[MAC_ADDRESS_SIZE],
                                                IpV4Header* const ip_packet, uint16_t total_data_size, const void* const data) {
    kassert(network_device != NULL && destination_mac != NULL &&
            ip_packet != NULL && data != NULL);

    kernel_msg(LOG_PREFIX"disassemble function called\n");

    // TODO: maybe add mutex
    static uint16_t current_id = 1;

    bool_t status = FALSE;

    uint16_t current_fragment_offset = 0;
    while (total_data_size > ETHERNET_MAX_PAYLOAD_SIZE - MIN_IPV4_HEADER_SIZE) {
        const uint16_t data_size_to_transfer = (total_data_size + MIN_IPV4_HEADER_SIZE > ETHERNET_MAX_PAYLOAD_SIZE) ?
            ETHERNET_MAX_PAYLOAD_SIZE - MIN_IPV4_HEADER_SIZE : total_data_size;

        ip_packet->length = flip_short(data_size_to_transfer + MIN_IPV4_HEADER_SIZE);
        ip_packet->id = current_id;
        ip_packet->flags = IpFragmentationFlagMoreFragments;
        ip_packet->fragment_offset = current_fragment_offset;
        ip_packet->flags_and_offset = flip_short(ip_packet->flags_and_offset);
        ip_packet->header_checksum = flip_short(calculate_internet_checksum(ip_packet, MIN_IPV4_HEADER_SIZE));

        memcpy(data, ((uint8_t*)ip_packet) + MIN_IPV4_HEADER_SIZE, data_size_to_transfer);

        current_fragment_offset += data_size_to_transfer / FRAGMENT_OFFSET_MULTIPLIER;

        total_data_size -= data_size_to_transfer;

        status = ethernet_transmit_frame(network_device, destination_mac, EthernetFrameTypeIpv4, ip_packet, data_size_to_transfer + MIN_IPV4_HEADER_SIZE);

        if (status == FALSE) return status;
    }

    ip_packet->length = flip_short(total_data_size + MIN_IPV4_HEADER_SIZE);
    ip_packet->id = current_id;
    ip_packet->flags = IpFragmentationFlagDoNothing;
    ip_packet->fragment_offset = current_fragment_offset;
    ip_packet->flags_and_offset = flip_short(ip_packet->flags_and_offset);
    ip_packet->header_checksum = flip_short(calculate_internet_checksum(ip_packet, MIN_IPV4_HEADER_SIZE));

    memcpy(data, ((uint8_t*)ip_packet) + MIN_IPV4_HEADER_SIZE, total_data_size);

    ++current_id;

    status = ethernet_transmit_frame(network_device, destination_mac, EthernetFrameTypeIpv4, ip_packet, total_data_size + MIN_IPV4_HEADER_SIZE);

    return status;
}

static void handle_ipv4_options(const IpV4Options* const options, const size_t options_size) {
    kassert(options != NULL);

    kernel_msg(LOG_PREFIX"handle option function is called\n");
}

static void ipv4_handle_tos(const IpV4Header* const ip_packet) {
    kassert(ip_packet != NULL);

    kernel_msg(LOG_PREFIX"handle tos function is called\n");
}

uint16_t calculate_internet_checksum(const uint8_t* const header, uint16_t header_size) {
    kassert(header != NULL);

    uint32_t sum = 0;
    const uint16_t* ptr = (uint16_t*)header;

    uint16_t i = 0;
    for (;i < header_size / 2; ++i) {
        sum += flip_short(ptr[i]);
    }

    if (header_size % 2 != 0) {
        sum += ((uint8_t)ptr[i]) << 8;
    }

    while (sum >> 16)
        sum = (sum & 0xffff) + (sum >> 16);

    return ~sum;
}

void ip_handle_packet(const NetworkDevice* const network_device, IpPacket* const ip_packet) {
    kassert(network_device != NULL && ip_packet != NULL);

    switch (ip_packet->ipv4.version)
    {
    case IPV4_TYPE:
        if (memcmp(ip_packet->ipv4.destination_ip, client_ipv4, IPV4_ADDRESS_SIZE) != 0) return;

        const uint8_t header_size = ip_packet->ipv4.ihl * IP_HEADER_OCTETS_COUNT;

        uint16_t data_size = flip_short(ip_packet->ipv4.length) - header_size;
        void* data = ((uint8_t*)ip_packet) + header_size;
        bool_t free_data_flag = FALSE; // When packet is assembled, we should call free on data

        ip_packet->ipv4.flags_and_offset = flip_short(ip_packet->ipv4.flags_and_offset);

        if (ip_packet->ipv4.flags == IpFragmentationFlagMoreFragments ||
           (ip_packet->ipv4.flags == IpFragmentationFlagDoNothing && ip_packet->ipv4.fragment_offset != 0)) {
            add_to_fragment_list(&ip_packet->ipv4, data_size, data);

            if (!is_all_fragments_in_list(ip_packet->ipv4.id)) return;

            data = assemble_ipv4_fragmented_packet(&ip_packet->ipv4, data_size, data);
            data_size += (ip_packet->ipv4.fragment_offset * FRAGMENT_OFFSET_MULTIPLIER);
            free_data_flag = TRUE;
        }

        if (header_size != MIN_IPV4_HEADER_SIZE) { // If header has an options field
            const uint8_t options_size = header_size - MIN_IPV4_HEADER_SIZE;

            IpV4Options* options = (IpV4Options*)(((uint8_t*)ip_packet) + MIN_IPV4_HEADER_SIZE);

            handle_ipv4_options(options, options_size);
        }

        if (ip_packet->ipv4.tos != 0) ipv4_handle_tos(&ip_packet->ipv4);

        switch (ip_packet->ipv4.protocol) {
        case IpProtocolIcmpType:
            icmpv4_handle_packet(network_device, data, data_size, ip_packet->ipv4.source_ip);
            break;
        case IpProtocolTcpType:
            tcp_handle_packet(network_device, data, ip_packet->ipv4.source_ip, ip_packet->ipv4.destination_ip, data_size);
            break;
        case IpProtocolUdpType:
            udp_handle_packet(network_device, data);
            break;
        default:
            break;
        }

        if (free_data_flag) kfree(data);

        break;
    case IPV6_TYPE:
        break;
    default:
        break;
    }
}

bool_t ipv4_send_packet(const NetworkDevice* const network_device, const uint16_t protocol, const uint8_t destination_ip[IPV4_ADDRESS_SIZE],
                        const uint16_t data_size, const void* const data) {
    kassert(network_device != NULL && destination_ip != NULL && data != NULL);

    // TODO: maybe remove static
    static IpV4Header* ipv4_header = NULL;

    if (ipv4_header == NULL) {
        ipv4_header = kmalloc(MIN_IPV4_HEADER_SIZE + UINT16_MAX);

        if (ipv4_header == NULL) {
            kernel_error(LOG_PREFIX"cant allocate memory for ipv4 header\n");
            return FALSE;
        }
    }

    ipv4_header->version = IPV4_TYPE;
    ipv4_header->ihl = MIN_IPV4_HEADER_SIZE / IP_HEADER_OCTETS_COUNT;
    ipv4_header->tos = 0;
    ipv4_header->length = flip_short(data_size + MIN_IPV4_HEADER_SIZE);
    ipv4_header->id = 0;
    ipv4_header->flags = IpFragmentationFlagDoNothing;
    ipv4_header->flags_and_offset = flip_short(ipv4_header->flags_and_offset);
    ipv4_header->ttl = 64; // 64 is a recommended value according to the standard
    ipv4_header->protocol = protocol;
    ipv4_header->header_checksum = 0; // set to 0 to calculate checksum
    memcpy(client_ipv4, ipv4_header->source_ip, IPV4_ADDRESS_SIZE);
    memcpy(destination_ip, ipv4_header->destination_ip, IPV4_ADDRESS_SIZE);
    memcpy(data, ((uint8_t*)ipv4_header) + MIN_IPV4_HEADER_SIZE, data_size);
    ipv4_header->header_checksum = flip_short(calculate_internet_checksum(ipv4_header, MIN_IPV4_HEADER_SIZE));

    // Another thread should listen the receive queue, otherwise no connection will be establish
    ArpCache* entry = NULL;
    uint8_t tries_to_send = UINT8_MAX;
    while (((entry = arp_cache_lookup(ipv4_header->destination_ip)) == NULL) && tries_to_send != 0) {
        arp_send_request(network_device, ipv4_header->destination_ip);
        --tries_to_send;
        wait(50);
    }

    if (tries_to_send == 0) {
        kernel_warn(LOG_PREFIX "arp cache lookup timeout\n");
        return FALSE;
    }

    bool_t status = FALSE;
    if (data_size + MIN_IPV4_HEADER_SIZE > ETHERNET_MAX_PAYLOAD_SIZE) {
        status = disassemble_and_send_ipv4_packets(network_device, entry->mac, ipv4_header, data_size, data);
    }
    else {
        status = ethernet_transmit_frame(network_device, entry->mac, EthernetFrameTypeIpv4, ipv4_header, data_size + MIN_IPV4_HEADER_SIZE);
    }

    return status;
}
