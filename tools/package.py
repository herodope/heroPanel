#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""
Build the release ZIP that goes up as a GitHub release asset.

    python tools/package.py [--allow-dirty] [--out DIR]

The file list comes from `git ls-files heroPanel/` rather than from a walk of
the working directory, so what a player installs is what is in the repo. A stray
.bak, an editor swapfile or a half-finished module cannot ride along, and
neither can a file that was never committed - which is the failure this exists
to prevent, because it does not surface until someone installs the zip and the
addon does not load.

For the same reason the build refuses to run against a dirty heroPanel/. A zip
cut from uncommitted edits cannot be reproduced from the tag it is attached to.
--allow-dirty is there for trying something out; it puts -dirty in the filename
so such a build cannot later be mistaken for a clean one.

Entry timestamps come from the HEAD commit rather than from the filesystem, so
one commit always produces the same bytes and two builds can be compared by
hash. Entries are sorted for the same reason.

This script is the one thing under tools/ that is tracked. The rest of the
directory is author-side tooling of no use to anyone installing the addon, but
the packaging step has to be reproducible by whoever cuts the next release.
"""

import argparse
import io
import os
import re
import subprocess
import sys
import zipfile

ADDON = "heroPanel"
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def git(*args):
    return subprocess.check_output(("git",) + args, cwd=ROOT).decode("utf-8").strip()


def toc_version():
    path = os.path.join(ROOT, ADDON, ADDON + ".toc")
    with io.open(path, encoding="utf-8-sig") as handle:
        toc = handle.read()
    match = re.search(r"^##\s*Version:\s*(.+?)\s*$", toc, re.M)
    if not match:
        sys.exit("no '## Version:' line in " + ADDON + ".toc")
    return match.group(1)


def main():
    parser = argparse.ArgumentParser(description="Build the heroPanel release zip.")
    parser.add_argument("--allow-dirty", action="store_true",
                        help="build even with uncommitted changes under " + ADDON + "/")
    parser.add_argument("--out", default=os.path.join(ROOT, "release"),
                        help="directory to write the zip into (default: release/)")
    args = parser.parse_args()

    dirty = git("status", "--porcelain", "--", ADDON) != ""
    if dirty and not args.allow_dirty:
        sys.exit("uncommitted changes under %s/ - commit them, or pass --allow-dirty."
                 % ADDON)

    files = sorted(f for f in git("ls-files", "--", ADDON).splitlines() if f)
    if not files:
        sys.exit("git has no tracked files under %s/" % ADDON)

    missing = [f for f in files if not os.path.isfile(os.path.join(ROOT, f))]
    if missing:
        sys.exit("tracked but not on disk:\n  " + "\n  ".join(missing))

    stamp = git("log", "-1", "--format=%cd", "--date=format:%Y %m %d %H %M %S").split()
    date_time = tuple(int(part) for part in stamp)

    name = "%s-%s%s.zip" % (ADDON, toc_version(), "-dirty" if dirty else "")
    if not os.path.isdir(args.out):
        os.makedirs(args.out)
    path = os.path.join(args.out, name)

    with zipfile.ZipFile(path, "w", zipfile.ZIP_DEFLATED) as bundle:
        for name_in_repo in files:
            info = zipfile.ZipInfo(name_in_repo, date_time=date_time)
            info.compress_type = zipfile.ZIP_DEFLATED
            info.external_attr = 0o644 << 16
            with io.open(os.path.join(ROOT, name_in_repo), "rb") as handle:
                bundle.writestr(info, handle.read())

    print("%s  (%d files, %d bytes)" % (path, len(files), os.path.getsize(path)))
    print("built from %s%s" % (git("rev-parse", "--short", "HEAD"),
                               ", DIRTY" if dirty else ""))


if __name__ == "__main__":
    main()
