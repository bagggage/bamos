#pragma once

#include "definitions.h"

#include "vm.h"

#include "utils/list.h"

/*
Kernel object memory allocator.
*/

typedef struct MemoryBucket {
    LIST_STRUCT_IMPL(MemoryBucket);

    VMPageFrame page_frame;
    uint8_t* bitmap;

    uint32_t allocated_count;
} MemoryBucket;

typedef struct ObjectMemoryAllocator {
    ListHead bucket_list;

    uint32_t bucket_capacity;
    uint32_t object_size;
} ObjectMemoryAllocator;

ObjectMemoryAllocator* _oma_new(const uint32_t object_size, const uint32_t bucket_pages_count);
ObjectMemoryAllocator* oma_new(const uint32_t object_size);
void oma_delete(ObjectMemoryAllocator* oma);

ObjectMemoryAllocator _oma_manual_init(VMPageFrame* bucket_page_frame, const uint32_t object_size);

bool_t _oma_is_containing_mem_block(const void* memory_block, const ObjectMemoryAllocator* oma);

void* oma_alloc(ObjectMemoryAllocator* oma);
void oma_free(void* memory_block, ObjectMemoryAllocator* oma);