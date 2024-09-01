#include "ethernet.h"

#include "arp.h"
#include "assert.h"
#include "ip.h"
#include "logger.h"
#include "mem.h"
#include "net_utils.h"

#define LOG_PREFIX "Ethernet: "

#define FCS_SIZE 4

#define MIN_DATA_SIZE 46

#define PACKETS_SEND_COUT_TO_RESET_DELAY 20

size_t delay_before_transmit = 0;

void ethernet_handle_frame(const NetworkDevice* const network_device, const EthernetFrame* const frame, const uint32_t frame_size) {
    kassert(network_device != NULL && frame != NULL);

    const uint16_t packet_type = flip_short(frame->type);

    if (packet_type <= 1500) { // if type <= 1500, then its not a type, but length of the data (only in Ethernet 802.3 frame)
        kernel_msg("Ethernet 802.3 packet\n");
        return;
    }
    else if (packet_type >= 1500 && packet_type <= 1536) {
        kernel_msg("Unknow packet\n");
        return;
    }

    switch (packet_type) {
    case EthernetFrameTypeArp:
        arp_handle_packet(network_device, frame->data);

        break;
    case EthernetFrameTypeIpv4:
        ip_handle_packet(network_device, frame->data);

        break;
    default:
        break;
    }
}

bool_t ethernet_transmit_frame(const NetworkDevice* const network_device, const uint8_t destination_mac[MAC_ADDRESS_SIZE],
                             const uint16_t protocol, uint8_t* const data, uint32_t data_size) {
    kassert(network_device != NULL && destination_mac != NULL && data != NULL);

    static EthernetFrame* ethernet_frame = NULL;

    if (ethernet_frame == NULL) {
        ethernet_frame = kcalloc(sizeof(EthernetFrame) + ETHERNET_MAX_PAYLOAD_SIZE);

        if (ethernet_frame == NULL) {
            kernel_error(LOG_PREFIX"cant allocate memory for ethernet frame\n");
            return FALSE;
        }
    }

    //TODO: add mutex
    memcpy(destination_mac, ethernet_frame->destination_mac, MAC_ADDRESS_SIZE);
    memcpy(network_device->mac_address, ethernet_frame->source_mac, MAC_ADDRESS_SIZE);
    ethernet_frame->type = flip_short(protocol);

    while (data_size != 0) {
        const uint32_t size_to_transfer = (data_size > ETHERNET_MAX_PAYLOAD_SIZE) ? ETHERNET_MAX_PAYLOAD_SIZE : data_size;
        memcpy(data, ethernet_frame->data, size_to_transfer);

        const uint8_t padding = (size_to_transfer > MIN_DATA_SIZE) ? 0 : (MIN_DATA_SIZE - size_to_transfer);
        memset(ethernet_frame->data + size_to_transfer, padding, 0); // remove previous data

        static size_t packets_with_delay_send_total_count = 0;

        if (delay_before_transmit != 0 && packets_with_delay_send_total_count % PACKETS_SEND_COUT_TO_RESET_DELAY == 0) {
            delay_before_transmit = 0;
            packets_with_delay_send_total_count = 0;
        }
        else if (delay_before_transmit != 0) {
            ++packets_with_delay_send_total_count;
        }

        wait(delay_before_transmit);

        network_device->interface.transmit(network_device, ethernet_frame, sizeof(EthernetFrame) + size_to_transfer + padding);

        data_size -= size_to_transfer;
    }

    return TRUE;
}