#include "ModpackPath.h"
#include <assert.h>
#include <string.h>

int main(void) {
    const char *safe[] = {"mods/example.jar", "config/", "./config/options.txt", "a//b", "mods/日本語.jar"};
    const char *unsafe[] = {"", ".", "./", "/etc/file", "\\root", "../file", "a/../file",
        "a\\..\\file", "a/..\\file", "C:/file", "D:\\file", ".."};
    for (size_t i = 0; i < sizeof(safe) / sizeof(safe[0]); i++) assert(ModpackRelativePathIsSafe(safe[i], strlen(safe[i])));
    for (size_t i = 0; i < sizeof(unsafe) / sizeof(unsafe[0]); i++) assert(!ModpackRelativePathIsSafe(unsafe[i], strlen(unsafe[i])));
    assert(!ModpackRelativePathIsSafe(NULL, 1));
    const char embeddedNul[] = {'m', 'o', 'd', 's', '/', '\0', 'x'};
    assert(!ModpackRelativePathIsSafe(embeddedNul, sizeof(embeddedNul)));
    // The length contract must not require reading a terminator after the buffer.
    const char unterminated[] = {'a', '/', 'b'};
    assert(ModpackRelativePathIsSafe(unterminated, sizeof(unterminated)));
    return 0;
}
