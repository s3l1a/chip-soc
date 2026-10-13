#!/usr/bin/env python3
"""Fetch only pinned engine source into the ignored external directory, no WAD."""
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parent
SHA = (ROOT / "doomgeneric.lock").read_text(encoding="ascii").strip()
URL = "https://github.com/ozkl/doomgeneric.git"
CHECKOUT = ROOT / "external" / "doomgeneric"


def git(*args):
    # Trust only this explicit checkout on FAT/exFAT, without changing git config.
    return subprocess.check_output(["git", "-c", f"safe.directory={CHECKOUT.as_posix()}",
                                    "-C", str(CHECKOUT), *args], text=True).strip()


def verify():
    if git("rev-parse", "HEAD") != SHA or git("status", "--porcelain"):
        raise RuntimeError("checkout must be clean and exactly match doomgeneric.lock")
    license_text = (CHECKOUT / "LICENSE").read_text(encoding="utf-8")
    notice = (CHECKOUT / "doomgeneric" / "w_file.c").read_text(encoding="utf-8")
    if "Version 2, June 1991" not in license_text or "either version 2" not in notice:
        raise RuntimeError("pinned GPL license/notice verification failed")
    print(f"DoomGeneric {SHA}: clean checkout, GPL v2 text and v2-or-later notice verified")


def main():
    if not CHECKOUT.exists():
        CHECKOUT.parent.mkdir(parents=True, exist_ok=True)
        subprocess.run(["git", "clone", "--no-checkout", URL, str(CHECKOUT)], check=True)
        git("fetch", "--no-tags", "origin", SHA)
        git("checkout", "--detach", SHA)
    verify()  # Never reset or overwrite an existing user's checkout.


if __name__ == "__main__":
    main()
