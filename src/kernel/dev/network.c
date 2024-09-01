#include "network.h"

uint8_t client_ipv4[IPV4_ADDRESS_SIZE] = { 0, 0, 0, 0 };

uint8_t** dns_servers_ipv4 = NULL;
size_t dns_servers_count = 0;

uint8_t** routers_ipv4 = NULL;
size_t routers_count = 0;

bool_t is_ethernet_controller(const PciDevice* const pci_device) {
    return pci_device->config->class_code == PCI_NETWORK_CONTROLLER &&
        pci_device->config->subclass == ETHERNET_CONTROLLER;
}