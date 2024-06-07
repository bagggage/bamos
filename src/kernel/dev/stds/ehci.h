#pragma once

#include "definitions.h"
#include "usb.h"

#include "utils/list.h"

typedef struct CapabilityReg {
    uint8_t length;             //Capability Register Length
    uint8_t reserved;
    uint16_t interface_version; // BCD
    uint32_t structural_params;
    uint32_t capability_params;
    uint64_t comp_port_route;
} ATTR_PACKED CapabilityReg;

typedef struct UsbCommandReg {
    uint32_t run : 1;
    uint32_t host_reset : 1;
    uint32_t frame_list_size : 2;
    uint32_t periodic_sched_enable : 1;
    uint32_t async_sched_enable : 1;
    uint32_t int_doorbell : 1;
    uint32_t light_host_reset : 1;
    uint32_t async_sched_park_count : 2;
    uint32_t reserved_1 : 1;
    uint32_t async_sched_park_enable : 1;
    uint32_t reserved_2 : 4;
    uint32_t int_threshold : 8; // Number of micro frames to process between interrupts
    uint32_t reserved_3 : 8;
} ATTR_PACKED UsbCommandReg;

typedef union UsbStatusReg {
    struct {
        uint32_t transfer_int : 1;
        uint32_t error_int : 1;
        uint32_t port_change : 1;
        uint32_t frame_list_roll : 1;
        uint32_t host_error : 1;
        uint32_t doorbell_int : 1;
        uint32_t reserved_1 : 6;
        uint32_t halted : 1;
        uint32_t reclamation : 1;
        uint32_t periodic_sched_status : 1;
        uint32_t async_sched_status : 1;
        uint32_t reserved_2 : 16;
    };
    volatile uint32_t value;
} ATTR_PACKED UsbStatusReg;

typedef struct UsbIntrReg {
    uint32_t transfer_int : 1;
    uint32_t error_int : 1;
    uint32_t port_int : 1;
    uint32_t frame_list_int : 1;
    uint32_t host_error_int : 1;
    uint32_t async_advance_int : 1;
    uint32_t reserved : 26;
} ATTR_PACKED UsbIntrReg;

typedef struct PortStatusCtrlReg {
    uint32_t connected : 1;
    uint32_t connect_change : 1;
    uint32_t enabled : 1;
    uint32_t enabled_change : 1;
    uint32_t overcurrent : 1;
    uint32_t overcurrent_change : 1;
    uint32_t force_resum : 1;
    uint32_t suspend : 1;
    uint32_t reset : 1;
    uint32_t reserved_1 : 1;
    uint32_t line_status : 2;
    uint32_t power : 1;
    uint32_t comp_ctrl : 1;      // 0 = Local, 1 = Companion Host Controller
    uint32_t indicator_ctrl : 2; // 0 = Off, 1 = Amber, 2 = Green
    uint32_t test_ctrl : 4;
    uint32_t wake_on_connect : 1;
    uint32_t wake_on_disconn : 1;
    uint32_t wake_on_overcurr : 1;
    uint32_t reserved_2 : 9;
} ATTR_PACKED PortStatusCtrlReg;

typedef struct UsbOperRegs {
    volatile UsbCommandReg command_reg;
    volatile UsbStatusReg status_reg;
    volatile UsbIntrReg intr_reg;
    volatile uint32_t frame_idx;
    volatile uint32_t ctrl_ds_segment;
    volatile uint32_t periodic_list_base;
    volatile uint32_t async_list_addr;
    volatile uint32_t reserved[9];
    volatile uint32_t config_flag;
    PortStatusCtrlReg ports[];
} ATTR_PACKED ATTR_ALIGN(4) UsbOperRegs;

typedef struct EhciTransferDescriptor {
    uint32_t next_link; // Standard next link pointer
    uint32_t alt_link; 
    uint32_t token;
    uint32_t buffer_prt[5];
} ATTR_PACKED EhciTransferDescriptor;

typedef enum EhciQueueType {
    EHCI_QUEUE_ISOCHRONOUS_TD = 0,
    EHCI_QUEUE_HEAED = 1,
    EHCI_QUEUE_SPLIT_TRANS_ISOCHRONOUS_TD = 2,
    EHCI_QUEUE_FRAME_SPAN_TRAV_NODE = 3
} EhciQueueType;

typedef struct EhciHorizLinkPointer {
    uint32_t terminate : 1;         // Set if this is the last Queue Head in a Periodic List. Not used for Asynchronous List
    uint32_t next_queue_type : 2;
    uint32_t reserved : 2;
    uint32_t next_queue_head : 27;  // Address of the next Queue Head in the ring
} ATTR_PACKED EhciHorizLinkPointer;

typedef enum EndpointSpeed {
    EHCI_ENDP_SPEED_FULL = 0,
    EHCI_ENDP_SPEED_LOW = 1,
    EHCI_ENDP_SPEED_HIGH = 2
} EndpointSpeed;

typedef struct EndpointCharacteristics {
    uint32_t device_address : 7;
    uint32_t inactive : 1;          // Only used in Periodic List
    uint32_t endp_number : 4;
    uint32_t endp_speed : 2;
    uint32_t data_toggle_ctrl : 1;  // Set if data toggle should use value from TD
    uint32_t reclam_list_head : 1;  // Set if this is the first Queue Head in an Asynchronous List
    uint32_t max_packet_length : 11;
    uint32_t ctrl_endp : 1;         // Not used for High Speed devices
    uint32_t nak_reload : 4;
} ATTR_PACKED EndpointChars;

typedef struct EndpointCapabilities {
    uint32_t intr_sched_mask : 8;
    uint32_t split_complet_mask : 8;
    uint32_t hub_address : 7;
    uint32_t port_number : 7;
    uint32_t bandwidth_pipe_mul : 2; // Must be greater than zero
} ATTR_PACKED EndpointCaps;

typedef struct EhciQueueHead {
    uint32_t link_ptr;          // Queue Head Horizontal Link Pointer
    EndpointChars endp_chars;   // Endpoint Characteristics
    EndpointCaps endp_caps;     // Endpoint Capabilities
    uint32_t curr_td;           // Current TD address

    // Matches a transfer descriptor
    EhciTransferDescriptor curr_td_work_area;
} ATTR_PACKED EhciQueueHead;

typedef struct EhciController {
    USB_DEV_STRUCT_IMPL;

    CapabilityReg* cap_reg;
    UsbOperRegs* oper_regs;
} EhciController;

Status init_ehci();