# Python imports this module at start when its folder is on the path
# (test/client-demo/run.sh puts it there for the demo only): it hands
# freerdp-tk's window to the demo's driver, drive.py, next to it. A Python
# without Tk (the system's, which plain uvx takes first, before freerdp-tk
# starts again with uv's own) gets nothing and no message: the terminal in
# the video shows only freerdp-tk's own words.
import importlib.util
import os
import sys

if os.environ.get("CLIENT_DEMO_DIR") and importlib.util.find_spec("tkinter"):
    sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
    import drive

    drive.install()
