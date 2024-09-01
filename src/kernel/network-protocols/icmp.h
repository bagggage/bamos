#pragma once

#include "definitions.h"

#include "dev/network.h"

typedef struct IcmpV4Packet {
    uint8_t type;
    uint8_t code;
    uint16_t checksum;
    uint32_t content;
    uint8_t data []; // max size 576
} ATTR_PACKED IcmpV4Packet;

void icmpv4_handle_packet(const NetworkDevice* const network_device, const IcmpV4Packet* const icmp_packet, const uint16_t total_icmp_size,
                          const uint8_t source_ip[IPV4_ADDRESS_SIZE]);

bool_t icmpv4_send_echo_request(const NetworkDevice* const network_device, const uint8_t destination_ip[IPV4_ADDRESS_SIZE],
                                const uint8_t data_size, const uint8_t* const data);

    bool_t icmpv4_send_timestamp_request(const NetworkDevice* const network_device, const uint8_t destination_ip[IPV4_ADDRESS_SIZE]);