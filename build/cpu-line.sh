#!/usr/bin/env bash
# One line naming this machine's CPU and whether libavm's AV2 kernels can run their AVX-512
# versions here, so a test log says which ones a session ran. libavm's dispatch takes them only
# with all five of AVX-512 F, DQ, CD, BW and VL and the OS's zmm state enabled; Linux lists the
# avx512* flags in /proc/cpuinfo only when the kernel enabled that state, macOS's
# hw.optional.avx512* likewise. That the kernels are right is proven by the AVM release kit
# (its simd job runs them under Intel SDE against pure C); this line only says which ran.
# Linux and macOS; test/windows-host.ps1 has its own. Usage: build/cpu-line.sh
set -u
arch=$(uname -m)
case "$(uname -s)" in
Linux)
    model=$(sed -n 's/^model name[[:space:]]*: //p' /proc/cpuinfo 2> /dev/null | head -1)
    flags=" $(sed -n 's/^flags[[:space:]]*: //p' /proc/cpuinfo 2> /dev/null | head -1) " ;;
Darwin)
    model=$(sysctl -n machdep.cpu.brand_string 2> /dev/null)
    flags=" "
    for f in f dq cd bw vl; do
        [ "$(sysctl -n "hw.optional.avx512$f" 2> /dev/null)" = 1 ] && flags+="avx512$f "
    done ;;
*)  model=""; flags=" " ;;
esac
model=${model:-unknown}
if [ "$arch" != x86_64 ]; then
    echo "CPU: $model ($arch); AVX-512: n/a ($arch)"
    exit 0
fi
missing=""
for f in avx512f avx512dq avx512cd avx512bw avx512vl; do
    case "$flags" in *" $f "*) ;; *) missing+=" ${f#avx512}" ;; esac
done
if [ -z "$missing" ]; then
    echo "CPU: $model; AVX-512 F DQ CD BW VL: yes (libavm takes its AVX-512 kernels)"
else
    echo "CPU: $model; AVX-512 F DQ CD BW VL: no, missing$missing (libavm stays on AVX2 and below)"
fi
