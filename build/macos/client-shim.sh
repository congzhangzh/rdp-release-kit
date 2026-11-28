#!/bin/sh
# bin/sdl-freerdp: the client is FreeRDP.app's (an app, so the camera has its usage words); this
# runs it with the same arguments, in this process (exec: same pid, stdout, stderr, exit code,
# process group), so every command line that ran bin/sdl-freerdp before still works. A symlink
# to this file (into a PATH folder, say) is followed to the archive it belongs to.
p=$0
while [ -L "$p" ]; do
    l=$(readlink "$p")
    case $l in /*) p=$l ;; *) p=$(dirname "$p")/$l ;; esac
done
exec "$(dirname "$p")/../FreeRDP.app/Contents/MacOS/sdl-freerdp" "$@"
