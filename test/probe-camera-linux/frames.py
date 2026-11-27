#!/usr/bin/env python3
"""frames.py <raw file> <width> <height> <min changes>: what an app read from the host's camera.

The file is what `v4l2-ctl --stream-mmap --stream-to` wrote: YUYV frames one after the other.
Each frame is told apart by its pixel (8, 8): the host's still (a camera with a slash, its
background luma 43, server/shadow/camera/placeholder.c) or a client frame, the client's
640x480 test pattern pillarboxed into the 16:9 camera (black, luma 16, at the sides).
It passes when the client frames change from one to the next at least <min changes> times
(videotestsrc pattern=ball moves on every frame)."""
import hashlib
import sys

path, width, height, need = sys.argv[1], int(sys.argv[2]), int(sys.argv[3]), int(sys.argv[4])
size = width * height * 2
data = open(path, 'rb').read()
count = len(data) // size
kinds = []
changes = 0
previous = None
for i in range(count):
    frame = data[i * size:(i + 1) * size]
    corner = frame[(8 * width + 8) * 2]
    kind = 'still' if 35 <= corner <= 50 else 'client' if corner <= 24 else f'other({corner})'
    kinds.append(kind)
    if kind == 'client':
        digest = hashlib.sha256(frame).digest()
        if previous is not None and digest != previous:
            changes += 1
        previous = digest
runs = []
for k in kinds:
    if runs and runs[-1][0] == k:
        runs[-1][1] += 1
    else:
        runs.append([k, 1])
print(f'{path}: {count} frames of {width}x{height} YUYV ({len(data) % size} bytes left over)')
print('sequence: ' + ' '.join(f'{k}x{n}' for k, n in runs))
print(f'client frames: {kinds.count("client")}, changes between them: {changes} (need {need})')
sys.exit(0 if changes >= need else 1)
