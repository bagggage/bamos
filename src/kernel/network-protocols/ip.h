#pragma once 

#include "definitions.h"

#include "dev/network.h"

#define IP_HEADER_OCTETS_COUNT 4

typedef enum IpHeaderVersionType {
    IPV4_TYPE = 4,
    IPV6_TYPE = 6,
} IpHeaderVersionType;

typedef enum IpProtocolType {
    IpProtocolIcmpType = 1,
    IpProtocolTcpType = 6,
    IpProtocolUdpType = 17,
} IpProtocolType;

// The IPV4 header also has the last argument `option field`, but it's an option. therefore it is not included in this structure
// If you need to get this field, you need to calculate ihl * 4. This is the real size of the header. If value if more than 20
// than the header has the option field. The max size of the option field is 40 bytes.
typedef struct IpV4Header {
    uint8_t ihl : 4;
    uint8_t version : 4;
    uint8_t tos;
    uint16_t length;
    uint16_t id;
    union {
        struct {
            uint16_t fragment_offset : 13;
            uint16_t flags : 3;
        };
        uint16_t flags_and_offset;
    };
    uint8_t ttl;
    uint8_t protocol;
    uint16_t header_checksum;
    uint8_t source_ip[IPV4_ADDRESS_SIZE];
    uint8_t destination_ip[IPV4_ADDRESS_SIZE];
} ATTR_PACKED IpV4Header;

typedef struct IpV4Options {
    uint8_t copied : 1;
    uint8_t class : 2;
    uint8_t option_type : 5;
    uint8_t size;
    uint8_t data [];
} ATTR_PACKED IpV4Options;

typedef union IpPacket {
    IpV4Header ipv4;
    // TODO ipv6
} IpPacket;

uint16_t calculate_internet_checksum(const uint8_t* const header, uint16_t header_size);

void ip_handle_packet(const NetworkDevice* const network_device, IpPacket* const ip_packet);

bool_t ipv4_send_packet(const NetworkDevice* const network_device, const uint16_t protocol, const uint8_t destination_ip[IPV4_ADDRESS_SIZE],
                        const uint16_t data_size, const void* const data);