#include "heap.h"

#include "arch.h"

uintptr_t Heap::reserve(const uint32_t pages) {
    kassert(pages > 0);

    uintptr_t result = 0;

    if (free_ranges.empty() == false) {
        RangeNode* suitable_range = nullptr;

        for (auto i = free_ranges.begin(); i != free_ranges.end(); ++i) {
            if (i->pages >= pages &&
                (suitable_range == nullptr || 
                (suitable_range != nullptr && suitable_range->value.pages < i->pages))
            ) {
                suitable_range = i.get_node();

                if (suitable_range->value.pages == pages) break;
            }
        }

        if (suitable_range) {
            result = suitable_range->value.base;
            remove_range(suitable_range, pages);
        }
    }

    if (result == 0) {
        result = top;
        top += pages * Arch::page_size;
    }

    return result;
}

void Heap::release(const uintptr_t base, const uint32_t pages) {
    kassert(base > 0 && pages > 0);

    const auto range_top = base + (pages * Arch::page_size);

    if (range_top == top) {
        top = base;
        return;
    }

    RangeNode* temp_node = free_ranges.begin().get_node();

    while (temp_node != nullptr) {
        if (temp_node->value.base == range_top) {
            temp_node->value.base = base;
            temp_node->value.pages += pages;
            break;
        }
        else if (temp_node->value.top() == base) {
            temp_node->value.pages += pages;
            break;
        }

        temp_node = temp_node->next;
    }

    if (temp_node == nullptr) {
        free_ranges.push_back(Range{base, pages});
        return;
    }
    else {
        RangeNode* target_node = temp_node;
        temp_node = free_ranges.begin().get_node();

        const auto target_top = target_node->value.top();

        while (temp_node != nullptr) {
            if (temp_node == target_node) {
                temp_node = temp_node->next;
                continue;
            }

            const auto temp_range_top = temp_node->value.top();

            if (temp_node->value.base == target_top) {
                temp_node->value.base = target_node->value.base;
                temp_node->value.pages += target_node->value.pages;

                free_ranges.remove(target_node);
                break;
            }
            else if (temp_range_top == target_node->value.base) {
                temp_node->value.pages += target_node->value.pages;

                free_ranges.remove(target_node);
                break;
            }

            temp_node = temp_node->next;
        }
    }
}

void Heap::remove_range(RangeNode* const node, const uint32_t pages) {
    if (node->value.pages > pages) {
        node->value.base += pages * Arch::page_size;
        node->value.pages -= pages;
    }
    else {
        free_ranges.remove(node);
    }
}