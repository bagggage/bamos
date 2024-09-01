#include "icmp.h"

#include "assert.h"
#include "ip.h"
#include "mem.h"
#include "net_utils.h"

#include "dev/clock.h"

#define LOG_PREFIX "ICMP: "

#define ICMP_MAX_DATA_SIZE 255

#define TIMESTAMP_SIZE 4

extern size_t delay_before_transmit;

static IcmpV4Packet* global_icmpv4_packet = NULL;

typedef enum IcmpPacketType {
    IcmpEchoReply = 0,
    IcmpDestinationUnreachable = 3,
    IcmpSourceQuench,
    IcmpRedirectMessage,
    IcmpEchoRequest = 8,
    IcmpRouterAdvertisement,
    IcmpRouterSolicitation,
    IcmpTimeExceeded,
    IcmpBadIpHeader,
    IcmpTimestampRequest,
    IcmpTimestampReply,
} IcmpPacketType;

static bool_t allocate_icmpv4() {
    if (global_icmpv4_packet == NULL) {
        global_icmpv4_packet = kmalloc(sizeof(IcmpV4Packet) + ICMP_MAX_DATA_SIZE);

        if (global_icmpv4_packet == NULL) {
            kernel_error(LOG_PREFIX "cant allocate memory for icmp v4 packet\n");

            return FALSE;
        }
    }

    return TRUE;
}

static inline uint32_t get_current_timestamp() {
    ClockDevice* clock_device = (ClockDevice*)dev_find_by_type(NULL, DEV_CLOCK);
    return (get_current_posix_time(clock_device) % 86400) * 1000;
}

static bool_t icmpv4_send_echo_reply(const NetworkDevice* const network_device, const IcmpV4Packet* const request_packet,
                             const uint8_t total_request_packet_size, const uint8_t destination_ip[IPV4_ADDRESS_SIZE]) {
    kassert(network_device != NULL && request_packet != NULL);

    if (allocate_icmpv4() == FALSE) return FALSE;

    global_icmpv4_packet->type = IcmpEchoReply;
    global_icmpv4_packet->code = 0;
    memcpy(&request_packet->content, &global_icmpv4_packet->content, sizeof(request_packet->content));

    memcpy(request_packet->data, global_icmpv4_packet->data, total_request_packet_size - sizeof(IcmpV4Packet));
    global_icmpv4_packet->checksum = 0;
    global_icmpv4_packet->checksum = flip_short(calculate_internet_checksum(global_icmpv4_packet, total_request_packet_size));

    bool_t status = ipv4_send_packet(network_device, IpProtocolIcmpType, destination_ip, total_request_packet_size, global_icmpv4_packet);

    return status;
}

static bool_t icmpv4_send_timestamp_reply(const NetworkDevice* const network_device, const IcmpV4Packet* const request_packet,
                                          const uint8_t total_request_packet_size, const uint8_t destination_ip[IPV4_ADDRESS_SIZE],
                                          const uint32_t receive_timestamp) {
    kassert(network_device != NULL && request_packet != NULL);

    if (allocate_icmpv4() == FALSE) return FALSE;

    global_icmpv4_packet->type = IcmpTimestampReply;
    global_icmpv4_packet->code = 0;
    memcpy(&request_packet->content, &global_icmpv4_packet->content, sizeof(request_packet->content));

    memcpy(request_packet->data, global_icmpv4_packet->data, TIMESTAMP_SIZE);
    memcpy(&receive_timestamp, global_icmpv4_packet->data + TIMESTAMP_SIZE, TIMESTAMP_SIZE);

    const uint32_t transmit_timestamp = get_current_timestamp();
    memcpy(&transmit_timestamp, global_icmpv4_packet->data + 2 * TIMESTAMP_SIZE, TIMESTAMP_SIZE);

    global_icmpv4_packet->checksum = 0;
    global_icmpv4_packet->checksum = flip_short(calculate_internet_checksum(global_icmpv4_packet, total_request_packet_size));

    bool_t status = ipv4_send_packet(network_device, IpProtocolIcmpType, destination_ip, total_request_packet_size, global_icmpv4_packet);

    return status;
}

void icmpv4_handle_packet(const NetworkDevice* const network_device, const IcmpV4Packet* const icmp_packet, const uint16_t total_icmp_size,
                          const uint8_t source_ip[IPV4_ADDRESS_SIZE]) {
    kassert(network_device != NULL && icmp_packet != NULL);

    switch (icmp_packet->type) {
    case IcmpEchoReply:
        kernel_msg(LOG_PREFIX "echo reply data %s\n", icmp_packet->data);
        break;
    case IcmpDestinationUnreachable:
        kernel_msg(LOG_PREFIX "Destination unreachable, code %d\n", icmp_packet->code);
        kernel_msg("Ip header and first 8 bytes of datagram:\n");

        IpV4Header* ipv4_packet = icmp_packet->data;
        raw_hexdump(ipv4_packet, (ipv4_packet->ihl * IP_HEADER_OCTETS_COUNT) + 8); // 8 bytes are send over icmp

        break;
    case IcmpSourceQuench:
        kernel_msg(LOG_PREFIX "source quench\n");
        kernel_msg(LOG_PREFIX "added 0.5 sec before transmit\n");

        delay_before_transmit += 500;

        break;
    case IcmpRedirectMessage:
        kernel_msg(LOG_PREFIX "redirect code %d\n", icmp_packet->code);
        break;
    case IcmpEchoRequest:
        kernel_msg(LOG_PREFIX "echo request\n");

        icmpv4_send_echo_reply(network_device, icmp_packet, total_icmp_size, source_ip);

        break;
    case IcmpRouterAdvertisement:
        kernel_msg(LOG_PREFIX "router advertisement\n");
        break;
    case IcmpRouterSolicitation:
        kernel_msg(LOG_PREFIX "router solicitation\n");
        break;
    case IcmpTimeExceeded:
        kernel_msg(LOG_PREFIX "time exceeded code %d\n", icmp_packet->code);
        break;
    case IcmpBadIpHeader:
        kernel_msg(LOG_PREFIX "bad ip header code %d\n", icmp_packet->code);

        ipv4_packet = icmp_packet->data;
        raw_hexdump(ipv4_packet, (ipv4_packet->ihl * IP_HEADER_OCTETS_COUNT) + 8); // 8 bytes are send over icmp

        break;
    case IcmpTimestampRequest:
        const uint32_t receive_timestamp = get_current_timestamp();

        icmpv4_send_timestamp_reply(network_device, icmp_packet, total_icmp_size, source_ip, receive_timestamp);

        break;
    case IcmpTimestampReply:
        kernel_msg(LOG_PREFIX "timestamp reply\n");
        kernel_msg(LOG_PREFIX "originate timestamp %d\n", (uint32_t)icmp_packet->data);
        kernel_msg(LOG_PREFIX "receive timestamp %d\n", (uint32_t)(icmp_packet->data + sizeof(uint32_t)));
        kernel_msg(LOG_PREFIX "transmit timestamp %d\n", (uint32_t)(icmp_packet->data + 2 * sizeof(uint32_t)));

        break;
    default:
        kernel_msg(LOG_PREFIX "unhandled packet type %d\n", icmp_packet->type);
        break;
    }
}

bool_t icmpv4_send_echo_request(const NetworkDevice* const network_device, const uint8_t destination_ip[IPV4_ADDRESS_SIZE],
                                const uint8_t data_size, const uint8_t* const data) {
    kassert(network_device != NULL && data != NULL);

    if (allocate_icmpv4() == FALSE) return FALSE;

    const uint16_t id = 1010;
    static uint16_t sequence_number = 0;

    global_icmpv4_packet->type = IcmpEchoRequest;
    global_icmpv4_packet->code = 0;
    global_icmpv4_packet->content = flip_int((id << 16) + sequence_number);
    memcpy(data, global_icmpv4_packet->data, data_size);
    global_icmpv4_packet->checksum = 0;
    global_icmpv4_packet->checksum = flip_short(calculate_internet_checksum(global_icmpv4_packet, sizeof(global_icmpv4_packet) + data_size));

    bool_t status = ipv4_send_packet(network_device, IpProtocolIcmpType, destination_ip,
                                    sizeof(IcmpV4Packet) + data_size, global_icmpv4_packet);

    if (status == TRUE) ++sequence_number;

    return status;
}

bool_t icmpv4_send_timestamp_request(const NetworkDevice* const network_device, const uint8_t destination_ip[IPV4_ADDRESS_SIZE]) {
    kassert(network_device != NULL);

    if (allocate_icmpv4() == FALSE) return FALSE;

    const uint16_t id = 1011;
    static uint16_t sequence_number = 0;

    global_icmpv4_packet->type = IcmpTimestampRequest;
    global_icmpv4_packet->code = 0;
    global_icmpv4_packet->content = flip_int((id << 16) + sequence_number);

    const uint32_t originate_timestamp = get_current_timestamp();
    memcpy(&originate_timestamp, global_icmpv4_packet->data, TIMESTAMP_SIZE);
    memset(global_icmpv4_packet->data + TIMESTAMP_SIZE, 2 * TIMESTAMP_SIZE, 0);

    global_icmpv4_packet->checksum = 0;
    global_icmpv4_packet->checksum = flip_short(calculate_internet_checksum(global_icmpv4_packet,
        sizeof(global_icmpv4_packet) + 3 * TIMESTAMP_SIZE));

    bool_t status = ipv4_send_packet(network_device, IpProtocolIcmpType, destination_ip,
                                     sizeof(global_icmpv4_packet) + 3 * TIMESTAMP_SIZE, global_icmpv4_packet);

    if (status == TRUE) ++sequence_number;

    return status;
}