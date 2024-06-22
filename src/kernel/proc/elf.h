#pragma once

#include "definitions.h"

#include "fs/vfs.h"

/*
ELF File format description.
*/

#define ELF_MAGIC 0x464C457F

#define ELF_INTERP_IGNORE "/lib/ld64.so.1"

typedef enum ElfType {
    ELF_TYPE_NONE = 0x00,
    ELF_TYPE_RELOC = 0x01,
    ELF_TYPE_EXEC = 0x02,
    ELF_TYPE_DYN = 0x03,
    ELF_TYPE_CORE = 0x04,

    ELF_TYPE_LOOS = 0xFE00,
    ELF_TYPE_HIOS = 0xFEFF,
    ELF_TYPE_LOPROC = 0xFF00,
    ELF_TYPE_HIPROC = 0xFFFF
} ElfType;

typedef enum {
    ELF_MACHINE_NONE = 0x00,
    ELF_MACHINE_ATT_WE32100 = 0x01,
    ELF_MACHINE_SPARC = 0x02,
    ELF_MACHINE_X86 = 0x03,
    ELF_MACHINE_M68K = 0x04,
    ELF_MACHINE_M88K = 0x05,
    ELF_MACHINE_INTEL_MCU = 0x06,
    ELF_MACHINE_INTEL_80860 = 0x07,
    ELF_MACHINE_MIPS = 0x08,
    ELF_MACHINE_IBM_SYSTEM_370 = 0x09,
    ELF_MACHINE_MIPS_RS3000_LITTLE_ENDIAN = 0x0A,
    ELF_MACHINE_RESERVED_START = 0x0B,
    ELF_MACHINE_RESERVED_END = 0x0E,
    ELF_MACHINE_HP_PA_RISC = 0x0F,
    ELF_MACHINE_INTEL_80960 = 0x13,
    ELF_MACHINE_POWERPC = 0x14,
    ELF_MACHINE_POWERPC_64 = 0x15,
    ELF_MACHINE_S390 = 0x16,
    ELF_MACHINE_IBM_SPU_SPC = 0x17,
    ELF_MACHINE_RESERVED2_START = 0x18,
    ELF_MACHINE_RESERVED2_END = 0x23,
    ELF_MACHINE_NEC_V800 = 0x24,
    ELF_MACHINE_FUJITSU_FR20 = 0x25,
    ELF_MACHINE_TRW_RH32 = 0x26,
    ELF_MACHINE_MOTOROLA_RCE = 0x27,
    ELF_MACHINE_ARM = 0x28,
    ELF_MACHINE_DIGITAL_ALPHA = 0x29,
    ELF_MACHINE_SUPERH = 0x2A,
    ELF_MACHINE_SPARC_V9 = 0x2B,
    ELF_MACHINE_SIEMENS_TRICORE = 0x2C,
    ELF_MACHINE_ARGONAUT_RISC_CORE = 0x2D,
    ELF_MACHINE_HITACHI_H8300 = 0x2E,
    ELF_MACHINE_HITACHI_H8300H = 0x2F,
    ELF_MACHINE_HITACHI_H8S = 0x30,
    ELF_MACHINE_HITACHI_H8500 = 0x31,
    ELF_MACHINE_IA64 = 0x32,
    ELF_MACHINE_STANFORD_MIPS_X = 0x33,
    ELF_MACHINE_MOTOROLA_COLDFIRE = 0x34,
    ELF_MACHINE_MOTOROLA_M68HC12 = 0x35,
    ELF_MACHINE_FUJITSU_MMA = 0x36,
    ELF_MACHINE_SIEMENS_PCP = 0x37,
    ELF_MACHINE_SONY_NCUP = 0x38,
    ELF_MACHINE_DENSO_NDR1 = 0x39,
    ELF_MACHINE_MOTOROLA_STARCORE = 0x3A,
    ELF_MACHINE_TOYOTA_ME16 = 0x3B,
    ELF_MACHINE_ST_MICROELECTRONICS_ST100 = 0x3C,
    ELF_MACHINE_ADVANCED_LOGIC_TINYJ = 0x3D,
    ELF_MACHINE_AMD_X86_64 = 0x3E,
    ELF_MACHINE_SONY_DSP = 0x3F,
    ELF_MACHINE_DEC_PDP_10 = 0x40,
    ELF_MACHINE_DEC_PDP_11 = 0x41,
    ELF_MACHINE_SIEMENS_FX66 = 0x42,
    ELF_MACHINE_ST_MICROELECTRONICS_ST9_PLUS = 0x43,
    ELF_MACHINE_ST_MICROELECTRONICS_ST7 = 0x44,
    ELF_MACHINE_MOTOROLA_MC68HC16 = 0x45,
    ELF_MACHINE_MOTOROLA_MC68HC11 = 0x46,
    ELF_MACHINE_MOTOROLA_MC68HC08 = 0x47,
    ELF_MACHINE_MOTOROLA_MC68HC05 = 0x48,
    ELF_MACHINE_SGI_SVX = 0x49,
    ELF_MACHINE_ST_MICROELECTRONICS_ST19 = 0x4A,
    ELF_MACHINE_DIGITAL_VAX = 0x4B,
    ELF_MACHINE_AXIS_COMMUNICATIONS = 0x4C,
    ELF_MACHINE_INFINEON_32_BIT = 0x4D,
    ELF_MACHINE_ELEMENT14_DSP = 0x4E,
    ELF_MACHINE_LSI_LOGIC_DSP = 0x4F,
    ELF_MACHINE_TMS320C6000_FAMILY = 0x8C,
    ELF_MACHINE_MCST_E2K = 0xAF,
    ELF_MACHINE_ARM_64 = 0xB7,
    ELF_MACHINE_ZILOG_Z80 = 0xDC,
    ELF_MACHINE_RISCV = 0xF3,
    ELF_MACHINE_BPF = 0xF7,
    ELF_MACHINE_WDC_65C816 = 0x101
} ElfMachineType;

typedef enum ElfIdentArch {
    ELF_IDENT_ARCH_X86 = 0x1,
    ELF_IDENT_ARCH_X64 = 0x2
} ElfIdentArch;

typedef enum ElfOsABI {
    ELF_OSABI_SYSV = 0x00,
    ELF_OSABI_HPUX = 0x01,
    ELF_OSABI_NETBSD = 0x02,
    ELF_OSABI_LINUX = 0x03,
    ELF_OSABI_GNU_HURD = 0x04,
    ELF_OSABI_SOLARIS = 0x06,
    ELF_OSABI_AIX = 0x07,
    ELF_OSABI_IRIX = 0x08,
    ELF_OSABI_FREEBSD = 0x09,
    ELF_OSABI_TRU64 = 0x0A,
    ELF_OSABI_NOVELL_MODESTO = 0x0B,
    ELF_OSABI_OPENBSD = 0x0C,
    ELF_OSABI_OPENVMS = 0x0D,
    ELF_OSABI_NONSTOP_KERNEL = 0x0E,
    ELF_OSABI_AROS = 0x0F,
    ELF_OSABI_FENIXOS = 0x10,
    ELF_OSABI_NUXI_CLOUDABI = 0x11,
    ELF_OSABI_STRATUS_OPENVOS = 0x12
} ElfOsABI;

typedef struct ELF {
    uint8_t ident_magic[4];
    uint8_t ident_arch;
    uint8_t ident_byte_order;
    uint8_t ident_version;
    uint8_t ident_os_abi;
    uint8_t ident_os_abi_version;
    uint8_t reserved0[7];
    uint16_t type;
    uint16_t machine;
    uint32_t version;
    uint64_t entry;
    uint64_t ph_offset;
    uint64_t sh_offset;
    uint32_t flags;
    uint16_t header_size;
    uint16_t prog_header_entry_size;
    uint16_t prog_header_entries_count;
    uint16_t sect_header_entry_size;
    uint16_t sect_header_entries_count;
    uint16_t sect_names_entry_idx;
} ATTR_PACKED ELF;

typedef enum ElfProgramType {
    ELF_PROG_TYPE_NULL = 0x00000000,
    ELF_PROG_TYPE_LOAD = 0x00000001,
    ELF_PROG_TYPE_DYNAMIC = 0x00000002,
    ELF_PROG_TYPE_INTERP = 0x00000003,
    ELF_PROG_TYPE_NOTE = 0x00000004,
    ELF_PROG_TYPE_SHLIB = 0x00000005,
    ELF_PROG_TYPE_PHDR = 0x00000006,
    ELF_PROG_TYPE_TLS = 0x00000007,
    ELF_PROG_TYPE_LOOS = 0x60000000,
    ELF_PROG_TYPE_HIOS = 0x6FFFFFFF,
    ELF_PROG_TYPE_LOPROC = 0x70000000,
    ELF_PROG_TYPE_HIPROC = 0x7FFFFFFF
} ElfProgramType;

typedef enum ElfProgramSegmentFlags {
    ELF_PROG_FLAGS_EXEC = 0x1,
    ELF_PROG_FLAGS_WRITEABLE = 0x2,
    ELF_PROG_FLAGS_READABLE = 0x4
} ElfProgramSegmentFlags;

typedef struct ElfProgramHeader {
    uint32_t type;
    uint32_t flags;
    uint64_t offset;
    uint64_t virt_address;
    uint64_t phys_address;
    uint64_t file_size;
    uint64_t memory_size;
    uint64_t align;
} ATTR_PACKED ElfProgramHeader;

typedef enum ElfDynamicTag {
    ELF_DYN_TAG_NULL = 0x0,
    ELF_DYN_TAG_NEEDED = 0x1,
    ELF_DYN_TAG_PLTRELSZ = 0x2,
    ELF_DYN_TAG_PLTGOT = 0x3,
    ELF_DYN_TAG_HASH = 0x4,
    ELF_DYN_TAG_STRTAB = 0x5,
    ELF_DYN_TAG_SYMTAB = 0x6,
    ELF_DYN_TAG_RELA = 0x7,
    ELF_DYN_TAG_RELASZ = 0x8,
    ELF_DYN_TAG_RELAENT = 0x9,
    ELF_DYN_TAG_STRSZ = 0x10,
    ELF_DYN_TAG_SYMENT = 0x11,
    ELF_DYN_TAG_INIT = 0x12,
    ELF_DYN_TAG_FINI = 0x13,
    ELF_DYN_TAG_SONAME = 0x14,
    ELF_DYN_TAG_RPATH = 0x15,
    ELF_DYN_TAG_SYMBOLIC = 0x16,
    ELF_DYN_TAG_REL = 0x17,
    ELF_DYN_TAG_RELSZ = 0x18,
    ELF_DYN_TAG_RELENT = 0x19,
    ELF_DYN_TAG_PLTREL = 0x20,
    ELF_DYN_TAG_DEBUG = 0x21,
    ELF_DYN_TAG_TEXTREL = 0x22,
    ELF_DYN_TAG_JMPREL = 0x23,
    ELF_DYN_TAG_LOPROC = 0x70000000,
    ELF_DYN_TAG_HIPROC = 0x7fffffff
} ElfDynamicTag;

typedef struct ElfDynamicEntry {
    uint64_t tag;
    union {
        uint64_t value;
        uint64_t ptr;
    };
} ATTR_PACKED ElfDynamicEntry;

typedef enum ElfSectionType {
    ELF_SECTION_TYPE_NULL = 0x0,
    ELF_SECTION_TYPE_PROGBITS = 0x1,
    ELF_SECTION_TYPE_SYMTAB = 0x2,
    ELF_SECTION_TYPE_STRTAB = 0x3,
    ELF_SECTION_TYPE_RELA = 0x4,
    ELF_SECTION_TYPE_HASH = 0x5,
    ELF_SECTION_TYPE_DYNAMIC = 0x6,
    ELF_SECTION_TYPE_NOTE = 0x7,
    ELF_SECTION_TYPE_NOBITS = 0x8,
    ELF_SECTION_TYPE_REL = 0x9,
    ELF_SECTION_TYPE_SHLIB = 0x0A,
    ELF_SECTION_TYPE_DYNSYM = 0x0B,
    ELF_SECTION_TYPE_INIT_ARRAY = 0x0E,
    ELF_SECTION_TYPE_FINI_ARRAY = 0x0F,
    ELF_SECTION_TYPE_PREINIT_ARRAY = 0x10,
    ELF_SECTION_TYPE_GROUP = 0x11,
    ELF_SECTION_TYPE_SYMTAB_SHNDX = 0x12,
    ELF_SECTION_TYPE_NUM = 0x13
} ElfSectionType;

typedef enum ElfSectionFlags {
    ELF_SECTION_FLAGS_WRITE = 0x1,
    ELF_SECTION_FLAGS_ALLOC = 0x2,
    ELF_SECTION_FLAGS_EXECINSTR = 0x4,
    ELF_SECTION_FLAGS_MERGE = 0x10,
    ELF_SECTION_FLAGS_STRINGS = 0x20,
    ELF_SECTION_FLAGS_INFO_LINK = 0x40,
    ELF_SECTION_FLAGS_LINK_ORDER = 0x80,
    ELF_SECTION_FLAGS_OS_NONCONFORMING = 0x100,
    ELF_SECTION_FLAGS_GROUP = 0x200,
    ELF_SECTION_FLAGS_TLS = 0x400,
    ELF_SECTION_FLAGS_MASKOS = 0x0FF00000,
    ELF_SECTION_FLAGS_MASKPROC = 0xF0000000,
    ELF_SECTION_FLAGS_ORDERED = 0x4000000,
    ELF_SECTION_FLAGS_EXCLUDE = 0x8000000
} ElfSectionFlags;

typedef struct ElfSectionHeader {
    uint32_t name_offset;
    uint32_t type;
    uint64_t flags;
    uint64_t virt_address;
    uint64_t offset;
    uint64_t size;
    uint32_t link;
    uint32_t info;
    uint64_t addr_align;
    uint64_t entry_size;
} ATTR_PACKED ElfSectionHeader;

/*
Struct used during loading programs from ELF files.
*/
typedef struct ElfFile {
    VfsDentry* dentry;

    ELF* header;
    ElfProgramHeader* progs;
} ElfFile;

typedef struct Process Process;

bool_t is_elf_valid(const ELF* elf);
bool_t is_elf_supported(const ELF* elf);

static inline bool_t is_elf_valid_and_supported(const ELF* elf) {
    return (is_elf_valid(elf) && is_elf_supported(elf));
}

const ElfProgramHeader* elf_find_prog(const ElfFile* elf_file, const ElfProgramType prog_type);

int elf_read_file(ElfFile* const elf_file);
void elf_free_file(ElfFile* const elf_file);

int elf_load(const ElfFile* elf_file, Process* const process);

void elf_test(VfsDentry* const file_dentry);