#pragma once

#include "dev/device.h"

#include "dev/stds/pci.h"

#define IS_LITTLE_ENDIAN 1

#define MAC_ADDRESS_SIZE 6
#define IPV4_ADDRESS_SIZE 4
#define IPV6_ADDRESS_SIZE 6

#define IP_MAX_ADDRESS_SIZE IPV6_ADDRESS_SIZE

static const uint8_t broadcast_mac[MAC_ADDRESS_SIZE] = { 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF };
static const uint8_t broadcast_ipv4[IPV4_ADDRESS_SIZE] = { 255, 255, 255, 255 };

extern uint8_t client_ipv4[IPV4_ADDRESS_SIZE];

extern uint8_t** dns_servers_ipv4;
extern size_t dns_servers_count;

extern uint8_t** routers_ipv4;
extern size_t routers_count;

typedef struct NetworkDevice NetworkDevice;

DEV_FUNC(Network, void, transmit, NetworkDevice* const network_device, const void* const data, const size_t data_size);
DEV_FUNC(Network, void, receive, NetworkDevice* const network_device);

typedef struct NetworkInterface {
    Network_receive_t receive;
    Network_transmit_t transmit;
} NetworkInterface;

typedef struct NetworkDevice {
    DEVICE_STRUCT_IMPL(Network);

    PciDevice* pci_device;

    uint8_t mac_address[MAC_ADDRESS_SIZE];
} NetworkDevice;

#define NETWORK_DEVICE_STRUCT_IMPL \
    NetworkDevice network_device;

bool_t is_ethernet_controller(const PciDevice* const pci_device);

