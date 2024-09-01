#pragma once 

#include "definitions.h"

#include "dev/network.h"

typedef struct DnsFlags {
#ifdef IS_LITTLE_ENDIAN
    uint16_t rcode : 4;
    uint16_t z : 3;
    uint16_t ra : 1;
    uint16_t rd : 1;
    uint16_t tc : 1;
    uint16_t aa : 1;
    uint16_t opcode : 4;
    uint16_t qr : 1;
#else
    uint16_t qr : 1;
    uint16_t opcode : 4;
    uint16_t aa : 1;
    uint16_t tc : 1;
    uint16_t rd : 1;
    uint16_t ra : 1;
    uint16_t z : 3;
    uint16_t rcode : 4;
#endif 
} ATTR_PACKED DnsFlags;

/*  +---------------------+
    |      DNS Header     |
    +---------------------+
    |  Question Section   |
    +---------------------+
    | QNAME   | QTYPE     |
    |---------|-----------|
    | QCLASS  |           |
    +---------------------+
    |   Answer Section    |
    +---------------------+
    | NAME    | TYPE      |
    |---------|-----------|
    | CLASS   | TTL       |
    |---------|-----------|
    |       RDATA         |
    +---------------------+
    |  Authority Section  |
    +---------------------+
    | NAME    | TYPE      |
    |---------|-----------|
    | CLASS   | TTL       |
    |---------|-----------|
    |       RDATA         |
    +---------------------+
    | Additional Section  |
    +---------------------+
    | NAME    | TYPE      |
    |---------|-----------|
    | CLASS   | TTL       |
    |---------|-----------|
    |       RDATA         |
    +---------------------+
*/

typedef struct DnsHeader {
    uint16_t id;
    union {
        DnsFlags flags;
        uint16_t u16_flags;
    };
    uint16_t total_questions;
    uint16_t total_answers;
    uint16_t total_authority_records;
    uint16_t total_additional_records;
    uint8_t data [];
} ATTR_PACKED DnsHeader;

void dns_handle_packet(const NetworkDevice* const network_device, const DnsHeader* const dns_header);

bool_t dns_send_query(const NetworkDevice* const network_device, const char* const domain);