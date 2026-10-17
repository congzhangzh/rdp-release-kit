#!/bin/bash
# Checks that a Windows client .exe needs nothing that is not part of
# Windows itself (no libc++.dll, SDL3.dll, ... next to it):
#
#   check-windows.sh <exe>
set -euo pipefail

EXE=$1
# Windows' own DLLs, and the UCRT (api-ms-win-crt-*, part of Windows 10+)
SYSTEM='^(api-ms-win-[a-z0-9-]+|advapi32|bcrypt|cfgmgr32|comctl32|comdlg32|crypt32|dbghelp|dnsapi|dwmapi|gdi32|hid|imm32|iphlpapi|kernel32|mpr|ncrypt|netapi32|ntdll|ole32|oleaut32|rpcrt4|secur32|setupapi|shell32|shlwapi|user32|userenv|uxtheme|version|winhttp|winmm|winspool\.drv|wldap32|ws2_32|wtsapi32|credui|dxgi|d3d11|d3d12|dinput8|xinput1_4|opengl32|ucrtbase|cabinet|winscard|wintrust|psapi)(\.dll)?$'

dlls=$(/llvm-mingw/bin/llvm-objdump -p "$EXE" | sed -n 's/.*DLL Name: //p' | tr '[:upper:]' '[:lower:]' | sort -u)
extra=$(grep -v -E "$SYSTEM" <<< "$dlls" || true)
if [ -n "$extra" ]; then
    echo "FAIL  $(basename "$EXE") needs DLLs Windows does not have: ${extra//$'\n'/ }"
    exit 1
fi
echo "ok    needs only Windows' own DLLs: ${dlls//$'\n'/ }"
