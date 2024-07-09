#pragma once

#ifdef X86_64
#include "arch/x86-64/arch.h"
using Arch = Arch_x86_64;
using PageTable = Arch::PageTable;
#endif