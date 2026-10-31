"""The demo's user at freerdp-tk's window (test/client-demo/run.sh, and
windows.ps1 on Windows).

Runs inside freerdp-tk's own process (sitecustomize.py hands it the window),
so it finds each field and button where Tk drew it, and works the window the
way a person does: the real pointer moves there, clicks and types (on Linux
xdotool, XTEST; on Windows SendInput, wininput.py), and the window answers to
those events alone. Nothing is set from here except through them. Steps run
from Tk's own loop (after), so the window keeps drawing while keys are typed.

CLIENT_DEMO_DIR holds its state: phase (1: fill in the form, save, connect,
work in GNOME, disconnect, quit; 2, freerdp-tk started again: double-click
the saved connection, which logs in with the password from the keyring),
driver.log, and the files run.sh waits for (phase1-done, done, failed).
CLIENT_DEMO_MODE: release (the kit's client, AV1) or uvx (Debian's client),
both to GNOME; windows (the kit's Windows client, to Windows' own Remote
Desktop on the same PC, a session of its own for the demo's user).
"""
import math
import os
import subprocess
import sys
import time
import tkinter as tk
import traceback

DIR = os.environ.get("CLIENT_DEMO_DIR", "/tmp/demo")
MODE = os.environ.get("CLIENT_DEMO_MODE", "release")
log = open(os.path.join(DIR, "driver.log"), "a", buffering=1)


def say(*words):
    print(time.strftime("%H:%M:%S"), *words, file=log)


def mark(name, text=""):
    with open(os.path.join(DIR, name), "w") as f:
        f.write(text)


def walk(widget):
    yield widget
    for child in widget.winfo_children():
        yield from walk(child)


def output(*argv) -> str:
    return subprocess.run(argv, capture_output=True, text=True).stdout.strip()


class XInput:
    """The pointer, the keys and the windows through xdotool (Linux)."""

    def where(self):
        x, y = output("xdotool", "getmouselocation", "--shell").split("\n")[:2]
        return int(x.split("=")[1]), int(y.split("=")[1])

    def move(self, x0, y0, x, y, seconds):
        """A smooth path, eased at both ends, in one xdotool call."""
        n = max(8, int(seconds * 40))
        argv = ["xdotool"]
        for i in range(1, n + 1):
            t = (1 - math.cos(math.pi * i / n)) / 2
            argv += ["mousemove", str(round(x0 + (x - x0) * t)),
                     str(round(y0 + (y - y0) * t)), "sleep", f"{seconds / n:.3f}"]
        return subprocess.Popen(argv)

    def click(self, times=1):
        return subprocess.Popen(["xdotool", "click", "--repeat", str(times), "--delay", "90", "1"])

    def type(self, text, delay=70):
        return subprocess.Popen(["xdotool", "type", "--delay", str(delay), text])

    def key(self, *keys):
        argv = ["xdotool"]
        for k in keys:
            argv += ["key", k, "sleep", "0.15"]
        return subprocess.Popen(argv)

    def find(self, name):
        ids = output("xdotool", "search", "--onlyvisible", "--name", name).split()
        return ids[-1] if ids else None

    def geometry(self, wid):
        geo = dict(line.split("=") for line in output("xdotool", "getwindowgeometry", "--shell", wid).split())
        return int(geo["X"]), int(geo["Y"]), int(geo["WIDTH"]), int(geo["HEIGHT"])

    def activate(self, wid):
        subprocess.run(["xdotool", "windowactivate", "--sync", wid])


def hands():
    if sys.platform == "win32":
        from wininput import WinInput
        return WinInput()
    return XInput()


class Driver:
    def __init__(self, root, app):
        self.root, self.app = root, app
        self.phase = open(os.path.join(DIR, "phase")).read().strip() or "1"
        self.io = hands()
        self.x, self.y = self.io.where()
        self.steps = self.phase1() if self.phase == "1" else self.phase2()
        say(f"phase {self.phase}, mode {MODE}")
        # what the checks in wasm-session.sh read: the Python that runs the
        # window (uvx: uv's own, after freerdp-tk started again), the clients
        # "(auto)" chose from (release: its own first, Debian's after it),
        # and the glyphs (ASCII where Tk has no Xft)
        from freerdp_tk import app as tkapp
        say("python:", sys.base_prefix)  # the install behind uvx's environment
        say("clients:", self.app.clients)
        say("glyphs:", getattr(tkapp, "GLYPHS", None))
        root.after(1500, self.tick)

    # each step yields how long to wait (seconds) or a process to wait for
    def tick(self):
        try:
            wait = next(self.steps)
        except StopIteration:
            return
        except Exception:
            say("FAILED\n" + traceback.format_exc())
            mark("failed", traceback.format_exc())
            return
        if hasattr(wait, "poll"):   # a process, or a wininput job
            self.wait_for(wait)
        else:
            self.root.after(int(wait * 1000), self.tick)

    def wait_for(self, proc):
        try:
            busy = proc.poll() is None
        except Exception:
            say("FAILED\n" + traceback.format_exc())
            mark("failed", traceback.format_exc())
            return
        if busy:
            self.root.after(30, self.wait_for, proc)
        else:
            self.tick()

    # ---- the pointer and the keys (XInput or WinInput) --------------------

    def move(self, x, y, seconds=0.6):
        """A smooth path to (x, y), eased at both ends."""
        job = self.io.move(self.x, self.y, x, y, seconds)
        self.x, self.y = x, y
        return job

    def to(self, widget, dx=None, dy=None):
        self.root.update_idletasks()
        x = widget.winfo_rootx() + (widget.winfo_width() // 2 if dx is None else dx)
        y = widget.winfo_rooty() + (widget.winfo_height() // 2 if dy is None else dy)
        return self.move(x, y)

    def click(self, times=1):
        return self.io.click(times)

    def type(self, text, delay=70):
        return self.io.type(text, delay)

    def key(self, *keys):
        return self.io.key(*keys)

    # ---- freerdp-tk's widgets ---------------------------------------------

    def field(self, var):
        for w in walk(self.root):
            if w.winfo_class() in ("TEntry", "TCombobox") and str(w.cget("textvariable")) == str(var):
                return w
        raise LookupError(f"no field for {var}")

    def button(self, text):
        for w in walk(self.root):
            if w.winfo_class() == "TButton" and w.cget("text") == text:
                return w
        raise LookupError(f"no button {text}")

    def tab(self, text):
        """The notebook and the middle of the tab named text."""
        for nb in walk(self.root):
            if nb.winfo_class() != "TNotebook":
                continue
            for x in range(2, nb.winfo_width(), 4):
                try:
                    i = nb.index(f"@{x},8")
                except tk.TclError:
                    continue
                if i != "" and nb.tab(i, "text") == text:
                    start = x
                    while x < nb.winfo_width() and nb.index(f"@{x},8") == i:
                        x += 2
                    return nb, (start + x) // 2
        raise LookupError(f"no tab {text}")

    def fill(self, var, text, select_all=False):
        yield self.to(self.field(var))
        yield self.click(3 if select_all else 1)
        yield 0.2
        yield self.type(text)
        yield 0.4

    def choose(self, var, value, choices):
        """A read-only list: click it, then Down to the value, and Return."""
        current = choices.index(var.get())
        yield self.to(self.field(var))
        yield self.click()
        yield 0.6
        yield self.key(*["Down"] * (choices.index(value) - current), "Return")
        yield 0.5
        if var.get() != value:
            raise RuntimeError(f"{value} not chosen: {var.get()}")

    def window(self, name, timeout=40):
        """The id of the window whose title matches name, once it shows
        (polled from Tk's loop, so freerdp-tk keeps drawing)."""
        end = time.monotonic() + timeout
        while True:
            wid = self.io.find(name)
            if wid:
                return wid
            if time.monotonic() > end:
                raise TimeoutError(f"no window {name} after {timeout} s")
            yield 0.3

    def session(self):
        """The session's window and its middle, once it shows."""
        wid = yield from self.window("^FreeRDP: ")
        x, y, w, h = self.io.geometry(wid)
        say("session window", wid, (x, y, w, h))
        return wid, x + w // 2, y + h // 2

    # ---- the two visits ---------------------------------------------------

    def phase1(self):
        from freerdp_tk import app as tkapp
        a = self.app
        win = MODE == "windows"
        yield 1.0
        if win:   # Windows' own Remote Desktop on this PC (127.0.0.2: a loopback address of its own)
            yield from self.fill(a.name, "windows-desktop")
            yield from self.fill(a.vars["host"], "127.0.0.2")
            yield from self.fill(a.vars["user"], os.environ["CLIENT_DEMO_USER"])
            yield from self.fill(a.password, os.environ["CLIENT_DEMO_PASSWORD"])
        else:
            yield from self.fill(a.name, "gnome-desktop")
            yield from self.fill(a.vars["host"], "rdp-gnome")
            yield from self.fill(a.vars["user"], "tester")
            yield from self.fill(a.password, "kit-test-pw")
        # the throwaway server's certificate is its own, made when its image was built
        yield from self.choose(a.vars["cert"], "ignore", tkapp.CERT_CHOICES)
        nb, x = self.tab("Display")
        yield self.to(nb, dx=x, dy=10)
        yield self.click()
        yield 0.6
        yield from self.fill(a.vars["size"], "1280x720", select_all=True)
        if MODE == "release":
            # the kit's client has AV1 (dav1d); Debian's has not, and gets H.264
            yield from self.choose(a.vars["gfx"], "AV1:i444", tkapp.GFX_CHOICES)
        # (windows: the default; Windows' own server picks H.264, it has no AV1)
        yield 0.8
        say("keyring:", repr(a.keyring_problem) if a.keyring_problem else "usable")
        if a.keyring_problem:
            raise RuntimeError(f"no keyring: {a.keyring_problem}")
        yield self.to(self.button("Save"))
        yield self.click()
        yield 1.0
        say("command:", a.preview.get("1.0", "end").strip())
        yield self.to(self.button("Connect"))
        yield self.click()
        wid, cx, cy = yield from self.session()
        yield 20 if win else 12   # Windows: the user's first sign-in on this PC
        # the keys go to the window that has the focus, so a click on the desktop first
        yield self.move(cx, cy, 0.8)
        yield self.click()
        self.io.activate(wid)
        yield 1.0
        if win:
            # in Windows: Win+R (the client holds the keyboard, so Windows here leaves it
            # to the session), Notepad and a line, then webdemo: Firefox in the session with
            # Big Buck Bunny next to the WebGL Aquarium, its sound through the session
            yield self.io.chord("super", "r")
            yield 1.5
            yield self.type("notepad", 110)
            yield self.key("Return")
            yield 3.0
            yield self.type("Typed in Windows through freerdp-tk.", 80)
            yield 2.0
            yield self.io.chord("super", "r")
            yield 1.5
            yield self.type("webdemo", 110)
            yield self.key("Return")
            yield 22.0
        else:
            # in GNOME: the search, a terminal, a line, then webdemo there: Firefox with
            # Big Buck Bunny next to the WebGL Aquarium, its sound through the session
            yield self.key("super")
            yield 2.0
            yield self.type("terminal", 110)
            yield 2.0
            yield self.key("Return")
            yield 5.0
            yield self.type("echo Typed in GNOME through freerdp-tk.", 80)
            yield self.key("Return")
            yield 1.5
            yield self.type("webdemo", 110)
            yield self.key("Return")
            yield 22.0
        # back to freerdp-tk: disconnect, then quit it
        tkwin = self.io.find("^FreeRDP$")
        if tkwin:
            self.io.activate(tkwin)
        yield 1.0
        # Disconnect ends the sessions picked in Running
        x, y, w, h = a.running_list.bbox(0)
        yield self.to(a.running_list, dx=x + 50, dy=y + h // 2)
        yield self.click()
        yield 0.5
        yield self.to(self.button("Disconnect"))
        yield self.click()
        # quit once the session has ended (else freerdp-tk asks whether to close it)
        for _ in range(100):
            yield 0.2
            if not a.sessions:
                break
        else:
            raise TimeoutError("the session did not end after Disconnect")
        yield 2.0
        say("log:", a.log.get("1.0", "end").strip().replace("\n", " | ")[-600:])
        mark("phase", "2")
        mark("phase1-done")
        self.root.after(200, a._quit)

    def phase2(self):
        a = self.app
        yield 1.5
        names = a.saved_list.get(0, "end")
        say("saved:", names)
        i = names.index("windows-desktop" if MODE == "windows" else "gnome-desktop")
        x, y, w, h = a.saved_list.bbox(i)
        yield self.to(a.saved_list, dx=x + 40, dy=y + h // 2)
        yield 0.4
        yield self.click(2)
        # the password comes from the keyring: no dialog asks for it
        wid, cx, cy = yield from self.session()
        yield 10   # (Windows: the same session again, the video still playing)
        yield self.move(cx, cy, 0.8)
        yield 5.0
        say("log:", a.log.get("1.0", "end").strip().replace("\n", " | ")[-600:])
        mark("done")


def install():
    """Starts the driver once freerdp-tk's window enters Tk's loop."""
    plain = tk.Misc.mainloop

    def mainloop(self, n=0):
        from freerdp_tk import app as tkapp
        ui = [w for w in self.winfo_children() if isinstance(w, tkapp.App)]
        if ui:
            Driver(self, ui[0])
        return plain(self, n)

    tk.Misc.mainloop = mainloop
