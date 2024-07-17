#pragma once

#include "alloc.h"
#include "assert.h"
#include "type-traits.h"

/*
Binary search tree
*/
template<typename T, typename K, K T::*Key, template<class> typename Alloc = NullAllocator>
class BinaryTree {
public:
    class Node {
    public:
        Node* lhs = nullptr;
        Node* rhs = nullptr;

        T value;
    public:
        Node() = default;
        Node(const T& value): value(value) {}
        Node(T&& value): value(value) {}

        Node* get_max() {
            Node* curr = rhs;
            while (curr->rhs) curr = curr->rhs;

            return curr;
        }

        Node* get_min_parent() {
            if (lhs == nullptr) return nullptr;

            Node* curr = this;

            while (curr->lhs->lhs) curr = curr->lhs;

            return curr;
        }

        Node* get_min() {
            if (lhs == nullptr) return nullptr;

            Node* curr = lhs;
            while (curr->lhs) curr = curr->lhs;

            return curr;
        }
    };

    using Allocator = Alloc<Node>;
private:
    Node* root = nullptr;

    static constexpr bool is_alloc = (tt::is_same<Allocator, NullAllocator<Node>> == false);
private:
    Node* search_node(const T& key) {
        kassert(root != nullptr);

        Node* current = root;

        do {
            if (current->value.*Key == key) [[unlikely]] return current;

            if (key < current->value.*Key) current = current->lhs;
            else current = current->rhs;
        } while (current);

        kassert(false && "Tree don't contains element with such key");
    }

    Node* search_parent(const K& key) {
        kassert(root != nullptr);

        if (root->value.*Key == key) [[unlikely]] return nullptr;

        Node* current = root;

        do {
            Node* child;

            if (key < current->value.*Key) child = current->lhs;
            else child = current->rhs;

            kassert(child != nullptr);

            if (child->value.*Key == key) [[unlikely]] return current;

            current = child;
        } while (current);

        kassert(false && "Tree don't contains element with such key");

        return nullptr;
    }
public:
    void insert(const T& value) {
        static_assert(is_alloc);

        Node* node = reinterpret_cast<Node*>(Allocator::alloc());
        *node = Node(value);

        insert(node);
    }

    void insert(T&& value) {
        static_assert(is_alloc);

        Node* node = reinterpret_cast<Node*>(Allocator::alloc());
        *node = Node(value);

        insert(node);
    }

    void insert(Node* const node) {
        if (root == nullptr) [[unlikely]] {
            root = node;
            return;
        }

        Node* parent = root;

        do {
            if (node->value.*Key < parent->value.*Key) {
                if (parent->lhs) {
                    parent = parent->lhs;
                    continue;
                }

                parent->lhs = node;
                break;
            }
            else {
                if (parent->rhs) {
                    parent = parent->rhs;
                    continue;
                }

                parent->rhs = node;
                break;
            }
        } while (true);
    }

    T& search(const K& key) {
        return search_node(key)->value;
    }

    T pop(const K& key) {
        Node* parent = search_parent(key);
        Node* node;

        if (parent == nullptr) [[unlikely]] node = root;
        else node = (parent->lhs->value.*Key == key) ? parent->lhs : parent->rhs;

        T result = node->value;

    do_remove:
        if (node->lhs || node->rhs) {
            if (node->lhs == nullptr) {
                Node* const temp = node->rhs;
                *node = *node->rhs;

                node = temp;
            }
            else if (node->rhs == nullptr) {
                Node* const temp = node->lhs;
                *node = *node->lhs;

                node = temp;
            }
            else {
                Node* const min_parent = node->rhs->get_min_parent();

                if (min_parent == nullptr) {
                    Node* const temp = node->rhs;

                    node->value = temp->value;
                    node->rhs = temp->rhs;
                    node = temp;
                }
                else {
                    node->value = min_parent->lhs->value;

                    parent = min_parent;
                    node = min_parent->lhs;

                    goto do_remove;
                }
            }
        }
        else {
            if (parent == nullptr) [[unlikely]] {
                root = nullptr;
            }
            else {
                if (parent->lhs == node) parent->lhs = nullptr;
                else parent->rhs = nullptr;
            }
        }

        if constexpr (is_alloc) if (node) Allocator::free(node);

        return result;
    }

    void remove(const K& key) {
        pop(key);
    }
};