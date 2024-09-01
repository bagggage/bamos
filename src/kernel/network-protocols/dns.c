#include "dns.h"

#include "assert.h"
#include "mem.h"
#include "udp.h"
#include "net_utils.h"

#define LOG_PREFIX "DNS: "

#define DOMAIN_SIZE 255

#define DOMAIN_AS_REF_MASK 0xC0

typedef enum DnsType {
    DnsTypeA = 1,
    DnsTypeCname = 5,
    DnsTypeAAAA = 28,
    DnsTypeHttps = 65,
    DnsTypeUri = 256,
} DnsType;

typedef enum DnsClassCode {
    DnsClassCodeIn = 1,
    DnsClassCodeCS,
    DnsClassCodeCh,
    DnsClassCodeHs,
} DnsClassCode;

// First field is a variable length name
typedef struct DnsQuery {
    uint16_t type;
    uint16_t class_code;
} ATTR_PACKED DnsQuery;

// First field is a variable length name
typedef struct DnsAnswer {
    uint16_t type;
    uint16_t class_code;
    uint32_t ttl;
    uint16_t data_size;
    uint8_t data [];
} ATTR_PACKED DnsAnswer;

static uint8_t get_first_subdomain_size(const char* const domain) {
    kassert(domain);

    uint8_t size = 0;
    while (domain[size] != NULL) {
        if (domain[size] == '.') return size;
        ++size;
    }

    return size;
}

static size_t get_subdomain_count(const char* const domain) {
    kassert(domain != NULL);

    size_t count = 0;
    for (size_t i = 0; domain[i] != NULL; ++i) {
        if (domain[i] == '.') count++;
    }

    return ++count;
}

// Should call free on domain when unused
static char* const get_domain_name(const uint8_t* const packet, const size_t offset) {
    kassert(packet != NULL);

    char* domain = kcalloc(DOMAIN_SIZE);

    const uint8_t* const domain_start = packet + offset;

    size_t domain_offset = 0;
    size_t data_offset = 1;
    size_t subdomain_size_offset = 0;
    while (domain_start[subdomain_size_offset] != '\0') {
        size_t size_to_copy = domain_start[subdomain_size_offset];
        memcpy(domain_start + data_offset, domain + domain_offset, size_to_copy);

        subdomain_size_offset += size_to_copy + 1;
        data_offset += size_to_copy + 1;
        domain_offset += size_to_copy;

        domain[domain_offset++] = '.';
    }

    domain[domain_offset - 1] = '\0';

    return domain;

}
void dns_handle_packet(const NetworkDevice* const network_device, const DnsHeader* const dns_header) {
    kassert(network_device != NULL && dns_header != NULL);

    DnsAnswer* dns_answer = NULL;

    const char* domain = get_domain_name(dns_header, offsetof(DnsHeader, data));

    size_t answer_offset = (strlen(domain) + 2) + sizeof(DnsQuery);
    const uint16_t total_answers = flip_short(dns_header->total_answers);
    for (uint16_t i = 0; i < total_answers; ++i) {
        uint8_t* domain_in_answer = dns_header->data + answer_offset;
        if (domain_in_answer[0] == DOMAIN_AS_REF_MASK) {
            dns_answer = domain_in_answer + 2;
            answer_offset += 2;
        }
        else {
            dns_answer = domain_in_answer + (strlen(domain) + 2);
            answer_offset += (strlen(domain) + 2);
        }

        if (dns_answer->class_code != flip_short(DnsClassCodeIn)) {
            kfree(domain);
            return;
        }

        const uint16_t answer_type = flip_short(dns_answer->type);

        switch (answer_type) {
        case DnsTypeA:
            kernel_msg("domain %s has ip %d.%d.%d.%d\n", domain, dns_answer->data[0], dns_answer->data[1], dns_answer->data[2], dns_answer->data[3]);
            break;
        case DnsTypeCname:
            const char* cname_domain = get_domain_name(dns_answer, offsetof(DnsAnswer, data));
            kernel_msg("Domain %s has CNAME %s\n", domain, cname_domain);

            kfree(domain);
            domain = cname_domain;
            break;
        default:
            break;
        }

        answer_offset += flip_short(dns_answer->data_size) + sizeof(DnsAnswer);
    }

    kfree(domain);
}

bool_t dns_send_query(const NetworkDevice* const network_device, const char* const domain) {
    kassert(network_device != NULL && domain != NULL);

    static uint16_t current_id = 0;

    const size_t subdomain_count = get_subdomain_count(domain);
    const size_t domain_size = strlen(domain) + 1;
    const size_t dns_header_size = sizeof(DnsHeader) + sizeof(DnsQuery) + domain_size + 1;
    DnsHeader* dns_header = kcalloc(dns_header_size);

    if (dns_header == NULL) {
        kernel_error(LOG_PREFIX "cant allocate memory for dns header");
        return FALSE;
    }

    dns_header->id = current_id;
    dns_header->total_questions = flip_short(1);
    dns_header->total_answers = 0;
    dns_header->total_additional_records = 0;
    dns_header->total_authority_records = 0;
    
    uint16_t u16_flags = 0;
    memset(&dns_header->flags, sizeof(dns_header->flags), 0);
    dns_header->flags.rd = 1;
    memcpy(&dns_header->flags, &u16_flags, sizeof(dns_header->flags));
    u16_flags = flip_short(u16_flags);
    memcpy(&u16_flags, &dns_header->flags, sizeof(u16_flags));

    DnsQuery dns_question;
    dns_question.type = flip_short(DnsTypeA);
    dns_question.class_code = flip_short(DnsClassCodeIn);

    size_t offset = 0;
    size_t current_offset = 0;
    while (current_offset < domain_size) {
        uint8_t subdomain_size = get_first_subdomain_size(domain + current_offset);

        dns_header->data[offset++] = subdomain_size;
        memcpy(domain + current_offset, dns_header->data + offset, subdomain_size);
        offset += subdomain_size;
        current_offset += subdomain_size + 1;
    }
    dns_header->data[offset++] = 0;
    memcpy(&dns_question, dns_header->data + offset, sizeof(dns_question));

    bool_t status = udp_send_packet(network_device, dns_servers_ipv4[0], IPV4_ADDRESS_SIZE,
                                    UdpDnsPort, UdpDnsPort, dns_header_size, dns_header);

    if (status) ++current_id;

    return status;
}