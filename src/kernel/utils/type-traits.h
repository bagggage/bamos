#pragma once

namespace tt {
    template<typename A, typename B>
    inline constexpr bool is_same = false;

    template<typename T>
    inline constexpr bool is_same<T, T> = true;

    template<bool Bool, typename T = void>
    struct enable_if {
        using type = T;
    };

    template<typename T>
    struct enable_if<false, T> {
        using type = void;
    };

    template<typename T>
    struct enable_if<true, T> {
        using type = T;
    };
};