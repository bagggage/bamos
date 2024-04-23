#pragma once

#include "definitions.h"

#include "cpu/paging.h"

#include "utils/list.h"

#define VM_HEAP_MAX_SIZE (GB_SIZE * 512U)

typedef struct VMHeap {
    uint64_t virt_top;
    uint64_t virt_base;

    ListHead free_list;
} VMHeap;

bool_t vm_init_heap_manager();

/*
Initialize new virtual heap.
Heap base address can't be null. 
*/
void vm_heap_construct(VMHeap* heap, const uint64_t virt_base);

/*
Reserve virtual addresses range on heap.
Returns virtual address of the start of the region. 
*/
uint64_t vm_heap_reserve(VMHeap* heap, const uint32_t pages_count);

/*
Release virtual addresses range of heap previously reserved by 'vm_heap_reserve'.
*/
void vm_heap_release(VMHeap* heap, const uint64_t virt_address, const uint32_t pages_count);

VMHeap vm_heap_copy(const VMHeap* src_heap);

void log_heap(const VMHeap* heap);