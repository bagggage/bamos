#pragma once

#include "definitions.h"

#include "dev/network.h"

typedef struct DhcpV4Packet {
    uint8_t opcode;
    uint8_t hardware_type;
    uint8_t hardware_len;
    uint8_t hops;
    uint32_t xid;
    uint16_t seconds;
    uint16_t flags;
    uint8_t client_ip[IPV4_ADDRESS_SIZE];
    uint8_t your_ip[IPV4_ADDRESS_SIZE];
    uint8_t server_ip[IPV4_ADDRESS_SIZE];
    uint8_t gateway_ip[IPV4_ADDRESS_SIZE];
    uint8_t client_hardware_address[16];
    uint8_t server_name[64];
    uint8_t boot_file_name[128];
    uint32_t magic_cookie;
    uint8_t options[336];
} ATTR_PACKED DhcpV4Packet;

typedef struct DhcpV4Options {
    uint8_t operation_id;
    uint8_t data_size;
    uint8_t data [];  // 255 is max size
} ATTR_PACKED DhcpV4Options;

void dhcp_handle_packet(const NetworkDevice* const network_device, const DhcpV4Packet* const dhcp_packet);

bool_t dhcpv4_send_discover_packet(const NetworkDevice* const network_device);