#pragma once

typedef struct ListHead {
    struct ListHead* prev;
    struct ListHead* next;
} ListHead;

#define LIST_STRUCT_IMPL(node_type) \
    struct node_type* prev; \
    struct node_type* next;
