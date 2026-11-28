#!/usr/bin/env python3
"""camera-frames.py <raw file> <width> <height> <min changes>: what an app read from the host's
camera when the client's camera fills the whole frame (Chromium's fake camera: a green frame
with a moving pie and a frame counter), unlike frames.py's pillarboxed 640x480 test pattern.

The file is what `v4l2-ctl --stream-mmap --stream-to` wrote: YUYV frames one after the other.
A frame is the host's still when its pixel (8, 8) has the still's background luma (35..50,
server/shadow/camera/placeholder.c), else a camera frame. Passes when the camera frames change
from one to the next at least <min changes> times."""
import hashlib
import sys

path, width, height, need = sys.argv[1], int(sys.argv[2]), int(sys.argv[3]), int(sys.argv[4])
size = width * height * 2
data = open(path, 'rb').read()
count = len(data) // size
hashes = [hashlib.sha256(data[i * size:(i + 1) * size]).digest() for i in range(count)]
still = [35 <= data[i * size + (8 * width + 8) * 2] <= 50 for i in range(count)]
changes = sum(1 for i in range(1, count)
              if not still[i] and not still[i - 1] and hashes[i] != hashes[i - 1])
print(f'{path}: {count} frames of {width}x{height} YUYV ({len(data) % size} bytes left over)')
print(f'still frames: {sum(still)}, camera frames: {count - sum(still)}, distinct frames: {len(set(hashes))}')
print(f'changes between camera frames: {changes} (need {need})')
sys.exit(0 if changes >= need else 1)
