#pragma once

#include "definitions.h"
#include "fmt.h"
#include "spinlock.h"

#include "video/text-output.h"

enum LogType : uint8_t {
    LOG_DEBUG = 0,
    LOG_INFO,
    LOG_WARN,
    LOG_ERROR
};

class Logger {
private:
    static constexpr uint64_t buffer_size = 1024;

    static Spinlock lock;
    static char buffer[buffer_size];

    template<typename... Args>
    static void log(const LogType type, Args... args) {
        lock.lock();

        char* cursor = buffer;

        switch (type) {
        case LOG_DEBUG:
            TextOutput::set_color(COLOR_GRAY);
            cursor = Fmt::str(cursor, "[DEBUG] "); break;
        case LOG_INFO:
            TextOutput::set_color(COLOR_LGRAY);
            cursor = Fmt::str(cursor, "[INFO]  "); break;
        case LOG_WARN:
            TextOutput::set_color(COLOR_LYELLOW);
            cursor = Fmt::str(cursor, "[WARN]  "); break;
        case LOG_ERROR:
            TextOutput::set_color(COLOR_LRED);
            cursor = Fmt::str(cursor, "[ERROR] "); break;
        default: break;
        }

        Fmt::str(cursor, args..., '\n');

        TextOutput::print(buffer);

        lock.release();
    }
public:
    template <typename... Args>
    static inline void debug(Args... args) {
        log(LOG_DEBUG, args...);
    }

    template <typename... Args>
    static inline void info(Args... args) {
        log(LOG_INFO, args...);
    }

    template <typename... Args>
    static inline void warn(Args... args) {
        log(LOG_WARN, args...);
    }

    template <typename... Args>
    static inline void error(Args... args) {
        log(LOG_ERROR, args...);
    }
};

template<typename... Args>
static inline void debug(const Args... args) {
    Logger::debug(args...);
}

template<typename... Args>
static inline void info(const Args... args) {
    Logger::info(args...);
}

template<typename... Args>
static inline void warn(const Args... args) {
    Logger::warn(args...);
}

template<typename... Args>
static inline void error(const Args... args) {
    Logger::error(args...);
}