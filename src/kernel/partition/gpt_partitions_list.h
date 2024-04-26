#pragma once

#include "definitions.h"

#include "gpt.h"

typedef struct GptPartitionNode {
    LIST_STRUCT_IMPL(GptPartitionNode);

    PartitionEntry partition_entry;
    StorageDevice* storage_device;
} GptPartitionNode;

typedef struct GptPartitionList {
    ListHead nodes;
} GptPartitionList;

bool_t gpt_partition_list_push(GptPartitionNode* partition_node);

GptPartitionNode* gpt_partition_list_get_first_node();
