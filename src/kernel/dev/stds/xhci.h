#pragma once

#include "definitions.h"
#include "pci.h"
#include "usb.h"

#include "utils/list.h"

typedef union XStructParams1 {
    struct {
        uint32_t max_dev_slots : 8;
        uint32_t max_interrupters : 11;
        uint32_t reserved : 5;
        uint32_t max_ports : 8;
    };
    uint32_t value;
} ATTR_PACKED XStructParams1;

typedef union XStructParams2 {
    struct {
        uint32_t isoch_sched_thresh: 4;
        uint32_t event_ring_table_max : 4;
        uint32_t reserved : 13;
        uint32_t max_scratch_pad_hi : 5;
        uint32_t scratch_restore : 1;
        uint32_t max_scratch_pad_lo : 5;
    };
    uint32_t value;
} ATTR_PACKED XStructParams2;

typedef union XStructParams3 {
    struct {
        uint32_t u1_dev_exit_latency : 8; // 0 = none; >1 = less than 'x' mircosec
        uint32_t reserved : 8;
        uint32_t u2_dev_exit_latency : 16; // 0 = none; >1 = less than 'x' mircosec
    };
    uint32_t value;
} ATTR_PACKED XStructParams3;

typedef union XCapabilityParams1 {
    struct {
        uint32_t ac64 : 1;
        uint32_t bnc : 1;
        uint32_t csz : 1;
        uint32_t ppc : 1;
        uint32_t pind : 1;
        uint32_t lhrc : 1;
        uint32_t ltc : 1;
        uint32_t nss : 1;
        uint32_t pae : 1;
        uint32_t spc : 1;
        uint32_t sec : 1;
        uint32_t cfc : 1;

        uint32_t max_psa_size : 4;
        uint32_t ext_cap_ptr : 16; // value = ('n' >> 2)
    };
    uint32_t value;
} ATTR_PACKED XCapabilityParams1;

typedef union XCapabilityParams2 {
    struct {
        uint32_t u3c : 1;
        uint32_t cmc : 1;
        uint32_t fcs : 1;
        uint32_t ctc : 1;
        uint32_t lec : 1;
        uint32_t cic : 1;
        uint32_t etc : 1;
        uint32_t etc_tsc : 1;
        uint32_t gsc : 1;
        uint32_t vtc : 1;

        uint32_t reserved : 22; // val = (real val >> 2)
    };
    uint32_t value;
} ATTR_PACKED XCapabilityParams2;

typedef struct XCapabilityReg {
    struct {
        uint32_t length : 8;             //Capability Register Length
        uint32_t reserved : 8;

        uint32_t version_1 : 4; // BCD
        uint32_t version_2 : 4; // BCD
        uint32_t version_3 : 4; // BCD
        uint32_t version_4 : 4; // BCD
    };

    XStructParams1 struct_params_1;
    XStructParams2 struct_params_2;
    XStructParams3 struct_params_3;

    XCapabilityParams1 cap_params_1;
    uint32_t doorbell_off;
    uint32_t rt_regs_space_off;
    XCapabilityParams2 cap_params_2;
} ATTR_PACKED ATTR_ALIGN(4) XCapabilityReg;

typedef struct XUsbCommandReg {
    uint32_t run : 1;
    uint32_t host_reset : 1;
    uint32_t intr_enable : 1;
    uint32_t host_sys_err_enable : 1;

    uint32_t reserved_1 : 3;

    uint32_t light_host_reset : 1;
    uint32_t contr_save_state : 1;
    uint32_t contr_rest_state : 1;
    uint32_t enable_wrap_event : 1;
    uint32_t enable_u3_mfi_stop : 1;

    uint32_t reserved_2 : 1;

    uint32_t cem_enable : 1;
    uint32_t ex_tbc_enable : 1;
    uint32_t ex_tsc_enable : 1;
    uint32_t vtio_enable : 1;

    uint32_t reserved_3 : 15;
} ATTR_PACKED XUsbCommandReg;

typedef union XUsbStatusReg {
    struct {
        uint32_t host_contrl_hltd : 1;
        uint32_t reserved_1 : 1;
        uint32_t host_sys_err : 1;
        uint32_t event_intr : 1;
        uint32_t port_change_detc : 1;
    
        uint32_t reserved_2 : 3;

        uint32_t save_state_stat : 1;
        uint32_t rest_state_stat : 1;
        uint32_t sv_rs_error : 1; // Save/Restore error
        uint32_t contrl_not_ready : 1;
        uint32_t host_contrl_err : 1;

        uint32_t reserved_3 : 19;
    };
    uint32_t value;
} ATTR_PACKED XUsbStatusReg;

typedef union XDevNotifCtrlReg {
    struct {
        uint32_t n0 : 1;
        uint32_t n1 : 1;
        uint32_t n2 : 1;
        uint32_t n3 : 1;
        uint32_t n4 : 1;

        uint32_t n5 : 1;
        uint32_t n6 : 1;
        uint32_t n7 : 1;
        uint32_t n8 : 1;
        uint32_t n9 : 1;

        uint32_t n10 : 1;
        uint32_t n11 : 1;
        uint32_t n12 : 1;
        uint32_t n13 : 1;
        uint32_t n14 : 1;

        uint32_t n15 : 1;

        uint32_t reserved : 16;
    };
    uint32_t value;
} ATTR_PACKED XDevNotifCtrlReg;

typedef union XCmdRingCtrlReg {
    struct {
        uint32_t ring_cycl_state : 1;
        uint32_t cmd_stop : 1;
        uint32_t cmd_abort : 1;
        uint32_t cmd_ring_running : 1; // Read-only

        uint32_t reserved : 2;
        uint32_t : 26;
    };
    uint64_32_t ring_ptr;
} ATTR_PACKED XCmdRingCtrlReg;

typedef struct XConfigureReg {
    uint32_t max_dev_slots_enable : 8;
    uint32_t u3_entry_enable : 1;
    uint32_t conf_info_enable : 1;

    uint32_t reserved : 22;
} ATTR_PACKED XConfigureReg;

typedef struct XUsbOperRegs {
    XUsbCommandReg command_reg;
    XUsbStatusReg status_reg;

    uint32_t page_size; // size = 2^('n'+12)
    uint32_t reserved_1[2];

    XDevNotifCtrlReg dev_notif_ctrl;
    XCmdRingCtrlReg cmd_ring_ctrl; // 64-bit

    uint32_t reserved_2[4];
    uint64_32_t dev_context_base;
    XConfigureReg configure;
} ATTR_PACKED ATTR_ALIGN(4) XUsbOperRegs;

typedef enum XPortIndicatorCtrl {
    XPORT_IND_OFF = 0,
    XPORT_IND_AMBER = 1,
    XPORT_IND_GREEN = 2,
    XPORT_IND_UNDEFINED = 3
} XPortIndicatorCtrl;

typedef struct XPortStatCtrlReg {
    uint32_t curr_conn_stat : 1;
    uint32_t on_off : 1;

    uint32_t reserved_1 : 1;

    uint32_t over_curr_active : 1;
    uint32_t reset : 1;

    uint32_t link_state : 4;

    uint32_t power : 1;
    uint32_t speed : 4;
    uint32_t indicator_ctrl : 2;
    uint32_t link_state_wr_strb : 1;

    uint32_t conn_stat_change : 1;
    uint32_t on_off_change : 1;
    uint32_t warm_reset_change : 1;
    uint32_t over_curr_change : 1;
    uint32_t reset_change : 1;
    uint32_t link_state_change : 1;
    uint32_t conf_err_change : 1;
    uint32_t cold_attach_stat : 1;
    uint32_t wake_conn_enable : 1;
    uint32_t wake_disc_enable : 1;
    uint32_t wake_over_curr_enable : 1;

    uint32_t reserved_2 : 2;

    uint32_t dev_removable : 1;
    uint32_t warm_reset : 1;
} ATTR_PACKED XPortStatCtrlReg;

typedef enum PortTestCtrl {
    PORT_TEST_DISABLED = 0,
    PORT_TEST_J_STATE = 1,
    PORT_TEST_K_STATE = 2,
    PORT_TEST_SE0_NAK = 3,
    PORT_TEST_PACKET = 4,
    PORT_TEST_FORCE_ENABLE = 5,
    PORT_TEST_ERROR = 15
} PortTestCtrl;

typedef union XPortPowerStatCtrlReg {
    struct {
        uint32_t u1_timeout : 8; // microsec
        uint32_t u2_timeout : 8; // 256 * microsec
        uint32_t force_link_pm_accept : 1;

        uint32_t reserved : 15; 
    } u3;
    struct {
        uint32_t l1_stat : 3;
        uint32_t remote_wake_enable : 1;
        uint32_t best_eff_serv_latency : 4;
        uint32_t l1_dev_slot : 8;
        uint32_t hardwr_lpm_enable : 1;

        uint32_t reserved : 11;
        uint32_t test_ctrl : 4;
    } u2;
} XPortPowerStatCtrlReg;

typedef struct XPortLinkInfoReg {
    uint32_t link_err_count : 16;
    uint32_t rx_lane_count : 4;
    uint32_t tx_lane_count : 4;

    uint32_t reserved : 8;
} ATTR_PACKED XPortLinkInfoReg;

typedef struct XPortHardLPMCtrlReg {
    uint32_t host_init_res_dur_mode : 2;
    uint32_t l1_timeout : 8; // 128 + (n * 128) microsec
    uint32_t best_eff_serv_latency_deep : 4;
    uint32_t reserved : 18;
} ATTR_PACKED XPortHardLPMCtrlReg;

typedef struct XPortReg {
    XPortStatCtrlReg stat_ctrl;
    XPortPowerStatCtrlReg power_stat_ctrl;

    XPortLinkInfoReg link_info; // USB2 reserved
    XPortHardLPMCtrlReg hardware_lmp_ctrl; // USB3 reserved
} ATTR_PACKED ATTR_ALIGN(4) XPortReg;

typedef struct XEventRingSegTableEntry {
    uint64_32_t seg_base;
    uint32_t seg_size;
    uint32_t reserved_1;
} ATTR_PACKED XEventRingSegTableEntry;

typedef struct XRuntimeIntrReg {
    struct {
        uint32_t intr_pending : 1;
        uint32_t intr_enable : 1;
        uint32_t reserved_1 : 30;
    };

    struct {
        uint32_t intr_moder_interval : 16;
        uint32_t intr_moder_counter : 16;
    };

    uint32_t event_ring_seg_table_size;
    uint32_t reserved_2;
    uint64_32_t event_ring_seg_table_base;
    uint64_32_t event_ring_dequeue;
} ATTR_PACKED XRuntimeIntrReg;

typedef struct XRuntimeRegs {
    uint32_t microframe_idx;
    uint32_t pad[7];
    XRuntimeIntrReg intr_regs[];
} ATTR_PACKED ATTR_ALIGN(4) XRuntimeRegs;

#pragma region Transfer Ring

typedef struct XTransferDescriptor {
    uint32_t next_link; // Standard next link pointer
    uint32_t alt_link; 
    uint32_t token;
    uint32_t buffer_prt[5];
} ATTR_PACKED XTransferDescriptor;

typedef union XTrbStatus {
    struct {
        uint32_t length : 17;
        uint32_t td_size : 5;
        uint32_t intr_target : 10;
    };
    uint32_t value;
} ATTR_PACKED XTrbStatus;

typedef enum XTransferType {
    TRT_NO = 0,
    TRT_RESERVED = 1,
    TRT_OUT = 2,
    TRT_IN = 3
} XTransferType;

typedef enum XTrbType {
    TRB_RESERVED = 0,

    // Transfer TRB
    TRB_NORMAL = 1,
    TRB_SETUP_STAGE = 2,
    TRB_DATA_STAGE = 3,
    TRB_STATUS_STAGE = 4,
    TRB_ISOCH = 5,
    TRB_LINK = 6,
    TRB_EVENT_DATA = 7,
    TRB_NO_OP = 8,

    // Command TRB
    TRB_ENABLE_SLOT_CMD = 9,
    TRB_DISABLE_SLOT_CMD = 10,
    TRB_ADDR_DEV_CMD = 11,
    TRB_CONF_ENDPOINT_CMD = 12,
    TRB_EVAL_CONTEXT_CMD = 13,
    TRB_RESET_ENDPOINT_CMD = 14,
    TRB_STOP_ENDPOINT_CMD = 15,
    TRB_SET_TR_DEQ_PTR_CMD = 16,
    TRB_RESET_DEV_CMD = 17,
    TRB_FORCE_EVENT_CMD = 18,
    TRB_NEG_BANDWIDTH_CMD = 19,
    TRB_SET_LATENCY_TOLER_VAL_CMD = 20,
    TRB_GET_PORT_BANDWIDTH_CMD = 21,
    TRB_FORCE_HEADER_CMD = 22,
    TRB_NO_OP_CMD = 23,
    TRB_GET_EX_PROP_CMD = 24,
    TRB_SET_EX_PROP_CMD = 25,

    // Event TRB
    TRB_TRANSFER_EVENT = 32,
    TRB_CMD_COMPL_EVENT = 33,
    TRB_PORT_STAT_CHANGE_EVENT = 34,
    TRB_BANDWIDTH_REQUEST_EVENT = 35,
    TRB_DOORBELL_EVENT = 36,
    TRB_HOST_CONTRL_EVENT = 37,
    TRB_DEV_NOTIF_WRAP_EVENT = 38,
    TRB_MF_IDX_WRAP_EVENT = 39,
} XTrbType;

typedef union XTrbControl {
    struct { // Normal TRB
        uint32_t cycle : 1;
        uint32_t eval_next_trb : 1;
        uint32_t intr_sp : 1;
        uint32_t no_snoop : 1; 
        uint32_t chain : 1;
        uint32_t intr_compl : 1;
        uint32_t imm_data : 1;
        uint32_t reserved_1 : 2;
        uint32_t block_intr : 1;
        uint32_t trb_type : 6;
        uint32_t transfer_type : 2;
        uint32_t reserved_2 : 14;
    };
    struct { // Link TRB
        uint32_t : 1;
        uint32_t toggle_cycle : 1;
        uint32_t : 30;
    };
    uint32_t value;
} ATTR_PACKED XTrbControl;

typedef struct XssTrb {
    union {
        struct {
            uint32_t bm_req_type : 8;
            uint32_t bm_request : 8;
            uint32_t w_value : 16;
        };
        uint32_t dword_1;
    };
    union {
        struct {
            uint32_t w_index : 16;
            uint32_t w_length : 16;
        };
        uint32_t dword_2;
    };
} ATTR_PACKED XssTrb;

typedef struct XTransferRequestBlock {
    union {
        uint64_32_t buffer_ptr;
        uint64_32_t data;
        XssTrb setup_stage;
    };

    XTrbStatus status;
    XTrbControl ctrl;
} ATTR_PACKED XTransferRequestBlock;

#pragma endregion

typedef enum XDevContextDoorbellTarget {
    DB_TARGET_RESERVED = 0,     // Enqueue ptr update
    DB_TARGET_CTRL_EP_0 = 1,    // Enqueue ptr update
    DB_TARGET_EP_1_OUT = 2,     // Enqueue ptr update
    DB_TARGET_EP_1_IN = 3,      // Enqueue ptr update
} XDevContextDoorbellTarget;

typedef enum XHostContrlDoorbellTarget {
    DB_TARGET_COMMAND = 0
} XHostContrlDoorbellTarget;

typedef struct XDoorbellReg {
    uint32_t target : 8;
    uint32_t reserved : 8;
    uint32_t stream_id : 16;
} ATTR_PACKED XDoorbellReg;

typedef struct XhciDoorbellRegs {
    XDoorbellReg doorbell[256];
} ATTR_PACKED XhciDoorbellRegs;

typedef struct XhciRing {
    uint32_t enqueue;
    uint32_t dequeue;

    XTransferRequestBlock* entries;
} XhciRing;

typedef enum XExtCapabilityID {
    XHCI_ECAP_RESERVED = 0,
    XHCI_ECAP_USB_LEG_SUP = 1,
    XHCI_ECAP_SUP_PROT = 2,
    XHCI_ECAP_EX_POWER_MGMT = 3,
    XHCI_ECAP_IO_VIRT = 4,
    XHCI_ECAP_MSG_INTR = 5,
    XHCI_ECAP_LOCAL_MEM = 6,

    XHCI_ECAP_USB_DBG = 10,

    XHCI_ECAP_EX_MSG_INTR = 17,
} XExtCapabilityID;

typedef struct XUsbLegSupportCap {
    uint32_t capabilty_id : 8;
    uint32_t next_ext_cap_ptr : 8; // value = ('n' << 2)

    uint32_t hc_bios_owned_sem : 1;

    uint32_t reserved_1 : 7;

    uint32_t hc_os_owned_sem : 1;

    uint32_t reserved_2 : 7;
} ATTR_PACKED XUsbLegSupportCap;

typedef struct XUsbLegSupportCtrlStat {
    uint32_t usb_smi_enable : 1;

    uint32_t reserved_1 : 3;

    uint32_t smi_host_sys_err_enable : 1;

    uint32_t reserved_2 : 8;

    uint32_t smi_os_own_enable : 1;
    uint32_t smi_pci_cmd_enable : 1;
    uint32_t smi_bar_enable : 1;
    uint32_t smi_event_intr : 1;

    uint32_t reserved_3 : 3;

    uint32_t smi_host_sys_err : 1;

    uint32_t reserved_4 : 8;

    uint32_t smi_os_own_change : 1;
    uint32_t smi_pci_cmd : 1;
    uint32_t smi_on_bar : 1;
} ATTR_PACKED XUsbLegSupportCtrlStat;

typedef struct XUsbLegacySupport {
    XUsbLegSupportCap capability;
    XUsbLegSupportCtrlStat ctrl_stat;
} ATTR_PACKED XUsbLegacySupport;

typedef union XExtCapPtrReg {
    struct {
        uint32_t capabilty_id : 8;
        uint32_t next_ext_cap_ptr : 8; // value = ('n' << 2)
        uint32_t specific : 16;
    };
    uint32_t value;
} ATTR_PACKED XExtCapPtrReg;

typedef enum XSlotState {
    XSLOT_STATE_DIS_ENB = 0,
    XSLOT_STATE_DEFAULT = 1,
    XSLOT_STATE_ADDRESSED = 2,
    XSLOT_STATE_CONFIGURED = 3
} XSlotState;

typedef struct XSlotContext {
    struct {
        uint32_t route_string : 20;
        uint32_t speed: 4;

        uint32_t reserved_1 : 1;

        uint32_t multi_tt : 1;
        uint32_t hub : 1;

        uint32_t ctx_entries : 5;
    };
    struct {
        uint32_t max_exit_latency : 16;
        uint32_t root_hub_port : 8;
        uint32_t ports_count : 8;
    };
    struct {
        uint32_t parent_hub_slot : 8;
        uint32_t parent_port : 8;
        uint32_t tt_time : 2; // 8 + ('n' * 8) FS
        
        uint32_t reserved_2 : 4;

        uint32_t intr_target : 10;
    };
    struct {
        uint32_t usb_dev_addr : 8;

        uint32_t reserved_3 : 19;

        uint32_t state : 5;
    };

    uint32_t reserved_4[4];
} ATTR_PACKED XSlotContext;

typedef enum XEndpointState {
    XENDP_STATE_DISABLED = 0,
    XENDP_STATE_RUNNIGN = 1,
    XENDP_STATE_HALTED = 2,
    XENDP_STATE_STOPPED = 3,
    XENDP_STATE_ERROR = 4
} XEndpointState;

typedef enum XEndpointType {
    XENDP_TYPE_NOT_VALID = 0,

    XENDP_TYPE_ISOCH_OUT = 1,
    XENDP_TYPE_BULK_OUT = 2,
    XENDP_TYPE_INTR_OUT = 3,

    XENDP_TYPE_CTRL_BIDIR = 4,

    XENDP_TYPE_ISOCH_IN = 5,
    XENDP_TYPE_BULK_IN = 6,
    XENDP_TYPE_INTR_IN = 7
} XEndpointType;

typedef struct XEndpointContext {
    struct {
        uint32_t state : 3;

        uint32_t reserved_1 : 5;

        uint32_t mult : 2;
        uint32_t max_prim_streams : 5;
        uint32_t linear_stream_arr : 1;
        uint32_t interval : 8;
        uint32_t max_esit_payload_hi : 8;
    };
    struct {
        uint32_t reserved_2 : 1;

        uint32_t error_count : 2;
        uint32_t type : 3;

        uint32_t reserved_3 : 1;

        uint32_t host_init_disable : 1;
        uint32_t max_burst_size : 8;
        uint32_t max_packet_size : 16;
    };
    union {
        struct {
            struct {
                uint32_t deq_cycle_state : 1;
                uint32_t reserved_4 : 3;
                uint32_t tr_dequeue_ptr_lo : 28;
            };
            uint32_t tr_dequeue_ptr_hi;
        };
        uint64_t tr_dequeue_ptr;
    };
    struct {
        uint32_t average_trb_len : 16;
        uint32_t max_esit_payload_lo : 16;
    };

    uint32_t reserved_5[3];
} ATTR_PACKED XEndpointContext;

typedef struct XStreamContext {
    struct {
        uint32_t deq_cycle_state : 1;
        uint32_t type : 3;
        uint32_t tr_dequeue_ptr_lo : 28; 
    };

    uint32_t tr_dequeue_ptr_hi;

    struct {
        uint32_t stopped_edtla : 24;
        uint32_t reserved_1 : 8;
    };

    uint32_t reserved_2;
} ATTR_PACKED XStreamContext;

typedef struct XInputCtrlContext {
    uint32_t drop_flags; // D0-D1 is reserved
    uint32_t add_flags;

    uint32_t reserved_1[5];

    struct {
        uint32_t conf_value : 8;
        uint32_t interface_num : 8;
        uint32_t alt_setting : 8;

        uint32_t reserved_2 : 8;
    };
} ATTR_PACKED XInputCtrlContext;

typedef struct XPortBandwidthContext {
    struct {
        uint32_t reserved_1 : 8;

        uint32_t port_1 : 8;
        uint32_t port_2 : 8;
        uint32_t port_3 : 8;
    };
    
    struct XPortBW {
        uint32_t port_0 : 8;
        uint32_t port_1 : 8;
        uint32_t port_2 : 8;
        uint32_t port_3 : 8;
    } ports[];
} ATTR_PACKED XPortBandwidthContext;

typedef struct XDeviceContext {
    XSlotContext slot_ctx;
} ATTR_PACKED XDeviceContext;

typedef struct XhciController {
    USB_DEV_STRUCT_IMPL;

    PciDevice* pci_dev;

    volatile XCapabilityReg* cap_reg;
    volatile XExtCapPtrReg* ext_cap;

    volatile XUsbOperRegs* oper_regs;
    volatile XPortReg* port_regs;
    volatile XRuntimeRegs* rt_regs;
    volatile XRuntimeIntrReg* intr_set;

    uint16_t page_size;
    uint16_t dev_ctx_size;
    uint16_t slots_count;
    uint16_t intr_count;

    // Device Context Array
    XDeviceContext** dev_context;

    // Rings
    XhciRing cmd_ring;
    XhciRing transfer_ring;

    XEventRingSegTableEntry* event_table;
} XhciController;

bool_t is_xhci_controller(const PciDevice* const pci_dev);

Status init_xhci_controller(PciDevice* const pci_dev);