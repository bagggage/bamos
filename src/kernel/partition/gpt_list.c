#include "gpt_list.h"

GptPartitionList gpt_list = {
    .nodes.next = NULL,
    .nodes.prev = NULL
};

bool_t gpt_push(GptPartitionNode* partition_node) {
    if (partition_node == NULL) return FALSE;

    if (gpt_list.nodes.next == NULL) {
        gpt_list.nodes.next = (ListHead*)partition_node;
        gpt_list.nodes.prev = (ListHead*)partition_node;
    }
    else {
        partition_node->prev = (GptPartitionNode*)gpt_list.nodes.prev;

        gpt_list.nodes.prev->next = (ListHead*)partition_node;
        gpt_list.nodes.prev = (ListHead*)partition_node;
    }

    return TRUE;
}

GptPartitionNode* gpt_get_first_node() {
    return (GptPartitionNode*)gpt_list.nodes.next;
}