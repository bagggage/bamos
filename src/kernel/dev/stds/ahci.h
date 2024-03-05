#pragma once 

#include "definitions.h"

typedef volatile struct HBAPort {
	uint32_t cl_base_address;		    // 0x00, command list base address, 1K-byte aligned
	uint32_t cl_base_address_upper;		// 0x04, command list base address upper 32 bits
	uint32_t FIS_base_address;		    // 0x08, FIS base address, 256-byte aligned
	uint32_t FIS_base_address_upper;    // 0x0C, FIS base address upper 32 bits
	uint32_t interrupt_status;		    // 0x10, interrupt status
	uint32_t interrupt_enable;		    // 0x14, interrupt enable
	uint32_t cmd;		                // 0x18, command and status
	uint32_t reserved0;		            // 0x1C, Reserved
	uint32_t task_file_data;		    // 0x20, task file data
	uint32_t signature;		            // 0x24, signature
	uint32_t sata_status;		        // 0x28, SATA status (SCR0:SStatus)
	uint32_t sata_control;		        // 0x2C, SATA control (SCR2:SControl)
	uint32_t sata_error;		        // 0x30, SATA error (SCR1:SError)
	uint32_t sata_active;               // 0x34, SATA active (SCR3:SActive)
	uint32_t command_issue;		        // 0x38, command issue
	uint32_t sata_notification;		    // 0x3C, SATA notification (SCR4:SNotification)
	uint32_t FIS_switch_control;        // 0x40, FIS-based switch control
	uint32_t reserved1[11];	            // 0x44 ~ 0x6F, Reserved
	uint32_t vendor[4];	                // 0x70 ~ 0x7F, vendor specific
} ATTR_PACKED HBAPort;
 
typedef volatile struct HBAMemory {
	uint32_t capability;		        // 0x00, Host capability
	uint32_t global_host_control;		// 0x04, Global host control
	uint32_t interrupt_status;		    // 0x08, Interrupt status
	uint32_t port_implemented;		    // 0x0C, Port implemented
	uint32_t version1;		            // 0x10, Version
	uint32_t ccc_control;	            // 0x14, Command completion coalescing control
	uint32_t ccc_ports;	                // 0x18, Command completion coalescing ports
	uint32_t em_location;	            // 0x1C, Enclosure management location
	uint32_t em_control;	            // 0x20, Enclosure management control
	uint32_t capability2;		        // 0x24, Host capabilities extended
	uint32_t bohc;		                // 0x28, BIOS/OS handoff control and status
	uint8_t  reserved[0xA0-0x2C]; 	    // 0x2C - 0x9F, Reserved
	uint8_t  vendor[0x100-0xA0];        // 0xA0 - 0xFF, Vendor specific registers
	HBAPort	 ports[1];	                // 1 ~ 32 0x100 - 0x10FF, Port control registers
} ATTR_PACKED HBAMemory;

Status init_ahci();

Status init_HBA_memory(uint8_t bus, uint8_t dev, uint8_t func);

bool_t is_ahci(uint8_t prog_if, uint8_t subclass);

void detect_ahci_devices_type();
