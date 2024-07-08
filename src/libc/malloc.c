#include "stdlib.h"

#include "stdint.h"
#include "sys/mman.h"

#define BYTE_SIZE 8
#define KB_SIZE 1024
#define MB_SIZE (KB_SIZE * 1024)

#define PAGE_BYTE_SIZE 4096
#define PAGES_PER_2MB ((MB_SIZE * 2) / PAGE_BYTE_SIZE)

#define TRUE 1
#define FALSE 0

typedef uint8_t bool_t;
typedef struct MemoryBucket MemoryBucket;

typedef struct BucketList {
    MemoryBucket* next;
    MemoryBucket* prev;
} BucketList;

typedef struct MemoryBucket {
    MemoryBucket* next;
    MemoryBucket* prev;

    uint8_t* mem_block;
    uint8_t* bitmap;

    uint32_t allocated_count;
} MemoryBucket;

typedef struct ObjectMemoryAllocator {
    BucketList bucket_list;

    uint32_t object_size;
    uint32_t bucket_size;
    uint32_t bucket_capacity;
} ObjectMemoryAllocator;

static inline uint64_t div_with_roundup(const uint64_t value, const uint64_t divider) {
    return (value / divider) + ((value % divider) == 0 ? 0 : 1);
}

static inline uint8_t _bitmap_get_bit(const uint8_t* bitmap, const uint32_t bit_idx) {
    return (bitmap[bit_idx / BYTE_SIZE] & (1 << (bit_idx % BYTE_SIZE)));
}

static inline void _bitmap_set_bit(uint8_t* bitmap, const uint32_t bit_idx) {
    bitmap[bit_idx / BYTE_SIZE] |= (1 << (bit_idx % BYTE_SIZE));
}

static inline void _bitmap_clear_bit(uint8_t* bitmap, const uint32_t bit_idx) {
    bitmap[bit_idx / BYTE_SIZE] &= ~(1 << (bit_idx % BYTE_SIZE));
}

static ObjectMemoryAllocator _oma_init(const uint32_t bucket_pages_count, const uint32_t object_size) {
    ObjectMemoryAllocator oma;

    oma.object_size = object_size;
    oma.bucket_list.next = NULL;
    oma.bucket_list.prev = NULL;

    uint32_t capacity = ((uint64_t)bucket_pages_count * PAGE_BYTE_SIZE) / object_size;
    uint32_t bitmap_size = div_with_roundup(capacity, BYTE_SIZE);

    while ((((uint64_t)capacity * object_size) + bitmap_size + sizeof(MemoryBucket)) >
        ((uint64_t)bucket_pages_count * PAGE_BYTE_SIZE)) {
        capacity--;
        bitmap_size = div_with_roundup(capacity, BYTE_SIZE);
    }

    oma.bucket_size = (uint64_t)bucket_pages_count * PAGE_BYTE_SIZE;
    oma.bucket_capacity = capacity;

    return oma;
}

static MemoryBucket* oma_push_bucket(uint8_t* const mem_block, ObjectMemoryAllocator* const oma) {
    const uint32_t bitmap_size = div_with_roundup(oma->bucket_capacity, BYTE_SIZE);

    uint8_t* bitmap = mem_block + oma->bucket_size - bitmap_size;
    MemoryBucket* bucket = (MemoryBucket*)((uint64_t)bitmap - sizeof(MemoryBucket));

    for (uint32_t i = 0; i < bitmap_size; ++i) {
        bitmap[i] = 0;
    }

    bucket->bitmap = bitmap;
    bucket->mem_block = mem_block;
    bucket->next = NULL;
    bucket->prev = oma->bucket_list.prev;
    bucket->allocated_count = 0;

    if (oma->bucket_list.next == NULL) {
        oma->bucket_list.next = bucket;
    }
    else {
        oma->bucket_list.prev->next = bucket;
    }

    oma->bucket_list.prev = bucket;

    return bucket;
}

static MemoryBucket* oma_push_new_bucket(ObjectMemoryAllocator* const oma) {
    uint8_t* mem_block = mmap(NULL, oma->bucket_size, PROT_READ | PROT_WRITE, MAP_ANONYMOUS | MAP_PRIVATE, 0, 0);

    if (mem_block == NULL) return NULL;

    MemoryBucket* bucket = oma_push_bucket(mem_block, oma);

    return bucket;
}

static void* oma_alloc(ObjectMemoryAllocator* const oma) {
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

        for (uint8_t j = 0; j < BYTE_SIZE; ++j) {
            const uint32_t bit_idx = (i * BYTE_SIZE) + j;

            if (_bitmap_get_bit(suitable_bucket->bitmap, bit_idx) == 0) {
                _bitmap_set_bit(suitable_bucket->bitmap, bit_idx);
                suitable_bucket->allocated_count++;

                return (void*)(suitable_bucket->mem_block + ((uint64_t)bit_idx * oma->object_size));
            }
        }
    }

    return NULL;
}

static void oma_free(void* const memory_block, ObjectMemoryAllocator* const oma) {
    MemoryBucket* suitable_bucket = (MemoryBucket*)(void*)oma->bucket_list.next;

    while (suitable_bucket != NULL) {
        if ((uint64_t)memory_block >= (uint64_t)suitable_bucket->mem_block &&
            (uint64_t)memory_block < (uint64_t)suitable_bucket->bitmap) {
            const uint64_t object_offset = (uint64_t)memory_block - (uint64_t)suitable_bucket->mem_block;
            const uint32_t bit_idx = object_offset / oma->object_size;

            _bitmap_clear_bit(suitable_bucket->bitmap, bit_idx);
            suitable_bucket->allocated_count--;

            return;
        }

        suitable_bucket = suitable_bucket->next;
    }
}

#define PAGE_KB_SIZE (PAGE_BYTE_SIZE / KB_SIZE)

#define UMA_MIN_RANK 3
#define UMA_RANKS_COUNT 19
#define UMA_MAX_RANK (UMA_MIN_RANK + UMA_RANKS_COUNT - 1)

typedef struct UniversalMemoryAllocator {
    ObjectMemoryAllocator oma_pool[UMA_RANKS_COUNT];
    uint64_t allocated_bytes;
} UniversalMemoryAllocator;

static UniversalMemoryAllocator uma;
static bool_t is_uma_initialized = FALSE;

static void init_uma() {
    uma.allocated_bytes = 0;

    for (uint32_t rank = UMA_MIN_RANK; rank <= UMA_MAX_RANK; ++rank) {
        const uint32_t obj_rank_size = 1 << rank;
        uint32_t bucket_pages_count = 1;

        if (obj_rank_size == PAGE_BYTE_SIZE) bucket_pages_count = 4;
        else if (obj_rank_size > PAGE_BYTE_SIZE && obj_rank_size < MB_SIZE) {
            bucket_pages_count = ((obj_rank_size / PAGE_BYTE_SIZE) * 4) + 1;
        }
        else if (obj_rank_size >= MB_SIZE) {
            bucket_pages_count = (obj_rank_size / PAGE_BYTE_SIZE) + 1;
        }

        uma.oma_pool[rank - UMA_MIN_RANK] = _oma_init(bucket_pages_count, obj_rank_size);
    }

    is_uma_initialized = TRUE;
}

static bool_t _oma_is_containing_mem_block(const void* restrict memory_block, const ObjectMemoryAllocator* restrict oma) {
    const MemoryBucket* bucket = oma->bucket_list.next;

    while (bucket != NULL) {
        if ((uint64_t)bucket->mem_block <= (uint64_t)memory_block &&
            (uint64_t)memory_block < (uint64_t)bucket->bitmap) {
            return TRUE;
        }

        bucket = bucket->next;
    }

    return FALSE;
}

static inline uint32_t popcount(const uint32_t number) {
    uint32_t result = number;

    result = (result & 0x55555555u) + ((result >> 1) & 0x55555555u);
    result = (result & 0x33333333u) + ((result >> 2) & 0x33333333u);
    result = (result & 0x0f0f0f0fu) + ((result >> 4) & 0x0f0f0f0fu);
    result = (result & 0x00ff00ffu) + ((result >> 8) & 0x00ff00ffu);
    result = (result & 0x0000ffffu) + ((result >>16) & 0x0000ffffu);

    return result;
}

static uint32_t log2(uint32_t number)
{
    number |= (number >> 1);
    number |= (number >> 2);
    number |= (number >> 4);
    number |= (number >> 8);
    number |= (number >> 16);

    return (popcount(number) - 1);
}

static inline uint32_t log2upper(uint32_t number) {
    return (popcount(number) > 1) ? (log2(number) + 1) : log2(number);
}

void* malloc(size_t size) {
    if (is_uma_initialized == FALSE) init_uma();

    uint32_t near_rank = log2upper(size);
    if (near_rank < UMA_MIN_RANK) near_rank = UMA_MIN_RANK;

    void* memory_block = oma_alloc(&uma.oma_pool[near_rank - UMA_MIN_RANK]);

    if (memory_block != NULL) uma.allocated_bytes += size;

    return memory_block;
}

void* calloc(size_t size, size_t count) {
    uint8_t* memory_block = (uint8_t*)malloc(size * count);

    if (memory_block == NULL) return memory_block;

    for (uint32_t i = 0; i < (size * count); ++i) {
        memory_block[i] = 0;
    }

    return memory_block;
}

//void* realloc(void* memory_block, const size_t size) {
//    if (memory_block == NULL) return memory_block;
//
//    uint32_t i = 0;
//
//    for (i = 0; i < UMA_RANKS_COUNT; ++i) {
//        if (_oma_is_containing_mem_block(memory_block, &uma.oma_pool[i]) == FALSE) continue;
//        break;
//    }
//
//    if (uma.oma_pool[i].object_size >= size) return memory_block;
//
//    void* new_block = malloc(size);
//
//    if (new_block == NULL) return NULL;
//
//    memcpy(memory_block, new_block, uma.oma_pool[i].object_size);
//    free(memory_block);
//    
//    return new_block;
//}

void free(void* restrict memory_block) {
    if (memory_block == NULL) return;

    for (uint32_t i = 0; i < UMA_RANKS_COUNT; ++i) {
        if (_oma_is_containing_mem_block(memory_block, &uma.oma_pool[i]) == FALSE) continue;

        oma_free(memory_block, &uma.oma_pool[i]);
        uma.allocated_bytes -= (1 << (i + UMA_MIN_RANK));

        return;
    }
}