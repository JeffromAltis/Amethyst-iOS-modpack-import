#pragma once
#include <stdbool.h>
#include <stddef.h>

// Portable lexical check; callers must also check filesystem symlinks.
static inline bool ModpackRelativePathIsSafe(const char *path, size_t length) {
    if (!path || !length || path[0] == '/' || path[0] == '\\') return false;
    if (length >= 2 && path[1] == ':' &&
        ((path[0] >= 'A' && path[0] <= 'Z') || (path[0] >= 'a' && path[0] <= 'z'))) return false;
    bool hasName = false;
    size_t start = 0;
    for (size_t i = 0; i <= length; i++) {
        if (i < length && path[i] == '\0') return false;
        if (i == length || path[i] == '/' || path[i] == '\\') {
            size_t size = i - start;
            if (size == 2 && path[start] == '.' && path[start + 1] == '.') return false;
            if (size && !(size == 1 && path[start] == '.')) hasName = true;
            start = i + 1;
        }
    }
    return hasName;
}
