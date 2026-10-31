"""The demo's hands on Windows (test/client-demo/windows.ps1): what xdotool
does for drive.py on Linux, with Windows' own SendInput, through ctypes.

Keys go as scan codes (KEYEVENTF_SCANCODE), as a keyboard sends them: Tk
reads them, and so does the FreeRDP client, which sends the remote desktop
scan codes (a VK_PACKET character would reach it as an unknown key). Each
action runs on a thread of its own and is returned as a job with poll(), so
drive.py waits for it from Tk's loop, as for xdotool's process on Linux.
"""
import ctypes
import math
import re
import threading
import time
from ctypes import wintypes

user32 = ctypes.WinDLL("user32", use_last_error=True)
kernel32 = ctypes.WinDLL("kernel32", use_last_error=True)

INPUT_MOUSE, INPUT_KEYBOARD = 0, 1
KEYEVENTF_EXTENDEDKEY, KEYEVENTF_KEYUP, KEYEVENTF_SCANCODE = 0x1, 0x2, 0x8
MOUSEEVENTF_LEFTDOWN, MOUSEEVENTF_LEFTUP = 0x2, 0x4


class MOUSEINPUT(ctypes.Structure):
    _fields_ = [("dx", wintypes.LONG), ("dy", wintypes.LONG), ("mouseData", wintypes.DWORD),
                ("dwFlags", wintypes.DWORD), ("time", wintypes.DWORD), ("dwExtraInfo", ctypes.c_size_t)]


class KEYBDINPUT(ctypes.Structure):
    _fields_ = [("wVk", wintypes.WORD), ("wScan", wintypes.WORD), ("dwFlags", wintypes.DWORD),
                ("time", wintypes.DWORD), ("dwExtraInfo", ctypes.c_size_t)]


class HARDWAREINPUT(ctypes.Structure):
    _fields_ = [("uMsg", wintypes.DWORD), ("wParamL", wintypes.WORD), ("wParamH", wintypes.WORD)]


class _U(ctypes.Union):
    _fields_ = [("mi", MOUSEINPUT), ("ki", KEYBDINPUT), ("hi", HARDWAREINPUT)]


class INPUT(ctypes.Structure):
    _fields_ = [("type", wintypes.DWORD), ("u", _U)]


user32.SendInput.argtypes = (wintypes.UINT, ctypes.POINTER(INPUT), ctypes.c_int)
user32.MapVirtualKeyW.argtypes = (wintypes.UINT, wintypes.UINT)
user32.VkKeyScanW.argtypes = (wintypes.WCHAR,)
user32.VkKeyScanW.restype = ctypes.c_short
EnumWindowsProc = ctypes.WINFUNCTYPE(wintypes.BOOL, wintypes.HWND, wintypes.LPARAM)


def _send(*inputs):
    arr = (INPUT * len(inputs))(*inputs)
    if user32.SendInput(len(inputs), arr, ctypes.sizeof(INPUT)) != len(inputs):
        raise OSError(f"SendInput: error {ctypes.get_last_error()}")


def _scan(scan, up=False, extended=False):
    flags = KEYEVENTF_SCANCODE | (KEYEVENTF_KEYUP if up else 0) | (KEYEVENTF_EXTENDEDKEY if extended else 0)
    return INPUT(INPUT_KEYBOARD, _U(ki=KEYBDINPUT(0, scan, flags, 0, 0)))


# names drive.py uses (xdotool's), as scan codes; True: an extended key (E0)
NAMED = {"Return": (0x1C, False), "Down": (0x50, True), "Up": (0x48, True), "Escape": (0x01, False),
         "Tab": (0x0F, False), "super": (0x5B, True), "shift": (0x2A, False), "alt": (0x38, False)}


def _char(ch):
    """A character as (scan code, shift) on this keyboard layout."""
    if ch == "\n":
        return NAMED["Return"][0], False
    vk = user32.VkKeyScanW(ch)
    if vk == -1:
        raise ValueError(f"no key for {ch!r}")
    return user32.MapVirtualKeyW(vk & 0xFF, 0), bool(vk & 0x100)   # MAPVK_VK_TO_VSC


class Job(threading.Thread):
    """An action on its own thread; poll() is None until it is done, as Popen's."""

    def __init__(self, fn):
        super().__init__(daemon=True)
        self.fn, self.error = fn, None
        self.start()

    def run(self):
        try:
            self.fn()
        except Exception as e:  # reported by the next poll
            self.error = e

    def poll(self):
        if self.is_alive():
            return None
        if self.error:
            raise self.error
        return 0


class WinInput:
    def where(self):
        p = wintypes.POINT()
        user32.GetCursorPos(ctypes.byref(p))
        return p.x, p.y

    def move(self, x0, y0, x, y, seconds):
        """A smooth path, eased at both ends (SetCursorPos makes the system move the pointer)."""
        def path():
            n = max(8, int(seconds * 40))
            for i in range(1, n + 1):
                t = (1 - math.cos(math.pi * i / n)) / 2
                user32.SetCursorPos(round(x0 + (x - x0) * t), round(y0 + (y - y0) * t))
                time.sleep(seconds / n)
        return Job(path)

    def click(self, times=1):
        def clicks():
            for i in range(times):
                _send(INPUT(INPUT_MOUSE, _U(mi=MOUSEINPUT(0, 0, 0, MOUSEEVENTF_LEFTDOWN, 0, 0))),
                      INPUT(INPUT_MOUSE, _U(mi=MOUSEINPUT(0, 0, 0, MOUSEEVENTF_LEFTUP, 0, 0))))
                time.sleep(0.09)
        return Job(clicks)

    def type(self, text, delay=70):
        def keys():
            shift = NAMED["shift"][0]
            for ch in text:
                scan, shifted = _char(ch)
                if shifted:
                    _send(_scan(shift))
                _send(_scan(scan), _scan(scan, up=True))
                if shifted:
                    _send(_scan(shift, up=True))
                time.sleep(delay / 1000)
        return Job(keys)

    def key(self, *names):
        def keys():
            for name in names:
                scan, ext = NAMED[name]
                _send(_scan(scan, extended=ext), _scan(scan, up=True, extended=ext))
                time.sleep(0.15)
        return Job(keys)

    def chord(self, held, name):
        """name with held down, e.g. ("super", "r") for Win+R."""
        def keys():
            hs, he = NAMED[held]
            scan, ext = NAMED[name] if name in NAMED else (_char(name)[0], False)
            _send(_scan(hs, extended=he))
            time.sleep(0.06)
            _send(_scan(scan, extended=ext), _scan(scan, up=True, extended=ext))
            time.sleep(0.06)
            _send(_scan(hs, up=True, extended=he))
        return Job(keys)

    def find(self, pattern):
        """The last visible top-level window whose title matches, or None."""
        found, rx = [], re.compile(pattern)

        def each(hwnd, _):
            if user32.IsWindowVisible(hwnd):
                n = user32.GetWindowTextLengthW(hwnd)
                buf = ctypes.create_unicode_buffer(n + 1)
                user32.GetWindowTextW(hwnd, buf, n + 1)
                if rx.search(buf.value):
                    found.append(hwnd)
            return True
        user32.EnumWindows(EnumWindowsProc(each), 0)
        return found[-1] if found else None

    def geometry(self, hwnd):
        r = wintypes.RECT()
        user32.GetWindowRect(hwnd, ctypes.byref(r))
        return r.left, r.top, r.right - r.left, r.bottom - r.top

    def activate(self, hwnd):
        """To the front. Windows lets a process bring a window forward only
        right after input: an Alt press first, as tools that do this do. When
        another window keeps the front (a toast, "New notification", did in kit
        run 41204726933), this thread joins the front window's input queue
        for a moment, which lifts that lock, and tries again."""
        alt = NAMED["alt"][0]
        for _ in range(5):
            _send(_scan(alt), _scan(alt, up=True))
            user32.ShowWindow(hwnd, 9)   # SW_RESTORE
            front = user32.GetForegroundWindow()
            mine = kernel32.GetCurrentThreadId()
            theirs = user32.GetWindowThreadProcessId(front, None) if front else 0
            joined = theirs and theirs != mine and user32.AttachThreadInput(mine, theirs, True)
            user32.BringWindowToTop(hwnd)
            user32.SetForegroundWindow(hwnd)
            if joined:
                user32.AttachThreadInput(mine, theirs, False)
            time.sleep(0.5)
            if user32.GetForegroundWindow() == hwnd:
                return
            # a toast already on screen kept the front through all of this (kit run
            # 41214959835, after toasts were turned off): it is closed
            title = ctypes.create_unicode_buffer(200)
            user32.GetWindowTextW(front, title, 200)
            if front and title.value == "New notification":
                user32.ShowWindow(front, 0)                # SW_HIDE
                user32.PostMessageW(front, 0x0010, 0, 0)   # WM_CLOSE


# For test/client-demo/windows.ps1, which types into its PowerShell window as
# run.sh does with xdotool:
#   python wininput.py click <x> <y> | type <text> | key <name>... | front <title regex> | release
#                      | place <title regex> <x> <y> <w> <h>
if __name__ == "__main__":
    import sys

    io, cmd, args = WinInput(), sys.argv[1], sys.argv[2:]
    if cmd == "click":
        x0, y0 = io.where()
        io.move(x0, y0, int(args[0]), int(args[1]), 0.6).join()
        io.click().join()
    elif cmd == "type":
        io.type(args[0], 75).join()
    elif cmd == "key":
        io.key(*args).join()
    elif cmd == "release":
        # modifiers Windows thinks are held: the web demos before this one typed into the
        # console through the shadow server (Win+R, Win+D), and after them nothing typed here
        # arrived (kit run 41199723802); each one found is let go
        held = []
        for name, vk in (("LShift", 0xA0), ("RShift", 0xA1), ("LCtrl", 0xA2), ("RCtrl", 0xA3),
                         ("LAlt", 0xA4), ("RAlt", 0xA5), ("LWin", 0x5B), ("RWin", 0x5C)):
            if user32.GetAsyncKeyState(vk) & 0x8000:
                held.append(name)
                scan = user32.MapVirtualKeyW(vk, 0)
                _send(_scan(scan, up=True, extended=vk in (0xA3, 0xA5, 0x5B, 0x5C)))
        print("held: " + (", ".join(held) or "none"))
    elif cmd in ("front", "place"):
        hwnd = io.find(args[0])
        if not hwnd:
            sys.exit(f"wininput: no window {args[0]}")
        if cmd == "place":
            user32.MoveWindow(hwnd, *map(int, args[1:5]), True)
        io.activate(hwnd)
        if user32.GetForegroundWindow() != hwnd:   # said, so a lost focus shows in run.log
            title = ctypes.create_unicode_buffer(200)
            user32.GetWindowTextW(user32.GetForegroundWindow(), title, 200)
            print(f"not in front; in front: {title.value!r}")
    else:
        sys.exit(f"wininput: {cmd}?")
