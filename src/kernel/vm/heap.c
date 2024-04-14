#include "heap.h"

#include "assert.h"
#include "logger.h"
#include "object_mem_alloc.h"
#include "vm.h"

static ObjectMemoryAllocator* free_list_oma = NULL;

typedef struct MemoryBlockNode {
    LIST_STRUCT_IMPL(MemoryBlockNode);

    MemoryBlock block;
} MemoryBlockNode;

bool_t vm_init_heap_manager() {
    free_list_oma = oma_new(sizeof(MemoryBlockNode));

    if (free_list_oma == NULL) return FALSE;

    return TRUE;
}

void vm_heap_construct(VMHeap* heap, const uint64_t virt_base) {
    kassert(heap != NULL && virt_base != 0);

    heap->virt_base = virt_base;
    heap->virt_top = virt_base;

    heap->free_list.next = NULL;
    heap->free_list.prev = NULL;
}

static void vm_heap_remove_free_block(VMHeap* heap, MemoryBlockNode* node, const uint32_t pages_count) {
    if (node->block.pages_count > pages_count) {
        node->block.address += ((uint64_t)pages_count * PAGE_BYTE_SIZE);
        node->block.pages_count -= pages_count;
    }
    else if (heap->free_list.next == heap->free_list.prev) {
        kassert(heap->free_list.next == node);
        oma_free((void*)node, free_list_oma);

        heap->free_list.next = NULL;
        heap->free_list.prev = NULL;
    }
    else {
        if (heap->free_list.next == node) {
            heap->free_list.next = (ListHead*)(void*)node->next;
            node->next->prev = NULL;
        }
        else if (heap->free_list.prev == node) {
            heap->free_list.prev = (ListHead*)(void*)node->prev;
            node->prev->next = NULL;
        }
        else {
            node->next->prev = node->prev;
            node->prev->next = node->next;
        }

        oma_free((void*)node, free_list_oma);
    }
}

static bool_t vm_heap_insert_free_block(VMHeap* heap, const uint64_t virt_address, const uint32_t pages_count) {
    const uint64_t block_top = virt_address + ((uint64_t)pages_count * PAGE_BYTE_SIZE);

    MemoryBlockNode* temp_node = heap->free_list.next;

    while (temp_node != NULL) {
        const uint64_t temp_block_top =
            temp_node->block.address + ((uint64_t)temp_node->block.pages_count * PAGE_BYTE_SIZE);

        if (temp_node->block.address == block_top) {
            temp_node->block.address = virt_address;
            temp_node->block.pages_count += pages_count;
            break;
        }
        else if (temp_block_top == virt_address) {
            temp_node->block.pages_count += pages_count;
            break;
        }

        temp_node = temp_node->next;
    }

    if (temp_node == NULL) {
        MemoryBlockNode* new_node = (MemoryBlockNode*)oma_alloc(free_list_oma);

        new_node->block.address = virt_address;
        new_node->block.pages_count = pages_count;
        new_node->next = NULL;
        
        if (heap->free_list.next == NULL) {
            heap->free_list.next = (ListHead*)(void*)new_node;
            new_node->prev = NULL;
        }
        else {
            heap->free_list.prev->next = (ListHead*)(void*)new_node;
            new_node->prev = (MemoryBlockNode*)(void*)heap->free_list.prev;
        }

        heap->free_list.prev = (ListHead*)(void*)new_node;
    }
    else {
        MemoryBlockNode* target_node = temp_node;
        temp_node = heap->free_list.next;

        const uint64_t target_top = target_node->block.address + ((uint64_t)target_node->block.pages_count * PAGE_BYTE_SIZE);

        while (temp_node != NULL) {
            if (temp_node == target_node) {
                temp_node = temp_node->next;
                continue;
            }

            const uint64_t temp_block_top =
                temp_node->block.address + ((uint64_t)temp_node->block.pages_count * PAGE_BYTE_SIZE);

            if (temp_node->block.address == target_top) {
                temp_node->block.address = target_node->block.address;
                temp_node->block.pages_count += target_node->block.pages_count;

                vm_heap_remove_free_block(heap, target_node, target_node->block.pages_count);
                break;
            }
            else if (temp_block_top == target_node->block.address) {
                temp_node->block.pages_count += target_node->block.pages_count;

                vm_heap_remove_free_block(heap, target_node, target_node->block.pages_count);
                break;
            }

            temp_node = temp_node->next;
        }
    }
}

uint64_t vm_heap_reserve(VMHeap* heap, const uint32_t pages_count) {
    kassert(heap != NULL && pages_count != 0);

    uint64_t result = 0;

    if (heap->free_list.next != NULL) {
        MemoryBlockNode* temp_block = (MemoryBlockNode*)(void*)heap->free_list.next;
        MemoryBlockNode* suitable_block = NULL;

        while (temp_block != NULL) {
            if (temp_block->block.pages_count >= pages_count &&
                (suitable_block == NULL ||
                (suitable_block != NULL &&
                suitable_block->block.pages_count < temp_block->block.pages_count))) {
                suitable_block = temp_block;

                if (suitable_block->block.pages_count == pages_count) break;
            }

            temp_block = temp_block->next;
        }

        if (suitable_block != NULL) {
            result = suitable_block->block.address;
            vm_heap_remove_free_block(heap, suitable_block, pages_count);
        }
    }

    if (result == 0) {
        result = heap->virt_top;
        heap->virt_top += ((uint64_t)pages_count * PAGE_BYTE_SIZE);
    }

    return result;
}

void vm_heap_release(VMHeap* heap, const uint64_t virt_address, const uint32_t pages_count) {
    kassert(heap != NULL && virt_address != 0 && pages_count != 0);

    if (virt_address + ((uint64_t)pages_count * PAGE_BYTE_SIZE) == heap->virt_top) {
        heap->virt_top = virt_address;
        return;
    }

    vm_heap_insert_free_block(heap, virt_address, pages_count);
}

void log_heap(const VMHeap* heap) {
    kernel_msg("Heap: %x --- %x\n", heap->virt_base, heap->virt_top);
    kernel_msg("Heap free list: ");

    const MemoryBlockNode* node = (const MemoryBlockNode*)(const void*)heap->free_list.next;

    if (node == NULL) {
        raw_puts("empty\n");
        return;
    }

    while (node != NULL) {
        raw_putc('[');
        raw_print_number(node->block.address, FALSE, 16);
        raw_puts(" : ");
        raw_print_number(node->block.pages_count, FALSE, 10);
        raw_puts("]->");

        node = node->next;
    }

    raw_putc('\n');
}