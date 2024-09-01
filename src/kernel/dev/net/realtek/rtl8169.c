#include "rtl8169.h"

#include "assert.h"
#include "logger.h"
#include "math.h"
#include "mem.h"

#include "vm/bitmap.h"
#include "vm/buddy_page_alloc.h"

#include "cpu/io.h"

#include "intr/intr.h"

#include "network-protocols/ethernet.h"

#define LOG_PREFIX "RTL8169: "

#define OWN SET_BIT(31) // If set, card own this descriptor
#define EOR SET_BIT(30) // End of Rx descriptor Ring
#define FS SET_BIT(29) // First descriptor of a Tx packet
#define LS SET_BIT(28) // Last descriptor of a Tx packet

#define MAX_PACKET_SIZE 0x3FFF

uint32_t num_of_tx_descriptors = 1024;
uint32_t num_of_rx_descriptors = 1024;

typedef enum Rtl8196Registers {
    Rtl8169CommandRegister = 0x37,
    Rlt8169CPlusCommandRegister = 0xE0,
    Rtl8169Register9346CR = 0x50,
    Rtl8169InterruptMaskRegister = 0x3C,
    Rtl8169ReceiveConfigurationRegister = 0x44,
    Rtl8169RxMaxPacketSizeRegister = 0xDA,
    Rtl8169RxStartAddressRegister = 0xE4,
    Rtl8169EarlyTransmitThreshold = 0xEC,
    Rtl8169TransmitConfiguration = 0x40,
    Rtl8169TxStartAddressRegister = 0x20,
    Rtl8169TxStartAddressHPLowRegister = 0x28,
    Rtl8169TxStartAddressHPHightRegister = 0x2C,
    Rtl8169TransmitPriorityPollingRegister = 0x38,
} Rtl8196Registers;

ATTR_INTRRUPT void irq_rtl8169(InterruptFrame64* frame) {
    UNUSED(frame);

    kernel_msg("[RTL8169] Interrupt detected\n");
}

static void setup_rx_descriptors(Rtl8169Device* const rtl8169_device) {
    kassert(rtl8169_device != NULL);

    const uint32_t rx_buffer_len = 256;

    for (uint32_t i = 0; i < num_of_rx_descriptors; ++i) {
        uint64_t packet_buffer_address = (uint64_t)kmalloc(rx_buffer_len);

        if (packet_buffer_address == NULL) {
            num_of_rx_descriptors = i;
            rtl8169_device->rx_descriptors[i - 1].command = (OWN | EOR | (rx_buffer_len & MAX_PACKET_SIZE));
            break;
        }

        if (i == (num_of_rx_descriptors - 1)) {
            rtl8169_device->rx_descriptors[i].command = (OWN | EOR | (rx_buffer_len & MAX_PACKET_SIZE));
        }
        else {
            rtl8169_device->rx_descriptors[i].command = (OWN | (rx_buffer_len & MAX_PACKET_SIZE));
        }

        rtl8169_device->rx_descriptors[i].vlan = 0;
        rtl8169_device->rx_descriptors[i].buffer = get_phys_address(packet_buffer_address);
    }

    outl(rtl8169_device->network_device.pci_device->bar0 + Rtl8169ReceiveConfigurationRegister, SET_BITS(0, 4) | SET_BITS(8, 15)); // RxConfig = RXFTH: unlimited, MXDMA: unlimited, AAP: set (promisc. mode set)
    outw(rtl8169_device->network_device.pci_device->bar0 + Rtl8169RxMaxPacketSizeRegister, SET_BITS(0, 12)); // Max rx packet size
    outl(rtl8169_device->network_device.pci_device->bar0 + Rtl8169RxStartAddressRegister, (uint32_t)((uint64_t)rtl8169_device->rx_descriptors)); // Tell the NIC where the lower byte of Rx descriptor is
    outl(rtl8169_device->network_device.pci_device->bar0 + Rtl8169RxStartAddressRegister + 4, (uint32_t)((uint64_t)(rtl8169_device->rx_descriptors) >> 32)); // Tell the NIC where the upper byte of Rx descriptor is
}

static void setup_tx_descriptors(Rtl8169Device* const rtl8169_device) {
    kassert(rtl8169_device != NULL);

    const uint32_t tx_buffer_len = 256;

    for (uint32_t i = 0; i < num_of_tx_descriptors; ++i) {
        uint64_t packet_buffer_address = kmalloc(tx_buffer_len);

        if (packet_buffer_address == NULL) {
            num_of_tx_descriptors = i;
            rtl8169_device->tx_descriptors[i - 1].command = (EOR | (tx_buffer_len & MAX_PACKET_SIZE));
            break;
        }

        if (i == (num_of_tx_descriptors - 1)) { // Last descriptor? if so, set the EOR bit 
            rtl8169_device->tx_descriptors[i].command = (EOR | (tx_buffer_len & MAX_PACKET_SIZE));
        }
        else {
            rtl8169_device->tx_descriptors[i].command = (tx_buffer_len & MAX_PACKET_SIZE);
        }

        rtl8169_device->tx_descriptors[i].vlan = 0;
        rtl8169_device->tx_descriptors[i].buffer = get_phys_address(packet_buffer_address);
    }

    outb(rtl8169_device->network_device.pci_device->bar0 + Rtl8169CommandRegister, SET_BIT(2)); // Enable Tx in the Command register, required before setting TxConfig
    outb(rtl8169_device->network_device.pci_device->bar0 + Rtl8169EarlyTransmitThreshold, SET_BITS(0, 1) | SET_BITS(3, 5)); // Max tx packet size
    outb(rtl8169_device->network_device.pci_device->bar0 + Rtl8169EarlyTransmitThreshold, SET_BITS(0, 5)); // Disable threshold
    outl(rtl8169_device->network_device.pci_device->bar0 + Rtl8169TransmitConfiguration, SET_BITS(8, 10) | SET_BITS(24, 25)); // TxConfig = IFG: normal, max DMA: unlimited
    outl(rtl8169_device->network_device.pci_device->bar0 + Rtl8169TxStartAddressRegister, (uint32_t)((uint64_t)rtl8169_device->tx_descriptors)); // Tell the NIC where the lower byte of Tx descriptor is
    outl(rtl8169_device->network_device.pci_device->bar0 + Rtl8169TxStartAddressRegister + 4, (uint32_t)((uint64_t)(rtl8169_device->tx_descriptors) >> 32)); // Tell the NIC where the upper byte of Tx descriptor is
    outl(rtl8169_device->network_device.pci_device->bar0 + Rtl8169TxStartAddressHPLowRegister, 0); // Lower bytes of high priority tx descriptor
    outl(rtl8169_device->network_device.pci_device->bar0 + Rtl8169TxStartAddressHPHightRegister, 0); // Upper bytes of high priority tx descriptor
    outb(rtl8169_device->network_device.pci_device->bar0 + Rtl8169CommandRegister, SET_BITS(2, 3)); // Enable Rx/Tx in the Command register
}

static void rtl8169_receive_packet(NetworkDevice* const network_device) {
    kassert(network_device != NULL);

    Rtl8169Device* rtl8169_device = (Rtl8169Device*)network_device;

    size_t buffer_size = 0;
    void* buffer = NULL;

    bool_t flag = FALSE;

    kernel_msg("Waiting for package\n");
    while (TRUE) {
        for (uint32_t i = 0; i < num_of_rx_descriptors; ++i) {
            if (!(rtl8169_device->rx_descriptors[i].command & OWN)) {
                rtl8169_device->rx_descriptors[i].command |= OWN;
                buffer_size = rtl8169_device->rx_descriptors[i].command & MAX_PACKET_SIZE;
                buffer = rtl8169_device->rx_descriptors[i].buffer;

                flag = TRUE;
                break;
            }
        }

        if (flag) {
            ethernet_handle_frame(network_device, buffer, buffer_size);
        }
    }
}

static void rtl8169_transmit_packet(NetworkDevice* const network_device, const void* const data, const size_t data_size) {
    kassert(network_device != NULL);

    const uint16_t tx_pointer = 0;

    Rtl8169Device* rtl8169_device = (Rtl8169Device*)network_device;

    memcpy(data, rtl8169_device->tx_descriptors[tx_pointer].buffer, data_size);
    rtl8169_device->tx_descriptors[tx_pointer].command = OWN | EOR | FS | LS | (data_size & MAX_PACKET_SIZE);
    rtl8169_device->tx_descriptors[tx_pointer].vlan = 0;

    outb(rtl8169_device->network_device.pci_device->bar0 + Rtl8169TransmitPriorityPollingRegister, SET_BIT(6));

    while (inb(rtl8169_device->network_device.pci_device->bar0 + Rtl8169TransmitPriorityPollingRegister) & SET_BIT(6));
}

bool_t is_rtl8169_controller(const PciDevice* const pci_device) {
    return (pci_device->config->vendor_id == 0x10EC && pci_device->config->device_id == 0x8161) ||
        (pci_device->config->vendor_id == 0x10EC && pci_device->config->device_id == 0x8168) ||
        (pci_device->config->vendor_id == 0x10EC && pci_device->config->device_id == 0x8169) ||
        (pci_device->config->vendor_id == 0x1259 && pci_device->config->device_id == 0xC107) ||
        (pci_device->config->vendor_id == 0x1737 && pci_device->config->device_id == 0x1032) ||
        (pci_device->config->vendor_id == 0x16EC && pci_device->config->device_id == 0x0116);
}

Status init_rtl8169(const PciDevice* const pci_device) {
    if (pci_device == NULL) return KERNEL_INVALID_ARGS;

    Rtl8169Device* rtl8169_device = (Rtl8169Device*)dev_push(DEV_NETWORK, sizeof(Rtl8169Device));

    if (rtl8169_device == NULL) {
        error_str = LOG_PREFIX "failed to create rtl8169 device";
        return KERNEL_ERROR;
    }

    rtl8169_device->network_device.pci_device = pci_device;

    outb(rtl8169_device->network_device.pci_device->bar0 + Rtl8169CommandRegister, SET_BIT(4)); // Send the Reset bit to the Command register 
    while (inb(rtl8169_device->network_device.pci_device->bar0 + Rtl8169CommandRegister) & SET_BIT(4)); // Wait for the chip to finish resetting 

    outw(rtl8169_device->network_device.pci_device->bar0 + Rlt8169CPlusCommandRegister, SET_BIT(3));  // Enable PCI DMA

    for (uint8_t i = 0; i < MAC_ADDRESS_SIZE; ++i) {
        rtl8169_device->network_device.mac_address[i] = inb(rtl8169_device->network_device.pci_device->bar0 + i);
    }

    kernel_msg("MAC address: %x:%x:%x:%x:%x:%x\n",
                rtl8169_device->network_device.mac_address[0],
                rtl8169_device->network_device.mac_address[1],
                rtl8169_device->network_device.mac_address[2],
                rtl8169_device->network_device.mac_address[3],
                rtl8169_device->network_device.mac_address[4],
                rtl8169_device->network_device.mac_address[5]);

    outb(rtl8169_device->network_device.pci_device->bar0 + Rtl8169Register9346CR, SET_BITS(6, 7)); // Unlock config registers

    InterruptLocation intr_location = intr_reserve(INTR_ANY_CPU);

    if (!intr_setup_handler(intr_location, (void*)&irq_rtl8169, INTR_KERNEL_STACK)) {
        error_str = LOG_PREFIX"Cant set interrupt";
        return KERNEL_ERROR;
    }
    outw(rtl8169_device->network_device.pci_device->bar0 + Rtl8169InterruptMaskRegister, SET_BITS(0, 15)); // Unlock all ints 

    const uint32_t rank = log2upper(div_with_roundup(sizeof(Rtl8169Descriptor) * num_of_tx_descriptors, PAGE_BYTE_SIZE));
    rtl8169_device->tx_descriptors = bpa_allocate_pages(rank);
    rtl8169_device->rx_descriptors = bpa_allocate_pages(rank);

    if (rtl8169_device->rx_descriptors == INVALID_ADDRESS || rtl8169_device->tx_descriptors == INVALID_ADDRESS) {
        error_str = LOG_PREFIX "No memory";

        bpa_free_pages(rtl8169_device->rx_descriptors, rank);
        bpa_free_pages(rtl8169_device->tx_descriptors, rank);

        return KERNEL_ERROR;
    }

    setup_rx_descriptors(rtl8169_device);
    setup_tx_descriptors(rtl8169_device);

    outb(rtl8169_device->network_device.pci_device->bar0 + Rtl8169Register9346CR, 0x00); // Lock config registers

    rtl8169_device->network_device.interface.receive = &rtl8169_receive_packet;
    rtl8169_device->network_device.interface.transmit = &rtl8169_transmit_packet;

    kernel_msg(LOG_PREFIX"Setup finished\n");

    return KERNEL_OK;
}