/* Hash the actual opened EXE, never trust its file name or inherited flags. */
#include <bcrypt.h>
static int pinned_executable(const wchar_t *path) {
    static const char pin[] = "124744bf4ae0d3856238e00d61fe321d47fcd3c0d7dfcd175c6c76aa9fb458ff";
    BCRYPT_ALG_HANDLE algorithm = NULL;
    BCRYPT_HASH_HANDLE hash = NULL;
    BYTE digest[32], buffer[65536];
    DWORD count;
    int result = 0;
    HANDLE file = CreateFileW(path, GENERIC_READ, FILE_SHARE_READ, NULL, OPEN_EXISTING,
                              FILE_FLAG_SEQUENTIAL_SCAN, NULL);
    if (file == INVALID_HANDLE_VALUE)
        return 0;
    if (BCryptOpenAlgorithmProvider(&algorithm, BCRYPT_SHA256_ALGORITHM, NULL, 0) < 0)
        goto done;
    if (BCryptCreateHash(algorithm, &hash, NULL, 0, NULL, 0, 0) < 0)
        goto done;
    for (;;) {
        if (!ReadFile(file, buffer, sizeof(buffer), &count, NULL))
            goto done;
        if (!count)
            break;
        if (BCryptHashData(hash, buffer, count, 0) < 0)
            goto done;
    }
    if (BCryptFinishHash(hash, digest, sizeof(digest), 0) < 0)
        goto done;
    for (unsigned n = 0; n < 32; n++) {
        unsigned a = pin[2 * n], b = pin[2 * n + 1];
        a = a >= 'a' ? a - 'a' + 10 : a - '0';
        b = b >= 'a' ? b - 'a' + 10 : b - '0';
        if (digest[n] != (BYTE)((a << 4) | b))
            goto done;
    }
    result = 1;
done:
    if (hash)
        BCryptDestroyHash(hash);
    if (algorithm)
        BCryptCloseAlgorithmProvider(algorithm, 0);
    CloseHandle(file);
    return result;
}
