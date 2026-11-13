"""Build the wheel for this platform with the native bundle inside.

    python bindings/python/build_wheel.py [--bundle DIR] [--plat-name TAG]

`--bundle` defaults to build/libqules (see build/build_library.jl). The wheel
is written to bindings/python/dist/. On Linux the default tag is
linux_x86_64; retag it with the manylinux tag reported by `auditwheel show`.
"""

import argparse
import platform
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[1]


def default_plat_name():
    machine = platform.machine().lower()
    if sys.platform == "win32":
        return "win_amd64"
    if sys.platform == "darwin":
        return "macosx_11_0_arm64" if machine == "arm64" else "macosx_10_15_x86_64"
    return f"linux_{machine}"


def library(bundle):
    if sys.platform == "win32":
        return bundle / "bin" / "qules.dll"
    return bundle / "lib" / ("libqules.dylib" if sys.platform == "darwin" else "libqules.so")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--bundle", type=Path, default=REPO / "build" / "libqules")
    parser.add_argument("--plat-name", default=default_plat_name())
    args = parser.parse_args()
    bundle = args.bundle.resolve()
    if not library(bundle).is_file():
        print(f"no {library(bundle).name} in {bundle}; run build/build_library.jl first",
              file=sys.stderr)
        return 1

    dist = HERE / "dist"
    dist.mkdir(exist_ok=True)
    with tempfile.TemporaryDirectory() as tmp:
        stage = Path(tmp) / "qules"
        shutil.copytree(HERE, stage, ignore=shutil.ignore_patterns(
            "dist", "build", "tests", "*.egg-info", "__pycache__"))
        # include/ is only needed by C hosts. Wheels cannot hold symlinks, so
        # linked libraries are copied as files.
        lib_dir = "bin" if sys.platform == "win32" else "lib"
        for part in (lib_dir, "share"):
            shutil.copytree(bundle / part, stage / "qules" / "_bundle" / part, symlinks=False)
        # Pure Python code, but the bundle is platform specific.
        (stage / "setup.cfg").write_text(
            f"[bdist_wheel]\npython_tag = py3\nplat_name = {args.plat_name}\n")
        subprocess.run([sys.executable, "-m", "pip", "wheel", "--no-deps", "-w", str(dist),
                        str(stage)], check=True)

    for wheel in sorted(dist.glob(f"qules-*-py3-none-{args.plat_name}.whl")):
        print(f"{wheel}  {wheel.stat().st_size / 2**20:.1f} MiB")
    return 0


if __name__ == "__main__":
    sys.exit(main())
