#!/bin/bash
# compat-0.12.7.sh <v4l2loopback 0.12.7 source dir>: CI only. 0.12.7 (2022, Ubuntu 24.04's) does not
# build on the runners' 7.0 kernels; this renames the kernel APIs it predates, and changes nothing
# else: strlcpy (removed in 6.8), del_timer_sync (6.15), from_timer (6.16), v4l2_fh_add and
# v4l2_fh_del taking the file (6.18). Its events stay those of 0.12.7: V4L2_EVENT_CTRL only, so
# subscribing to the client usage event fails with EINVAL (v4l2loopback.c:1779-1788), what the
# host's fallback is for.
set -euo pipefail
f=${1:?}/v4l2loopback.c
sed -i -e 's/\bstrlcpy(/strscpy(/g' -e 's/\bdel_timer_sync(/timer_delete_sync(/g' \
    -e 's/v4l2_fh_add(&opener->fh)/v4l2_fh_add(\&opener->fh, file)/' \
    -e 's/v4l2_fh_del(&opener->fh)/v4l2_fh_del(\&opener->fh, file)/' "$f"
sed -i '0,/^#include/s//#include <linux\/timer.h>\n#ifndef from_timer\n#define from_timer timer_container_of\n#endif\n#include/' "$f"
