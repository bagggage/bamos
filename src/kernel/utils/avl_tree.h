#pragma once

#include "definitions.h"

#define AVLTREE_NODE_IMPL(node_t, key_t, key_name) \
    key_t key_name; \
    node_t* left; \
    node_t* right; \
    unsigned int height

typedef struct AVLTreeNode {
    AVLTREE_NODE_IMPL(struct AVLTreeNode, uint64_t, key);
} AVLTreeNode;

typedef AVLTreeNode AVLTree;

void avl_tree_clear(AVLTree* avl_tree);

AVLTreeNode* avl_tree_push(AVLTree* avl_tree, const void* src, uint32_t sizeof_node);
Status avl_tree_remove(AVLTree* avl_tree, const void* key_value, uint32_t sizeof_key);
void avl_tree_remove_node(AVLTree* avl_tree, AVLTreeNode* node_to_remove);

AVLTreeNode* avl_tree_find(AVLTree* avl_tree, const void* key_value, uint32_t sizeof_key);