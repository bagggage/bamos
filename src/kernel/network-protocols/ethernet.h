#pragma once

#include "definitions.h"

#include "dev/network.h"

#define ETHERNET_MAX_PAYLOAD_SIZE 1500

typedef enum EthernetFrameType {
    EthernetFrameTypeArp = 0x0806,
    EthernetFrameTypeIpv4 = 0x0800,
} FrameType;

typedef struct EthernetFrame {
    uint8_t destination_mac[MAC_ADDRESS_SIZE];
    uint8_t source_mac[MAC_ADDRESS_SIZE];
    uint16_t type;
    uint8_t data [];      // min size 46, max 1500 bytes
} ATTR_PACKED EthernetFrame;

void ethernet_handle_frame(const NetworkDevice* const network_device, const EthernetFrame* const frame, const uint32_t frame_size);
bool_t ethernet_transmit_frame(const NetworkDevice* const network_device, const uint8_t destination_mac[MAC_ADDRESS_SIZE],
                             const uint16_t protocol, uint8_t* const data, const uint32_t data_size);