#pragma once

#include "alloc.h"
#include "type-traits.h"

template<typename T, template<class> typename Alloc = NullAllocator>
class List {
public:
    class Node {
    public:
        Node* next;
        Node* prev;

        T value;
    };

    using Allocator = Alloc<Node>;
private:
    Node* head = nullptr;
    Node* tail = nullptr;

    static constexpr bool is_alloc = (tt::is_same<Allocator, NullAllocator<Node>> == false);
public:
    class Iter {
    private:
        Node* node;

        friend class List<T, Alloc>;
    public:
        Iter(Node& node): node(&node) {};

        Iter& operator=(const Iter& other) {
            return node = other.node;
        }

        Iter& operator++() { 
            node = node->next;
            return *this;
        }

        Iter& operator++(int) {
            Iter temp = *this;
            node = node->next;

            return temp;
        }

        Iter& operator--() { 
            node = node->prev;
            return *this;
        }

        Iter& operator--(int) {
            Iter temp = *this;
            node = node->prev;

            return temp;
        }

        inline Node* get_node() { return node; }

        T& operator*() const { return node->value; };
        T* operator->() { return &node->value; };

        friend bool operator==(const Iter& lhs, const Iter& rhs) { return lhs.node == rhs.node; };
        friend bool operator!=(const Iter& lhs, const Iter& rhs) { return lhs.node != rhs.node; };
    };

    inline Iter begin() { return Iter(head); }
    inline Iter end() { return Iter(nullptr); }

    inline T* head() { return head; }
    inline T* tail() { return tail; }

    inline const T* head() const { return head; }
    inline const T* tail() const { return tail; }

    void push_front(const T& value) {
        static_assert(is_alloc);

        Node* node = reinterpret_cast<Node*>(Allocator::alloc());
        node->value = value;
        push_front(node);
    }

    void push_back(const T& value) {
        static_assert(is_alloc);

        Node* node = reinterpret_cast<Node*>(Allocator::alloc());
        node->value = value;
        push_back(node);
    }

    void insert(const Iter& before, const T& value) {
        static_assert(is_alloc);

        Node* node = reinterpret_cast<Node*>(Allocator::alloc());
        node->value = value;
        insert(before, node);
    }

    void push_front(Node* const node) {
        if (head == nullptr) {
            head = node;
            tail = node;
        }
        else {
            node->next = head;
            head->prev = node;
            head = node;
        }
    }

    void push_back(Node* const node) {
        if (head == nullptr) {
            head = node;
            tail = node;
        }
        else {
            node->prev = tail;
            tail->next = node;
            tail = node;
        }
    }

    void insert(const Iter& before, Node* const node) {
        insert(&*before, node);
    }

    void insert(Node* const before, Node* const node) {
        if (head == nullptr) {
            head = node;
            tail = node;
        }
        else if (before == nullptr) {
            node->prev = tail;
            tail->next = node;
            tail = node;
        }
        else {
            if (before->prev) {
                before->prev->next = node;
                node->prev = before->prev;
            }
            else {
                head = node;
            }

            before->prev = node;
            node->next = before;
        }
    }

    using pop_ret_t = tt::enable_if<is_alloc == false, Node*>::type;

    pop_ret_t pop_back() {
        Node* node = tail;

        if (node->prev) tail = tail->prev;
        else head = tail = nullptr;

        if constexpr (is_alloc) Allocator::free(node);
        else return node;
    }

    pop_ret_t pop_front() {
        Node* node = head;

        if (node->next) head = head->next;
        else head = tail = nullptr;

        if constexpr (is_alloc) Allocator::free(node);
        else return node;
    }

    pop_ret_t remove(const Iter& where) {
        return remove(&*where);
    }

    pop_ret_t remove(Node* const node) {
        if (head == tail) {
            kassert(head == node);

            head = nullptr;
            tail = nullptr;
        }
        else if (head == node) {
            head = node.next;
            node.next->prev = nullptr;
        }
        else if (tail == node) {
            tail = node.prev;
            node.prev->next = nullptr;
        }
        else {
            node.next->prev = node.prev;
            node.prev->next = node.next;
        }

        if constexpr (is_alloc) Allocator::free(node);
        else return node;
    }

    inline bool empty() const {
        return head == nullptr;
    }
};