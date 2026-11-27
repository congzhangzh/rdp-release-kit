# freerdp-tk's bundled Python under the hardened runtime, as the signed job runs it:
#
#   PYTHONPATH=<pkg>/lib/freerdp-tk <pkg>/python/bin/python3 -s python-runtime-check.py
#
# Each part loads code the hardened runtime polices: _tkinter and Tcl/Tk (dylibs: library
# validation), Tcl's Thread and itcl packages (dlopen'ed by Tcl: library validation), a ctypes
# callback (a libffi closure: executable memory), freerdp-tk and keyring's macOS backend (ctypes
# into Security.framework). Exit 0 only if all of them work; prints one line per part.
import ctypes
import importlib.util
import sys

failed = []


def part(name, fn):
    try:
        detail = fn()
        print(f"ok    {name}{': ' + detail if detail else ''}")
    except BaseException as e:  # noqa: BLE001 - report every failure, then exit 1
        failed.append(name)
        print(f"FAIL  {name}: {type(e).__name__}: {e}")


def tcl():
    import tkinter
    t = tkinter.Tcl()
    assert t.eval("expr {6 * 7}") == "42"
    return f"Tcl {t.eval('info patchlevel')}"


def tcl_packages():
    import tkinter
    t = tkinter.Tcl()
    return f"Thread {t.eval('package require Thread')}, itcl {t.eval('package require itcl')}"


def tk():
    import _tkinter
    import tkinter  # noqa: F401
    return f"Tk {_tkinter.TK_VERSION} (module loaded; no window here)"


def ctypes_callback():
    libc = ctypes.CDLL(None)
    compare = ctypes.CFUNCTYPE(ctypes.c_int, ctypes.POINTER(ctypes.c_int), ctypes.POINTER(ctypes.c_int))
    values = (ctypes.c_int * 6)(5, 1, 4, 2, 6, 3)
    libc.qsort(values, len(values), ctypes.sizeof(ctypes.c_int), compare(lambda a, b: a[0] - b[0]))
    assert list(values) == [1, 2, 3, 4, 5, 6], list(values)
    return "qsort called back into Python"


def freerdp_tk():
    import freerdp_tk.app  # noqa: F401
    if importlib.util.find_spec("freerdp_tk.credentials"):
        import keyring.backends.macOS  # noqa: F401
        return "freerdp_tk.app, keyring.backends.macOS"
    return "freerdp_tk.app"


print(f"Python {sys.version.split()[0]} at {sys.executable}")
part("Tcl", tcl)
part("Tcl packages Thread and itcl (dlopen)", tcl_packages)
part("Tk", tk)
part("ctypes callback (libffi closure)", ctypes_callback)
part("freerdp-tk", freerdp_tk)
sys.exit(1 if failed else 0)
