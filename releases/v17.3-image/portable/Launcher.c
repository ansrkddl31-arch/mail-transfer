#define UNICODE
#define _UNICODE
#include <windows.h>

/* Windows APIs only: no installer, downloads, registry, policy changes or CRT DLL. */
static wchar_t root[32768], ps[32768], command[65536], script[32768];
/* Zig/COFF reserves this symbol; the launcher uses no TLS or C runtime. */
DWORD _tls_index;
static STARTUPINFOW startup;
static PROCESS_INFORMATION process;
static BOOL Append(wchar_t *dest, DWORD capacity, const wchar_t *text) {
    DWORD i=0,j=0;
    while (i<capacity && dest[i]) i++;
    if (i==capacity) return FALSE;
    while (text[j]) { if(i+1>=capacity) return FALSE; dest[i++]=text[j++]; }
    dest[i]=0;
    return TRUE;
}
static int Launch(void) {
    DWORD n=GetModuleFileNameW(NULL,root,32768),i,slash=0;
    if(!n || n>=32768) goto failure;
    for(i=0;i<n;i++) if(root[i]==L'\\') slash=i;
    if(!slash) goto failure;
    root[slash]=0;
    if(!Append(script,32768,root) || !Append(script,32768,L"\\Portable.ps1")) goto failure;
    if(GetFileAttributesW(script)==INVALID_FILE_ATTRIBUTES) {
        MessageBoxW(NULL,L"ZIP 전체를 압축 해제한 뒤 실행하세요. EX메일 실행.exe와 Portable.ps1이 같은 폴더에 있어야 합니다.",L"EX메일 익스플로러 포터블",MB_OK|MB_ICONERROR);
        return 1;
    }
    n=GetSystemDirectoryW(ps,32768);
    if(!n || n>=32768 || !Append(ps,32768,L"\\WindowsPowerShell\\v1.0\\powershell.exe")) goto failure;
    if(!Append(command,65536,L"\"") || !Append(command,65536,ps) ||
       !Append(command,65536,L"\" -NoLogo -NoProfile -NoExit -STA -ExecutionPolicy RemoteSigned -File \"") ||
       !Append(command,65536,script) || !Append(command,65536,L"\"")) goto failure;
    startup.cb=sizeof(startup);
    startup.dwFlags=STARTF_USESHOWWINDOW;
    startup.wShowWindow=SW_SHOWNORMAL;
    if(!CreateProcessW(ps,command,NULL,NULL,FALSE,CREATE_NEW_CONSOLE,NULL,root,&startup,&process)) goto failure;
    CloseHandle(process.hThread);
    CloseHandle(process.hProcess);
    return 0;
failure:
    MessageBoxW(NULL,L"PowerShell을 시작하지 못했습니다. Windows PowerShell 5.1과 폴더 접근 권한을 확인하세요. 회사 정책에서 실행을 차단한 경우 담당자에게 문의하세요.",L"EX메일 익스플로러 포터블",MB_OK|MB_ICONERROR);
    return 1;
}
void WINAPI PortableEntry(void) { ExitProcess((UINT)Launch()); }
