#!/bin/bash
# Checks that a binary runs on any distribution with the build's glibc or
# newer:
#
#   check-portable.sh <binary> [max glibc version, default 2.34]
#
# - it needs nothing from the host but glibc, libgcc_s and libpulse
# - no symbol it uses comes from a newer glibc than the maximum
# - it exports no FreeRDP, WinPR, SDL or OpenSSL symbols that could clash
#   with a shared copy loaded by something else
set -euo pipefail

BIN=$1
MAX_GLIBC=${2:-2.34}
ALLOWED='^(libc\.so\.6|libm\.so\.6|libpthread\.so\.0|libdl\.so\.2|librt\.so\.1|ld-linux-[a-z0-9_-]+\.so\.[0-9]|libgcc_s\.so\.1|libpulse\.so\.0)$'
fail=0

needed=$(readelf -d "$BIN" | sed -n 's/.*(NEEDED).*\[\(.*\)\]/\1/p')
extra=$(grep -v -E "$ALLOWED" <<< "$needed" || true)
if [ -n "$extra" ]; then
    echo "FAIL  $BIN needs libraries a host may not have: ${extra//$'\n'/ }"
    fail=1
else
    echo "ok    needs only: ${needed//$'\n'/ }"
fi

newest=$(objdump -T "$BIN" | grep -o 'GLIBC_[0-9.]*' | sed 's/GLIBC_//' | sort -uV | tail -1)
if [ "$(printf '%s\n%s\n' "$newest" "$MAX_GLIBC" | sort -V | tail -1)" != "$MAX_GLIBC" ]; then
    echo "FAIL  needs glibc $newest, more than $MAX_GLIBC"
    fail=1
else
    echo "ok    needs glibc $newest at most (limit $MAX_GLIBC)"
fi

exported=$(nm -D --defined-only "$BIN" | awk '{print $NF}' |
           grep -c -E '^(freerdp_|winpr_|SDL_|TTF_|OPENSSL_|SSL_|EVP_|FT_)' || true)
if [ "$exported" != 0 ]; then
    echo "FAIL  exports $exported library symbols"
    fail=1
else
    echo "ok    exports no library symbols"
fi
exit $fail
