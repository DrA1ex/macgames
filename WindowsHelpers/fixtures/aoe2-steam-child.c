/* A synthetic Steam parent and game child: no Steam client or game data. */
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <wchar.h>
#include <stdio.h>
__attribute__((noinline)) static double math_probe(void) {
    double result;
    __asm__ volatile("fld1; fld1; faddp; fstpl %0" : "=m"(result));
    return result;
}
int wmain(int argc, wchar_t **argv) {
    wchar_t image[32768];
    GetModuleFileNameW(NULL, image, 32768);
    wchar_t *name = wcsrchr(image, L'\\');
    name = name ? name + 1 : image;
    if (!_wcsicmp(name, L"steam.exe")) {
        if (argc != 4 || wcscmp(argv[1], L"-applaunch") || wcscmp(argv[2], L"813780"))
            return 64;
        wcscpy(name, L"AoE2DE_s.exe");
        wchar_t command[65536];
        swprintf(command, 65536, L"\"%ls\" \"%ls\"", image, argv[3]);
        STARTUPINFOW startup = {.cb = sizeof(startup)};
        PROCESS_INFORMATION child;
        if (!CreateProcessW(image, command, NULL, NULL, TRUE, 0, NULL, NULL, &startup, &child))
            return 1;
        if (WaitForSingleObject(child.hProcess, 30000) != WAIT_OBJECT_0)
            return 2;
        DWORD code = 0;
        GetExitCodeProcess(child.hProcess, &code);
        CloseHandle(child.hThread);
        CloseHandle(child.hProcess);
        return code;
    }
    if (argc != 2)
        return 65;
    FILE *file = _wfopen(argv[1], L"w");
    if (!file)
        return 3;
    double result = math_probe();
    fprintf(file, "synthetic_child=ok\nmath=%.1f\n", result);
    fclose(file);
    return result == 2.0 ? 0 : 4;
}
