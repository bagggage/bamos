#pragma once 

#include "definitions.h"

#include "dev/network.h"

typedef struct ArpPacket {
    uint16_t hardware_type;
    uint16_t protocol_type;
    uint8_t  hardware_size;
    uint8_t  protocol_size;
    uint16_t opcode;
    uint8_t  source_hardware_addr[MAC_ADDRESS_SIZE];
    uint8_t  source_protocol_addr[IPV4_ADDRESS_SIZE];
    uint8_t  destination_hardware_addr[MAC_ADDRESS_SIZE];
    uint8_t  destination_protocol_addr[IPV4_ADDRESS_SIZE];
} ATTR_PACKED ArpPacket;

typedef struct ArpCache {
    uint8_t mac[MAC_ADDRESS_SIZE];
    uint8_t ip[IPV4_ADDRESS_SIZE];
} ArpCache;

// If the entry is not found `NULL` is returned, otherwise return `pointer to the cache entry`.
// This entry should be used in read-only mode or copied to another variable for modification,
// otherwise the arp cache entry will be overwritten.
ArpCache* arp_cache_lookup(const uint8_t ip[IPV4_ADDRESS_SIZE]);

bool_t arp_send_request(const NetworkDevice* const network_device, const uint8_t destination_ip[IPV4_ADDRESS_SIZE]);

void arp_handle_packet(const NetworkDevice* const network_device, const ArpPacket* const arp_packet);