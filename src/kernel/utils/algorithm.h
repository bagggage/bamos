#pragma once

template<typename Iter, typename T>
static inline Iter find(Iter first, Iter last, const T& value) {
    while (first != last) {
        if (*first == value) return first;

        ++first;
    }

    return last;
}

template<typename Iter, typename Comp, typename T>
static inline Iter find(Iter first, Iter last, const T& value, Comp comp) {
    while (first != last) {
        if (comp(*first, value)) return first;

        ++first;
    }

    return last;
}