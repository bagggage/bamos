#pragma once

#include "definitions.h"

#include "dev/network.h"

typedef enum UdpPortType {
    UdpDnsPort = 53,
    UdpDhcpServerPort = 67,
    UdpDhcpClientPort = 68,
} UdpPortType;

typedef struct UdpPacket {
    uint16_t source_port;
    uint16_t destination_port;
    uint16_t length;
    uint16_t checksum;
    uint8_t data []; // max size 65,527
} ATTR_PACKED UdpPacket;

void udp_handle_packet(const NetworkDevice* const network_device, const UdpPacket* const udp_packet);

bool_t udp_send_packet(const NetworkDevice* const network_device,
                       const uint8_t destination_ip[IP_MAX_ADDRESS_SIZE], const uint8_t destination_ip_size,
                       const uint16_t source_port, const uint16_t destination_port,
                       const uint16_t data_size, const void* const data);