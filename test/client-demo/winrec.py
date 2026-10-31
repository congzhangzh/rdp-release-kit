"""What the speakers of this Windows PC play, recorded to a WAV file, for the
freerdp-tk demo's video (test/client-demo/windows.ps1): ffmpeg records the
screen (gdigrab) but cannot record a playback device, WASAPI loopback can.

    python winrec.py <out.wav> <stop file>

Records until the stop file exists; <out.wav>.start holds when it began (Unix
time), for the mux. Prints the device, or why there is none (a PC without a
sound device: the video stays silent, nothing fails).
"""
import os
import sys
import time
import wave

out, stop = sys.argv[1:3]
try:
    import numpy
    import soundcard
    speaker = soundcard.default_speaker()
    mic = soundcard.get_microphone(id=str(speaker.name), include_loopback=True)
except Exception as e:  # no package, no device
    print(f"winrec: no recording: {e}", flush=True)
    sys.exit(0)
print(f"winrec: recording {speaker.name}", flush=True)
rate = 48000
with wave.open(out, "wb") as w, mic.recorder(samplerate=rate, channels=2) as rec:
    w.setnchannels(2)
    w.setsampwidth(2)
    w.setframerate(rate)
    start = time.monotonic()
    with open(out + ".start", "w") as f:   # when the first sample was taken, for the mux
        f.write(f"{time.time():.3f}")
    while not os.path.exists(stop):
        data = rec.record(numframes=rate // 10)
        w.writeframes((numpy.clip(data, -1, 1) * 32767).astype("<i2").tobytes())
print(f"winrec: {time.monotonic() - start:.1f} s", flush=True)
