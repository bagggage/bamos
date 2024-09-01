#include "udp.h"

#include "assert.h"
#include "dhcp.h"
#include "ip.h"
#include "logger.h"
#include "mem.h"
#include "net_utils.h"
#include "dns.h"

#define LOG_PREFIX "UDP: "

void udp_handle_packet(const NetworkDevice* const network_device, const UdpPacket* const udp_packet) {
    kassert(network_device != NULL && udp_packet != NULL);

    const uint16_t destination_port = flip_short(udp_packet->destination_port);

    switch (destination_port) {
    case UdpDnsPort:
        dns_handle_packet(network_device, udp_packet->data);
        break;
    case UdpDhcpClientPort:
        dhcp_handle_packet(network_device, udp_packet->data);
        break;
    default:
        break;
    }
}

bool_t udp_send_packet(const NetworkDevice* const network_device,
                       const uint8_t destination_ip[IP_MAX_ADDRESS_SIZE], const uint8_t destination_ip_size,
                       const uint16_t source_port, const uint16_t destination_port,
                       const uint16_t data_size, const void* const data) {
    kassert(network_device != NULL && data != NULL);

    static UdpPacket* udp_packet = NULL;

    if (udp_packet == NULL) {
        udp_packet = (UdpPacket*)kmalloc(sizeof(UdpPacket) + UINT16_MAX);

        if (udp_packet == NULL) {
            kernel_error(LOG_PREFIX"cant allocate memory for udp buffer\n");
            return FALSE;
        }
    }

    //TODO add mutex
    udp_packet->source_port = flip_short(source_port);
    udp_packet->destination_port = flip_short(destination_port);
    udp_packet->length = flip_short(sizeof(UdpPacket) + data_size);
    udp_packet->checksum = 0; // In ipv4 packet checksum could be 0
    memcpy(data, udp_packet->data, data_size);

    bool_t status = FALSE;
    switch (destination_ip_size) {
    case IPV4_ADDRESS_SIZE:
        status = ipv4_send_packet(network_device, IpProtocolUdpType, destination_ip, sizeof(UdpPacket) + data_size, udp_packet);
        break;
    case IPV6_ADDRESS_SIZE:
        break;
    default:
        break;
    }

    return status;
}