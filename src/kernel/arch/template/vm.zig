//! # Virtual memory module arch-dependent implementation template

/// High-level virtual memory module.
const vm = @import("../../vm.zig");

// Constants that must be defined for current architecture.

/// Architecture minimal page size.
pub const page_size = 0;

/// Linear Memory Access (LMA) region start address.
pub const lma_start = 0;
/// Linear Memory Access (LMA) region size.
pub const lma_size = 0;
/// Linear Memory Access (LMA) region end address.
pub const lma_end = 0;

/// The start virtual address of the kernel heap.
pub const heap_start = 0;

/// `PageTable` type.
/// Prefered to be an array.
/// 
/// If the architecture does not support paging,
/// this type should be compatible with the high-level memory module
/// and used for managing virtual memory instead of a page table.
pub const PageTable: type = undefined;

/// Initialization function.
/// This function is guaranteed to be called only once.
/// 
/// After successful execution, all architecture-dependent functions for
/// working with the module should be available: `mmap`, `unmap`, `allocPt`, `freePt`, and others.
/// 
/// In case of incorrect initialization, the function should return an error.
pub fn init() vm.Error!void {}

/// The function should implement the allocation
/// of a single page table ready for use.
/// 
/// Returns a pointer to the allocated page table,
/// or `null` if the allocation fails.
/// 
/// May be `inline`.
pub fn allocPt() ?*PageTable {}

/// The function should release memory and other
/// resources for the page table previously allocated
/// by the `allocPt` function.
/// 
/// May be `inline`.
pub fn freePt(pt: *PageTable) void {
    _ = pt;
}

/// The function should return the current page table
/// used by the CPU core on which this function is called.
/// 
/// May be `inline`.
pub fn getPt() *PageTable {}

/// The function should set the provided page table
/// as the current one used by the core, for example,
/// by writing to specific registers.
/// 
/// May be `inline`.
pub fn setPt(pt: *const PageTable) void {
    _ = pt;
}

/// The function should efficiently map the kernel
/// in the destination page table based on the source table.
/// The mapped sections should be shared across multiple tables simultaneously,
/// so that any future changes in the kernel mapping
/// in one table will affect the other tables as well.
///
/// For a better understanding, see `vm.newPt`
/// and the example implementation in `arch.x86-64.vm.clonePt`.
/// 
/// May be `inline`.
pub fn clonePt(src_pt: *const PageTable, dest_pt: *PageTable) void {
    _ = src_pt;
    _ = dest_pt;
}
