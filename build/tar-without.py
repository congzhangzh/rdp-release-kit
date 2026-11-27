#!/usr/bin/env python3
"""tar-without.py <in.tar> <out.tar> <pattern>...: a copy of a git archive without some paths.

Each member whose path matches a pattern (fnmatch, on the whole path), or lies under a matched
directory, is left out; every other member is copied with its header (name, mode, time, owner)
and content as they are. The archive's pax global header, where git archive keeps the commit
(git get-tar-commit-id), is kept too, so the copy still names its commit. Used by
build/gpl-sources.sh for libavm's source without the bundles its build doesn't read.
"""
import fnmatch
import sys
import tarfile


def main() -> int:
    if len(sys.argv) < 4:
        print(__doc__.splitlines()[0], file=sys.stderr)
        return 2
    src, dst, patterns = sys.argv[1], sys.argv[2], sys.argv[3:]
    dropped = []
    with tarfile.open(src, "r:", encoding="utf-8") as tin, \
            tarfile.open(dst, "w:", format=tarfile.PAX_FORMAT, encoding="utf-8",
                         pax_headers=dict(tin.pax_headers)) as tout:
        for m in tin:
            name = m.name.rstrip("/")
            if any(fnmatch.fnmatchcase(name, p) for p in patterns) or \
                    any(name.startswith(d + "/") for d in dropped):
                if m.isdir():
                    dropped.append(name)
                continue
            tout.addfile(m, tin.extractfile(m) if m.isfile() else None)
    unused = [p for p in patterns if not any(fnmatch.fnmatchcase(d, p) for d in dropped)
              and "*" not in p]
    if unused:
        print(f"tar-without.py: no directory {', '.join(unused)} in {src}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
