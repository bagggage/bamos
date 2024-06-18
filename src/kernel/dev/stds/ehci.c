#include "ehci.h"

#include "logger.h"
#include "mem.h"
#include "pci.h"

static inline bool_t is_ehci_device(const PciDevice* const pci_dev) {
    return (
        pci_dev->config.class_code == PCI_SERIAL_BUS_CONTROLLER &&
        pci_dev->config.subclass == 0x3 &&
        pci_dev->config.prog_if == 0x20
    ) ? TRUE : FALSE;
}

static EhciController* init_ehci_controller(PciDevice* const pci_dev) {
    EhciController* ehci = (EhciController*)kmalloc(sizeof(EhciController));

    if (ehci == NULL) return NULL;

    if (vm_map_phys_to_virt(
                pci_dev->bar0,
                pci_dev->bar0,
                1,
                (VMMAP_WRITE | VMMAP_CACHE_DISABLED | VMMAP_WRITE_THROW)
        ) != KERNEL_OK) {
        kernel_error("EHCI: Failed to map registers\n");
        kfree((void*)ehci);
        return NULL;
    }

    ehci->cap_reg = (CapabilityReg*)pci_dev->bar0;
    ehci->oper_regs = (UsbOperRegs*)(pci_dev->bar0 + ehci->cap_reg->length);

    kernel_msg("EHCI BAR0: %x\n", pci_dev->bar0);
    kernel_msg("Cap reg length: %x\n", ehci->cap_reg->length);
    kernel_msg("Cap reg version: %u%u%u%u\n",
        ehci->cap_reg->interface_version & 0xF,
        (ehci->cap_reg->interface_version & 0xF0) >> 4,
        (ehci->cap_reg->interface_version & 0xF00) >> 8,
        (ehci->cap_reg->interface_version & 0xF000) >> 12
    );
    kernel_msg("Command run: %x\n", ehci->oper_regs->command_reg.run);
    kernel_msg("Status reg: %x\n", ehci->oper_regs->status_reg.value);

    // Stop
    ehci->oper_regs->command_reg.run = 0;
    while (ehci->oper_regs->status_reg.halted == 0);

    // Reset host controller
    ehci->oper_regs->command_reg.host_reset = 1;
    while (ehci->oper_regs->command_reg.host_reset == 1);

    return ehci;
}

Status init_ehci() {
    PciBus* pci_bus = (void*)dev_find_by_type(NULL, DEV_PCI_BUS);
    PciDevice* curr_dev = (void*)pci_bus->nodes.next;

    for (; curr_dev != NULL; curr_dev = curr_dev->next) {
        if (is_ehci_device(curr_dev) == FALSE) continue;

        EhciController* ehci = init_ehci_controller(curr_dev);

        if (ehci == NULL) {
            error_str = "Not enough memory";
            return KERNEL_COUGH;
        }

        usb_bus_push(&ehci->common);
    }

    //_kernel_break();

    return KERNEL_OK;
}