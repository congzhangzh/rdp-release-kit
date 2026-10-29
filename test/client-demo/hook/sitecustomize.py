# Python imports this module at start when its folder is on the path
# (test/client-demo/run.sh puts it there for the demo only): it hands
# freerdp-tk's window to the demo's driver, drive.py, next to it.
import os
import sys

if os.environ.get("CLIENT_DEMO_DIR"):
    sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
    import drive

    drive.install()
