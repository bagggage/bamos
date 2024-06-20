#include "xhci.h"

#include "bootboot.h"

#include "assert.h"
#include "logger.h"
#include "math.h"
#include "mem.h"
#include "usb.h"

#include "intr/apic.h"
#include "intr/intr.h"
#include "vm/buddy_page_alloc.h"

#define LOG_PREFIX "Xhci: "

#define END_OP_REGS_OFFSET 0x400

#define	XHCI_INTEL_USB3PRM      0xdc // USB 3.0 Port Routing Mask
#define	XHCI_INTEL_USB3_PSSEN   0xd8 // USB 3.0 Port SuperSpeed Enable
#define	XHCI_INTEL_USB2PRM      0xd4 // USB 2.0 Port Routing Mask
#define	XHCI_INTEL_XUSB2PR      0xd0 // USB 2.0 Port Routing

#define XHCI_EVENT_HANDLER_BUSY 8

#define XHCI_RING_ENTRIES_COUNT (PAGE_BYTE_SIZE / sizeof(XTransferRequestBlock))
#define XHCI_RING_AVAIL_COUNT   (XHCI_RING_ENTRIES_COUNT - 1)
#define XHCI_MAX_CONTROLLERS 16

extern BOOTBOOT bootboot;

static XhciController* g_controllers[XHCI_MAX_CONTROLLERS] = { NULL };
static uint32_t g_last_ctrl = 0;

bool_t is_xhci_controller(const PciDevice* const pci_dev) {
    return (
        pci_dev->config->class_code == PCI_SERIAL_BUS_CONTROLLER &&
        pci_dev->config->subclass == 0x3 &&
        pci_dev->config->prog_if == 0x30
    ) ? TRUE : FALSE;
}

static volatile XExtCapPtrReg* xhci_support_ext_cap(XhciController* const xhci, const XExtCapabilityID id) {
    volatile XExtCapPtrReg* cap = xhci->ext_cap;

    do {
        kernel_msg(LOG_PREFIX "Capability: %x\n", cap);

        if (cap->capabilty_id == id) return cap;

        if (cap->next_ext_cap_ptr != 0) {
            cap = (volatile XExtCapPtrReg*)
                ((uint64_t)cap + (cap->next_ext_cap_ptr << 2));
        }
    } while (cap->next_ext_cap_ptr != 0);

    return NULL;
}

static bool_t xhci_alloc_ring(XhciRing* const ring) {
    ring->entries = (XTransferRequestBlock*)bpa_allocate_pages(0);

    if (ring->entries == (void*)INVALID_ADDRESS) return FALSE;

    kassert(get_phys_address((uint64_t)ring->entries) == (uint64_t)ring->entries);
    memset((void*)ring->entries, PAGE_BYTE_SIZE, 0);

    ring->dequeue = 0;
    ring->enqueue = 0;

    XTransferRequestBlock* const link_trb = &ring->entries[XHCI_RING_ENTRIES_COUNT - 1];

    link_trb->buffer_ptr.val = (uint64_t)ring->entries;
    link_trb->ctrl.trb_type = TRB_LINK;
    link_trb->ctrl.toggle_cycle = TRUE;

    return TRUE;
}

static void xhci_free_ring(XhciRing* const ring) {
    if (ring->entries == NULL) return;

    bpa_free_pages((uint64_t)ring->entries, 0);

    ring->dequeue = 0;
    ring->enqueue = 0;
    ring->entries = NULL;
}

static bool_t xhci_alloc_event_ring(XhciController* const xhci, const uint32_t intr_idx, XEventRingSegTableEntry* const event_ring_table) {
    const uint64_t ring_base = bpa_allocate_pages(0);

    if (ring_base == INVALID_ADDRESS) return FALSE;

    kassert(get_phys_address(ring_base) == ring_base);
    memset((void*)ring_base, PAGE_BYTE_SIZE, 0);

    volatile XRuntimeIntrReg* const intr_reg = xhci->rt_regs->intr_regs + intr_idx;

    event_ring_table->seg_base.lo = (uint32_t)ring_base;
    event_ring_table->seg_base.hi = (uint32_t)(ring_base >> 32);
    event_ring_table->seg_size = PAGE_BYTE_SIZE / sizeof(XTransferRequestBlock);

    intr_reg->event_ring_dequeue.lo = (uint32_t)ring_base;
    intr_reg->event_ring_dequeue.hi = (uint32_t)(ring_base >> 32);

    intr_reg->event_ring_seg_table_base.lo = (uint32_t)((uint64_t)event_ring_table);
    intr_reg->event_ring_seg_table_base.hi = (uint32_t)((uint64_t)event_ring_table >> 32);
    intr_reg->event_ring_seg_table_size = 1;

    return TRUE;
}

static bool_t xhci_halt(XhciController* const xhci) {
    xhci->oper_regs->command_reg.run = 0;

    while (xhci->oper_regs->status_reg.host_contrl_hltd == 0);

    return TRUE;
}

static bool_t xhci_reset(XhciController* const xhci) {
    xhci->oper_regs->command_reg.host_reset = 1;

    while (
        xhci->oper_regs->command_reg.host_reset != 0 ||
        xhci->oper_regs->status_reg.contrl_not_ready != 0
    );

    return TRUE;
}

static void xhci_submit_command(XhciController* const xhci, const XTransferRequestBlock* trb) {
    xhci->cmd_ring.entries[xhci->cmd_ring.enqueue] = *trb;
}

ATTR_INTRRUPT void xhci_intr_handler(InterruptFrame64* frame) {
    UNUSED(frame);

    kernel_logger_push_color(COLOR_LYELLOW);
    kprintf("XHCI Interrupt\n");
    kernel_logger_pop_color();

    XhciController* xhci = NULL;

    for (uint32_t i = 0; i < g_last_ctrl; ++i) {
        if (g_controllers[i]->oper_regs->status_reg.event_intr) {
            xhci = g_controllers[i];
            xhci->oper_regs->status_reg.event_intr = 1;
            break;
        }
    }

    if (xhci == NULL) {
        kernel_warn(LOG_PREFIX "interrupt handler can't found halted controller");
        lapic_eoi();
        return;
    }

    volatile XRuntimeIntrReg* const intr_regs = xhci->rt_regs->intr_regs;

    kprintf("XHCI: %x\n", (uint64_t)xhci);

    for (uint32_t i = 0; i < xhci->intr_count; ++i) {
        const uint64_t dequeue = ((uint64_t)intr_regs[i].event_ring_dequeue.hi << 32) | intr_regs[i].event_ring_dequeue.lo;
        if ((dequeue & XHCI_EVENT_HANDLER_BUSY) == 0) continue;

        kprintf("Int[%u]: IE: %b: IP: %b\n", i, intr_regs[i].intr_enable, intr_regs[i].intr_pending);

        XEventTrb* event = (XEventTrb*)(dequeue & (~0xFull));
        uint8_t ccs_bit = (xhci->event_bitmap >> i) & 1;

        if (event->cycle_bit != ccs_bit) event++;

        while (event->cycle_bit == ccs_bit) {
            switch (event->type)
            {
            case TRB_PORT_STAT_CHANGE_EVENT:
                volatile XPortReg* port = xhci->port_regs + (event->port_id - 1);
                kernel_msg("Port: %u: CSC: %b: CCS: %b: PP: %b\n",
                    event->port_id, port->stat_ctrl.conn_stat_change,
                    port->stat_ctrl.curr_conn_stat, port->stat_ctrl.power);

                break;
            case TRB_LINK:
                xhci->event_bitmap ^= (1 << i);
                ccs_bit ^= 1;

                event = (XEventTrb*)event->trb_ptr.val;
                continue;
                break;
            default:
                kernel_msg("Event: %x: type: %u\n", (uint64_t)event, event->type);
                break;
            }

            event->cycle_bit = !ccs_bit;
            event++;
        }

        // If not the start of the ring
        if (((uint64_t)event & 0xFFF) != 0) event--;

        intr_regs[i].event_ring_dequeue.hi = ((uint64_t)event >> 32);
        intr_regs[i].event_ring_dequeue.lo = (uint32_t)((uint64_t)event);
        intr_regs[i].intr_pending = 1;
    }

    kernel_warn("EOI\n");
    lapic_eoi();
}

static bool_t xhci_init(XhciController* const xhci) {
    while (xhci->oper_regs->status_reg.contrl_not_ready);

    pci_enable_bus_master(xhci->pci_dev);

    // Assume ownership of the controller from the BIOS.
    volatile XUsbLegacySupport* legacy_support = (void*)xhci_support_ext_cap(xhci, XHCI_ECAP_USB_LEG_SUP);

    if (legacy_support != NULL && legacy_support->capability.hc_bios_owned_sem) {
        kernel_warn(LOG_PREFIX "Owned by BIOS\n");

        legacy_support->capability.hc_os_owned_sem = 1;

        while (
            legacy_support->capability.hc_bios_owned_sem != 0 ||
            legacy_support->capability.hc_os_owned_sem != 1
        );
        kernel_msg(LOG_PREFIX "Ownership changed\n");
    }
    if (legacy_support) {
        legacy_support->ctrl_stat.usb_smi_enable = 0;
        legacy_support->ctrl_stat.smi_host_sys_err_enable = 0;
        legacy_support->ctrl_stat.smi_os_own_enable = 0;
        legacy_support->ctrl_stat.smi_pci_cmd_enable = 0;
        legacy_support->ctrl_stat.smi_bar_enable = 0;
        legacy_support->ctrl_stat.smi_event_intr = 0;

        legacy_support->ctrl_stat.smi_os_own_change = 1;
    }

    if (xhci->pci_dev->config->vendor_id == 0x8086) {
        kernel_msg(LOG_PREFIX "Intel USB 3.0 Host detected\n");

        uint32_t ports = pci_config_readl(xhci->pci_dev, XHCI_INTEL_USB3PRM);
	    pci_config_writel(xhci->pci_dev, XHCI_INTEL_USB3_PSSEN, ports);

	    ports = pci_config_readl(xhci->pci_dev, XHCI_INTEL_USB2PRM);
	    pci_config_writel(xhci->pci_dev, XHCI_INTEL_XUSB2PR, ports);
    }

    // Reset
    xhci_halt(xhci);
    xhci_reset(xhci);

    // Enable max dev slots
    xhci->oper_regs->configure.max_dev_slots_enable = xhci->slots_count;

    // Configure Device Context Base Address Array Pointer
    xhci->dev_context = kcalloc(xhci->slots_count * sizeof(XDeviceContext*));

    if (xhci->dev_context == NULL) {
        error_str = LOG_PREFIX "Failed to configure Device Context Array";
        return FALSE;
    }

    kassert(((uint64_t)xhci->dev_context % 64) == 0); // Should be 64-byte aligned
    pci_write64((void*)&xhci->oper_regs->dev_context_base, get_phys_address((uint64_t)xhci->dev_context));

    // Configure scratchpad buffer
    const uint16_t scratchpad_count =
        (xhci->cap_reg->struct_params_2.max_scratch_pad_hi << 5) |
        (xhci->cap_reg->struct_params_2.max_scratch_pad_lo);

    kernel_msg("Scratchpad count: %u: page size: %u\n", scratchpad_count, xhci->page_size);

    if (scratchpad_count > 0) {
        uint64_t* const scratchpad_array = kcalloc(sizeof(uint64_t) * scratchpad_count);

        if (scratchpad_array == NULL) {
            kfree(xhci->dev_context);
            error_str = LOG_PREFIX "Failed to allocate scratchpads";
            return FALSE;
        }

        xhci->dev_context[0] = (void*)get_phys_address((uint64_t)scratchpad_array);

        const uint16_t rank = log2(xhci->page_size / PAGE_BYTE_SIZE);

        for (uint16_t i = 0; i < scratchpad_count; ++i) {
            scratchpad_array[i] = bpa_allocate_pages(rank);

            if (scratchpad_array[i] == INVALID_ADDRESS) {
                kfree(scratchpad_array);
                kfree(xhci->dev_context);
                error_str = LOG_PREFIX "Failed to allocate scratchpads";
                return KERNEL_ERROR;
            }
        }
    }

    // Prepare command ring
    if (xhci_alloc_ring(&xhci->cmd_ring) == FALSE) {
        kfree(xhci->dev_context);
        error_str = LOG_PREFIX "Failed to allocate command ring";
        return FALSE;
    }

    xhci->oper_regs->cmd_ring_ctrl.ring_cycl_state = 1;

    kernel_msg("Cmd ring phys: %x\n", get_phys_address((uint64_t)xhci->cmd_ring.entries));
    pci_write64((void*)&xhci->oper_regs->cmd_ring_ctrl.ring_ptr, get_phys_address((uint64_t)xhci->cmd_ring.entries));

    // Init interrupts
    if (pci_init_msi_or_msi_x(xhci->pci_dev) == FALSE) {
        kfree(xhci->dev_context);
        error_str = LOG_PREFIX "Failed to init PCI MSI/MSI-X";
        return FALSE;
    }

    const uint32_t intr_count =
        xhci->pci_dev->intr_ctrl->type == PCI_INTR_MSI ? 1 :
        (xhci->cap_reg->struct_params_1.max_interrupters > bootboot.numcores ?
        bootboot.numcores : xhci->cap_reg->struct_params_1.max_interrupters);

    kernel_msg("Max interrupters: %u: Current: %u\n",
        xhci->cap_reg->struct_params_1.max_interrupters, intr_count);
    kassert(intr_count < 64 && "Now only 64 MSI-X interrupts supported by PCI driver");

    xhci->intr_count = intr_count;

    XEventRingSegTableEntry* const event_ring_table = (XEventRingSegTableEntry*)kcalloc(sizeof(XEventRingSegTableEntry) * intr_count);
    XEventRingSegTableEntry* const event_ring_table_phys = (XEventRingSegTableEntry*)get_phys_address((uint64_t)event_ring_table);

    if (event_ring_table == NULL) {
        error_str = LOG_PREFIX "Failed to allocate event rings";
        xhci_free_ring(&xhci->cmd_ring);
        kfree(xhci->dev_context);
        return FALSE;
    }

    xhci->event_table = event_ring_table;

    for (uint32_t i = 0; i < intr_count; ++i) {
        // Try to use different cpus
        InterruptLocation intr_location = intr_reserve(INTR_ANY_CPU);

        kprintf("interrupter %u:%u, ", intr_location.cpu_idx, intr_location.vector);

        if (intr_location.vector == 0 ||
            pci_setup_precise_intr(xhci->pci_dev, intr_location) == FALSE ||
            intr_setup_handler(intr_location, (void*)xhci_intr_handler) == FALSE ||
            xhci_alloc_event_ring(xhci, i, event_ring_table_phys + i) == FALSE)
        {
            error_str = LOG_PREFIX "Failed to initialize interrupt";

            if (intr_location.vector != 0) intr_release(intr_location);

            xhci_free_ring(&xhci->cmd_ring);
            kfree(xhci->dev_context);
            return FALSE;
        }

        // interrupt tick rate: 2000 * 250ns (interrupt per 0.5 ms)
        xhci->rt_regs->intr_regs[i].intr_moder_interval = 2000;
        xhci->rt_regs->intr_regs[i].intr_moder_counter = 2000;

        xhci->rt_regs->intr_regs[i].intr_enable = 1;
    }

    xhci->event_bitmap = UINT64_MAX;

    return TRUE;
}

void xhci_enumerate_ports(XhciController* const xhci) {
    for (uint32_t i = 0; i < xhci->cap_reg->struct_params_1.max_ports; ++i) {
        volatile XPortReg* const port = xhci->port_regs + i;
    }
}

Status init_xhci_controller(PciDevice* const pci_dev) {
    kassert(is_xhci_controller(pci_dev));

    if (g_last_ctrl >= XHCI_MAX_CONTROLLERS) {
        error_str = LOG_PREFIX "Max controllers limit has reached";
        return KERNEL_COUGH;
    }

    XhciController* const xhci = (XhciController*)kmalloc(sizeof(XhciController));

    if (xhci == NULL) {
        error_str = LOG_PREFIX "no memory";
        return KERNEL_ERROR;
    }

    const uint64_t bar0 = vm_map_mmio(pci_dev->bar0, PAGES_PER_2MB / 2);

    if (bar0 == 0) {
        error_str = LOG_PREFIX "failed to map registers";
        kfree((void*)xhci);
        return KERNEL_ERROR;
    }

    xhci->pci_dev   = pci_dev;
    xhci->cap_reg   = (XCapabilityReg*) bar0;
    xhci->ext_cap   = (XExtCapPtrReg*)  (bar0 + (xhci->cap_reg->cap_params_1.ext_cap_ptr << 2));
    xhci->oper_regs = (XUsbOperRegs*)   (bar0 + xhci->cap_reg->length);
    xhci->port_regs = (XPortReg*)       (bar0 + xhci->cap_reg->length + END_OP_REGS_OFFSET);
    xhci->rt_regs   = (XRuntimeRegs*)   (bar0 + xhci->cap_reg->rt_regs_space_off);
    xhci->intr_set  = &xhci->rt_regs->intr_regs[0];

    xhci->page_size = 1u << (xhci->oper_regs->page_size + 12);
    xhci->slots_count = xhci->cap_reg->struct_params_1.max_dev_slots;
    xhci->dev_ctx_size = (xhci->cap_reg->cap_params_1.csz != 0) ? 64 : 32;

    const uint32_t serial_bus_num = pci_config_readl(pci_dev, 0x60);

    kernel_msg(LOG_PREFIX "%x: USB %u.%u: ver: %u.%u.%u.%u\n",
        pci_dev->bar0,
        (serial_bus_num >> 4) & 0xF, serial_bus_num & 0xF,
        xhci->cap_reg->version_1, xhci->cap_reg->version_2,
        xhci->cap_reg->version_3, xhci->cap_reg->version_4
    );

    if (xhci_init(xhci) == FALSE) {
        kfree((void*)xhci);
        return KERNEL_ERROR;
    }

    usb_bus_push(&xhci->common);

    kernel_msg(LOG_PREFIX "Page size: %u: Device context size: %u: Max slots: %u: Moder interval: %u\n",
        xhci->page_size, xhci->dev_ctx_size, xhci->slots_count,
        xhci->rt_regs->intr_regs->intr_moder_interval
    );

    g_controllers[g_last_ctrl++] = xhci;

    xhci->oper_regs->command_reg.run = 1;
    xhci->oper_regs->command_reg.intr_enable = 1;

    while (xhci->oper_regs->status_reg.host_contrl_hltd);

    _kernel_break();

    return KERNEL_OK;
}