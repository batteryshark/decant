// Reports bitness, Windows version and WoW64 state. Usage: sysinfo.exe [outfile]
#include <windows.h>
#include <stdio.h>

typedef LONG(WINAPI *RtlGetVersionFn)(OSVERSIONINFOW *);
typedef const char *(CDECL *WineGetVersionFn)(void);

int main(int argc, char **argv) {
    FILE *f = argc > 1 ? fopen(argv[1], "w") : stdout;
    if (!f) return 1;
    HMODULE ntdll = GetModuleHandleA("ntdll.dll");
    OSVERSIONINFOW v = {sizeof(v)};
    ((RtlGetVersionFn)GetProcAddress(ntdll, "RtlGetVersion"))(&v);
    BOOL wow = FALSE;
    IsWow64Process(GetCurrentProcess(), &wow);
    char sysdir[MAX_PATH] = "", wowdir[MAX_PATH] = "", k32[MAX_PATH] = "", exe[MAX_PATH] = "";
    GetSystemDirectoryA(sysdir, MAX_PATH);
    GetSystemWow64DirectoryA(wowdir, MAX_PATH);
    GetModuleFileNameA(GetModuleHandleA("kernel32.dll"), k32, MAX_PATH);
    GetModuleFileNameA(NULL, exe, MAX_PATH);
    WineGetVersionFn wv = (WineGetVersionFn)GetProcAddress(ntdll, "wine_get_version");
    fprintf(f, "exe: %s\npointer bits: %d\nWindows %lu.%lu build %lu\nIsWow64Process: %d\n"
               "GetSystemDirectory: %s\nGetSystemWow64Directory: %s\nkernel32 loaded from: %s\nwine: %s\n",
            exe, (int)sizeof(void *) * 8, v.dwMajorVersion, v.dwMinorVersion, v.dwBuildNumber, wow,
            sysdir, wowdir, k32, wv ? wv() : "n/a");
    if (f != stdout) fclose(f);
    return 0;
}
