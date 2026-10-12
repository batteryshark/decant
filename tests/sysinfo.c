// Writes bitness, Windows version and WoW64 state to argv[1] or C:\decant-sysinfo.txt.
#include <windows.h>
#include <stdio.h>

int main(int argc, char **argv) {
    FILE *f = fopen(argc > 1 ? argv[1] : "C:\\decant-sysinfo.txt", "w");
    if (!f) return 1;
    OSVERSIONINFOW v = {sizeof(v)};
    ((LONG(WINAPI *)(OSVERSIONINFOW *))GetProcAddress(GetModuleHandleA("ntdll.dll"), "RtlGetVersion"))(&v);
    BOOL wow = FALSE;
    IsWow64Process(GetCurrentProcess(), &wow);
    char wowdir[MAX_PATH] = "";
    GetSystemWow64DirectoryA(wowdir, MAX_PATH);
    fprintf(f, "pointer bits: %d\nWindows %lu.%lu build %lu\nIsWow64Process: %d\nGetSystemWow64Directory: %s\n",
            (int)sizeof(void *) * 8, v.dwMajorVersion, v.dwMinorVersion, v.dwBuildNumber, wow, wowdir);
    return fclose(f);
}
