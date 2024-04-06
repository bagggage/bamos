#include "object_mem_alloc.h"

#include "assert.h"
#include "bitmap.h"
#include "logger.h"
#include "vm.h"

#define OMA_MAX_FREE_BUCKETS 1
#define OMA_DEFAULT_CAPACITY 128

static bool_t is_oma_pool_initialized = FALSE;
static ObjectMemoryAllocator oma_pool;

ObjectMemoryAllocator _oma_init(const uint32_t bucket_pages_count, const uint32_t object_size) {
    ObjectMemoryAllocator oma = { { NULL, NULL }, 0, 0 };

    oma.object_size = object_size;

    uint32_t capacity = ((uint64_t)bucket_pages_count * PAGE_BYTE_SIZE) / object_size;
    uint32_t bitmap_size = div_with_roundup(capacity, BYTE_SIZE);

    while ((((uint64_t)capacity * object_size) + bitmap_size + sizeof(MemoryBucket)) >
        ((uint64_t)bucket_pages_count * PAGE_BYTE_SIZE)) {
        kassert(capacity > BYTE_SIZE);

        bitmap_size--;
        capacity -= BYTE_SIZE;
    }

    oma.bucket_capacity = capacity;

    return oma;
}

static inline void init_oma_pool() {
    oma_pool = _oma_init(1, sizeof(ObjectMemoryAllocator));
    is_oma_pool_initialized = TRUE;
}

ObjectMemoryAllocator* oma_new(const uint32_t object_size) {
    if (is_oma_pool_initialized == FALSE) {
        init_oma_pool();
    }

    ObjectMemoryAllocator* new_oma = oma_alloc(&oma_pool);

    if (new_oma == NULL) return NULL;

    uint32_t pages_count = div_with_roundup((uint64_t)object_size * OMA_DEFAULT_CAPACITY, PAGE_BYTE_SIZE);

    // Round to 2MB pages
    if (pages_count >= MB_SIZE / PAGE_BYTE_SIZE) {
        pages_count = div_with_roundup(pages_count, PAGES_PER_2MB);
    }

    *new_oma = _oma_init(pages_count, object_size);

    return new_oma;
}

void oma_clear(ObjectMemoryAllocator* oma) {
    while (oma->bucket_list.next != NULL) {
        MemoryBucket* bucket = (MemoryBucket*)oma->bucket_list.next;

        oma->bucket_list.next = (ListHead*)(void*)bucket->next;

        vm_free_pages(&bucket->page_frame, vm_get_kernel_pml4());
    }
}

void oma_delete(ObjectMemoryAllocator* oma) {
    if (oma == NULL) return;

    oma_clear(oma);
    oma_free((void*)oma, &oma_pool);
}

static MemoryBucket* oma_push_bucket(VMPageFrame* bucket_page_frame, ObjectMemoryAllocator* oma) {
    kassert(bucket_page_frame->virt_address != NULL);

    const uint32_t bitmap_size = div_with_roundup(oma->bucket_capacity, BYTE_SIZE);

    uint8_t* bitmap =
        (uint8_t*)((bucket_page_frame->virt_address + ((uint64_t)bucket_page_frame->count * PAGE_BYTE_SIZE)) - bitmap_size);
    MemoryBucket* bucket = (MemoryBucket*)((uint64_t)bitmap - sizeof(MemoryBucket));

    bucket->bitmap = bitmap;
    bucket->page_frame = *bucket_page_frame;
    bucket->next = NULL;
    bucket->prev = NULL;
    bucket->allocated_count = 0;

    if (oma->bucket_list.next == NULL) {
        oma->bucket_list.next = (ListHead*)(void*)bucket;
    }
    else {
        oma->bucket_list.prev->next = (ListHead*)(void*)bucket;
    }

    bucket->prev = (MemoryBucket*)(void*)oma->bucket_list.prev;
    oma->bucket_list.prev = (ListHead*)(void*)bucket;

    return bucket;
}

ObjectMemoryAllocator _oma_manual_init(VMPageFrame* bucket_page_frame, const uint32_t object_size) {
    kassert(bucket_page_frame != NULL && bucket_page_frame->count > 0 && object_size > 0);

    ObjectMemoryAllocator oma = _oma_init(bucket_page_frame->count, object_size);

#ifdef KDEBUG
    kernel_msg("OMA: Struct constructed\n");
#endif

    oma_push_bucket(bucket_page_frame, &oma);

    return oma;
}

static MemoryBucket* oma_push_new_bucket(ObjectMemoryAllocator* oma) {
    const uint32_t bitmap_size = div_with_roundup(oma->bucket_capacity, BYTE_SIZE);
    const uint32_t bucket_pages_count =
        div_with_roundup(((uint64_t)oma->bucket_capacity * oma->object_size) + bitmap_size + sizeof(MemoryBucket), PAGE_BYTE_SIZE);

    VMPageFrame page_frame = vm_alloc_pages(bucket_pages_count, vm_get_kernel_pml4(), VMMAP_WRITE | VMMAP_USE_LARGE_PAGES);

    if (page_frame.count == 0) {
        return NULL;
    }

    return oma_push_bucket(&page_frame, oma);
}

void* oma_alloc(ObjectMemoryAllocator* oma) {
    MemoryBucket* suitable_bucket = (MemoryBucket*)(void*)oma->bucket_list.next;

    while (suitable_bucket != NULL && suitable_bucket->allocated_count == oma->bucket_capacity) {
        suitable_bucket = suitable_bucket->next;
    }

    if (suitable_bucket == NULL) {
        suitable_bucket = oma_push_new_bucket(oma);

        if (suitable_bucket == NULL) return NULL;
    }

    for (uint32_t i = 0; i < div_with_roundup(oma->bucket_capacity, BYTE_SIZE); ++i) {
        if (suitable_bucket->bitmap[i] == 0xFF) continue;

        uint8_t bitmask = 1;

        for (uint8_t j = 0; j < BYTE_SIZE; ++j) {
            const uint32_t bit_idx = (i * BYTE_SIZE) + j;

            if (_bitmap_get_bit(suitable_bucket->bitmap, bit_idx) == 0) {
                kassert(bit_idx < oma->bucket_capacity);

                _bitmap_set_bit(suitable_bucket->bitmap, bit_idx);
                suitable_bucket->allocated_count++;

                return (void*)(suitable_bucket->page_frame.virt_address + ((uint64_t)bit_idx * oma->object_size));
            }

            bitmask <<= 1;
        }
    }

    // This branch should never be reached
    kassert(FALSE);

    return NULL;
}

void oma_free(void* memory_block, ObjectMemoryAllocator* oma) {
    MemoryBucket* suitable_bucket = (MemoryBucket*)(void*)oma->bucket_list.next;

    while (suitable_bucket != NULL) {
        if ((uint64_t)memory_block >= suitable_bucket->page_frame.virt_address &&
            (uint64_t)memory_block < (uint64_t)suitable_bucket->bitmap) {
            const uint64_t object_offset = (uint64_t)memory_block - suitable_bucket->page_frame.virt_address;
            const uint32_t bit_idx = object_offset / oma->object_size;

            kassert(_bitmap_get_bit(suitable_bucket->bitmap, bit_idx) != 0);

            _bitmap_clear_bit(suitable_bucket->bitmap, bit_idx);
            suitable_bucket->allocated_count--;

            return;
        }

        suitable_bucket = suitable_bucket->next;
    }

    // Given invalid 'memory_block'
    kassert(FALSE);
}