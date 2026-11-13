"""Build the wheel for this platform with the native bundle inside.

    python bindings/python/build_wheel.py [--bundle DIR] [--plat-name TAG]

`--bundle` defaults to build/libqules (see build/build_library.jl). The wheel
is written to bindings/python/dist/. The default tag is win_amd64 on Windows,
the oldest macOS the bundle's libraries support on macOS, and linux_<arch> on
Linux (pass the manylinux tag of the build machine instead).
"""

import argparse
import os
import platform
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[1]
SYMLINKS = "symlinks.txt"  # read by qules._native


def library(bundle):
    if sys.platform == "win32":
        return bundle / "bin" / "qules.dll"
    return bundle / "lib" / ("libqules.dylib" if sys.platform == "darwin" else "libqules.so")


def macos_plat_name(bundle):
    """Tag from the highest minimum macOS version among the bundle's dylibs."""
    oldest = (11, 0)
    for path in bundle.rglob("*.dylib"):
        if path.is_symlink():
            continue
        out = subprocess.run(["otool", "-l", str(path)], capture_output=True, text=True).stdout
        for major, minor in re.findall(r"minos (\d+)\.(\d+)", out):
            oldest = max(oldest, (int(major), int(minor)))
    return f"macosx_{oldest[0]}_{oldest[1]}_{platform.machine().lower()}"


def default_plat_name(bundle):
    if sys.platform == "win32":
        return "win_amd64"
    if sys.platform == "darwin":
        return macos_plat_name(bundle)
    return f"linux_{platform.machine().lower()}"


def copy_bundle_part(src, dst, bundle, links):
    """Copy `src` to `dst`. Wheels cannot hold symlinks, so a symlink to a file
    inside the bundle is recorded in `links` instead of being copied."""
    for root, dirs, files in os.walk(src):
        root = Path(root)
        target_root = dst / root.relative_to(src)
        target_root.mkdir(parents=True, exist_ok=True)
        for name in dirs + files:
            path = root / name
            if path.is_symlink():
                resolved = path.resolve()
                if resolved.is_file() and resolved.is_relative_to(bundle):
                    links.append((path.relative_to(bundle).as_posix(), os.readlink(path)))
                    continue
                if name in dirs:  # os.walk does not descend into linked directories
                    shutil.copytree(path, target_root / name)
                    continue
            if name in files:
                shutil.copy2(path, target_root / name)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--bundle", type=Path, default=REPO / "build" / "libqules")
    parser.add_argument("--plat-name")
    args = parser.parse_args()
    bundle = args.bundle.resolve()
    if not library(bundle).is_file():
        print(f"no {library(bundle).name} in {bundle}; run build/build_library.jl first",
              file=sys.stderr)
        return 1
    plat_name = args.plat_name or default_plat_name(bundle)

    dist = HERE / "dist"
    dist.mkdir(exist_ok=True)
    with tempfile.TemporaryDirectory() as tmp:
        stage = Path(tmp) / "qules"
        shutil.copytree(HERE, stage, ignore=shutil.ignore_patterns(
            "dist", "build", "tests", "*.egg-info", "__pycache__"))
        packaged = stage / "qules" / "_bundle"
        links = []
        # include/ is only needed by C hosts.
        for part in ("bin" if sys.platform == "win32" else "lib", "share"):
            copy_bundle_part(bundle / part, packaged / part, bundle, links)
        if links:
            (packaged / SYMLINKS).write_text("".join(f"{p}\t{t}\n" for p, t in links))
        # Pure Python code, but the bundle is platform specific.
        (stage / "setup.cfg").write_text(
            f"[bdist_wheel]\npython_tag = py3\nplat_name = {plat_name}\n")
        subprocess.run([sys.executable, "-m", "pip", "wheel", "--no-deps", "-w", str(dist),
                        str(stage)], check=True)

    for wheel in sorted(dist.glob(f"qules-*-py3-none-{plat_name}.whl")):
        print(f"{wheel}  {wheel.stat().st_size / 2**20:.1f} MiB")
    return 0


if __name__ == "__main__":
    sys.exit(main())
