#include "xhci.h"

#include "assert.h"
#include "logger.h"
#include "mem.h"
#include "usb.h"

#define LOG_PREFIX "Xhci: "

#define END_OP_REGS_OFFSET 0x400

#define USB3_PSSEN 0xd0
#define XUSB2PR    0xd8

bool_t is_xhci_controller(const PciDevice* const pci_dev) {
    return (
        pci_dev->config.class_code == PCI_SERIAL_BUS_CONTROLLER &&
        pci_dev->config.subclass == 0x3 &&
        pci_dev->config.prog_if == 0x30
    ) ? TRUE : FALSE;
}

Status init_xhci_controller(PciDevice* const pci_dev) {
    kassert(is_xhci_controller(pci_dev));

    XhciController* xhci = (XhciController*)kmalloc(sizeof(XhciController));

    if (xhci == NULL) {
        error_str = LOG_PREFIX "no memory";
        return KERNEL_ERROR;
    }

    if (vm_map_phys_to_virt(
                pci_dev->config.bar0,
                pci_dev->config.bar0,
                1,
                (VMMAP_WRITE | VMMAP_CACHE_DISABLED | VMMAP_WRITE_THROW)
        ) != KERNEL_OK) {
        error_str = LOG_PREFIX "failed to map registers";
        kfree((void*)xhci);
        return KERNEL_ERROR;
    }

    xhci->cap_reg = (XCapabilityReg*)pci_dev->config.bar0;
    xhci->oper_regs = (XUsbOperRegs*)(pci_dev->config.bar0 + xhci->cap_reg->length);
    xhci->port_regs = (XPortReg*)(pci_dev->config.bar0 + xhci->cap_reg->length + END_OP_REGS_OFFSET);
    xhci->rt_regs = (XRuntimeRegs*)(pci_dev->config.bar0 + xhci->cap_reg->rt_regs_space_off);

    if (pci_dev->config.vendor_id == 0x8086) {
        kernel_msg("Intel USB 3.0 Host detected\n");
    }

    kernel_msg(LOG_PREFIX "version %u.%u\n", xhci->cap_reg->version_major, xhci->cap_reg->version_minor);
    kernel_msg(LOG_PREFIX "cap_reg: %x\n", xhci->cap_reg);
    kernel_msg(LOG_PREFIX "oper_regs: %x\n", xhci->oper_regs);
    kernel_msg(LOG_PREFIX "port_regs: %x\n", xhci->port_regs);
    kernel_msg(LOG_PREFIX "rt_regs: %x\n", xhci->rt_regs);

    usb_bus_push(&xhci->common);

    //_kernel_break();

    return KERNEL_OK;
}