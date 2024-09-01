#include "arp.h"

#include "assert.h"
#include "ethernet.h"
#include "logger.h"
#include "mem.h"
#include "net_utils.h"

#define MAX_ARP_CACHE_SIZE 512
#define CACHE_RESERVED_ENTRIES 1

static ArpCache arp_cache[MAX_ARP_CACHE_SIZE] = { {.mac = { 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF }, .ip = {255, 255, 255, 255}} };
static uint16_t arp_cache_size = CACHE_RESERVED_ENTRIES;

typedef enum ArpHardwareType {
    ArpEthernetType = 0x1,
    ArpReservedType = 0xFFFF
} ArpHardwareType;

typedef enum ArpProtocolType {
    ArpIPv4Type = 0x0800,
} ArpProtocolType;

typedef enum ArpHardwareLength {
    ArpMacLength = 6,
} ArpHardwareLength;

typedef enum ArpProtocolLength {
    ArpIPv4Length = 4,
} ArpProtocolLength;

typedef enum ArpOperationType {
    ArpRequestOperation = 1,
    ArpReplyOperation = 2
} ArpOperationType;

// TODO: maybe add mutex
static void add_to_arp_cache(const uint8_t mac[MAC_ADDRESS_SIZE], const uint8_t ip[IPV4_ADDRESS_SIZE]) {
    kassert(mac != NULL && ip != NULL);

    if (arp_cache_lookup(ip) != NULL) return;

    memcpy(mac, arp_cache[arp_cache_size].mac, MAC_ADDRESS_SIZE);
    memcpy(ip, arp_cache[arp_cache_size].ip, IPV4_ADDRESS_SIZE);
    arp_cache_size = (arp_cache_size + CACHE_RESERVED_ENTRIES) % MAX_ARP_CACHE_SIZE ?
        (arp_cache_size + CACHE_RESERVED_ENTRIES) % MAX_ARP_CACHE_SIZE : CACHE_RESERVED_ENTRIES;
}

static bool_t arp_send_reply(const NetworkDevice* const network_device, const ArpPacket* const arp_request_packet) {
    kassert(arp_request_packet != NULL && network_device != NULL);

    ArpPacket arp_packet;

    arp_packet.hardware_type = flip_short(ArpEthernetType);
    arp_packet.protocol_type = flip_short(ArpIPv4Type);
    arp_packet.hardware_size = MAC_ADDRESS_SIZE;
    arp_packet.protocol_size = IPV4_ADDRESS_SIZE;
    arp_packet.opcode = flip_short(ArpReplyOperation);
    memcpy(network_device->mac_address, arp_packet.source_hardware_addr, MAC_ADDRESS_SIZE);
    memcpy(client_ipv4, arp_packet.source_protocol_addr, IPV4_ADDRESS_SIZE);
    memcpy(arp_request_packet->source_hardware_addr, arp_packet.destination_hardware_addr, MAC_ADDRESS_SIZE);
    memcpy(arp_request_packet->source_protocol_addr, arp_packet.destination_protocol_addr, IPV4_ADDRESS_SIZE);

    const bool_t status = ethernet_transmit_frame(network_device, arp_packet.destination_hardware_addr,
                                                    EthernetFrameTypeArp, &arp_packet, sizeof(ArpPacket));

    return status;
}

ArpCache* arp_cache_lookup(const uint8_t ip[IPV4_ADDRESS_SIZE]) {
    kassert(ip != NULL);

    for (uint16_t i = 0; i < arp_cache_size; ++i) {
        if (memcmp(ip, arp_cache[i].ip, IPV4_ADDRESS_SIZE) == 0) return &arp_cache[i];
    }

    return NULL;
}

bool_t arp_send_request(const NetworkDevice* const network_device, const uint8_t destination_ip[IPV4_ADDRESS_SIZE]) {
    kassert(network_device != NULL);

    ArpPacket arp_packet;

    arp_packet.hardware_type = flip_short(ArpEthernetType);
    arp_packet.protocol_type = flip_short(ArpIPv4Type);
    arp_packet.hardware_size = MAC_ADDRESS_SIZE;
    arp_packet.protocol_size = IPV4_ADDRESS_SIZE;
    arp_packet.opcode = flip_short(ArpRequestOperation);
    memcpy(network_device->mac_address, arp_packet.source_hardware_addr, MAC_ADDRESS_SIZE);
    memcpy(client_ipv4, arp_packet.source_protocol_addr, IPV4_ADDRESS_SIZE);
    memset(arp_packet.destination_hardware_addr, MAC_ADDRESS_SIZE, 0);
    memcpy(destination_ip, arp_packet.destination_protocol_addr, IPV4_ADDRESS_SIZE);

    const bool_t status = ethernet_transmit_frame(network_device, broadcast_mac, EthernetFrameTypeArp, &arp_packet, sizeof(ArpPacket));

    return status;
}

void arp_handle_packet(const NetworkDevice* const network_device, const ArpPacket* const arp_packet) {
    kassert(network_device != NULL && arp_packet != NULL);

    const uint16_t operation_type = flip_short(arp_packet->opcode);

    switch (operation_type) {
    case ArpRequestOperation:
        if (memcmp(arp_packet->destination_protocol_addr, client_ipv4, IPV4_ADDRESS_SIZE) != 0) return;
        
        arp_send_reply(network_device, arp_packet);

        if (arp_cache_lookup(arp_packet->source_protocol_addr) == NULL) {
            arp_send_request(network_device, arp_packet->source_protocol_addr);
        }


        break;
    case ArpReplyOperation:
        add_to_arp_cache(arp_packet->source_hardware_addr, arp_packet->source_protocol_addr);

        break;
    default:
        break;
    }
}
