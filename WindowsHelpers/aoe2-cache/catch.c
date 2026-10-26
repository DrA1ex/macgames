#include <windows.h>
__attribute__((noinline)) int call_and_catch(void (*function)(void)) {
    __try {
        function();
    } __except (1) {
        return 1;
    }
    return 0;
}
