"""Private ctypes layer for the QULES native bundle.

Locates the native library inside a bundle directory (``bin/qules.dll``,
``lib/libqules.so`` or ``lib/libqules.dylib``), initializes the embedded Julia
runtime exactly once per process and declares the C signatures from
``qules.h`` / ``julia_init.h``.

Do not import this module directly; use the ``qules`` package API.
"""

from __future__ import annotations

import atexit
import ctypes
import os
import sys
from typing import Optional

#: Environment variable that overrides the bundle shipped inside the package.
BUNDLE_ENV = "QULES_BUNDLE"

#: Bundle copied into the package by build_wheel.py.
PACKAGED_BUNDLE = os.path.join(os.path.dirname(os.path.abspath(__file__)), "_bundle")

c_double_p = ctypes.POINTER(ctypes.c_double)

#: ``double (*)(size_t n, const double *x, void *user_data)``
OBJECTIVE = ctypes.CFUNCTYPE(ctypes.c_double, ctypes.c_size_t, c_double_p, ctypes.c_void_p)
#: ``void (*)(const char *line, void *user_data)``
LOG = ctypes.CFUNCTYPE(None, ctypes.c_char_p, ctypes.c_void_p)

_lib: Optional[ctypes.CDLL] = None  # the loaded DLL, set once per process
_bundle_dir: Optional[str] = None   # normalized path of the loaded bundle
_dll_dir = None                      # os.add_dll_directory handle, kept alive for the process
_argv = None                         # argv passed to init_julia, kept alive for the process


def library_path(bundle_dir: str) -> str:
    """Path of the native library inside `bundle_dir` for this platform."""
    if sys.platform == "win32":
        return os.path.join(bundle_dir, "bin", "qules.dll")
    name = "libqules.dylib" if sys.platform == "darwin" else "libqules.so"
    return os.path.join(bundle_dir, "lib", name)


def resolve_bundle_dir(bundle_dir: Optional[str]) -> str:
    """Return the absolute bundle directory: the argument, else ``$QULES_BUNDLE``,
    else the bundle shipped inside the package."""
    if bundle_dir is None:
        bundle_dir = os.environ.get(BUNDLE_ENV)
    if not bundle_dir:
        if not os.path.isfile(library_path(PACKAGED_BUNDLE)):
            raise ValueError(
                "this qules installation contains no native bundle; pass its directory "
                f"to qules.load() or set the {BUNDLE_ENV} environment variable")
        bundle_dir = PACKAGED_BUNDLE
    return os.path.abspath(os.fspath(bundle_dir))


def load(bundle_dir: Optional[str]) -> ctypes.CDLL:
    """Load the bundle's native library and initialize Julia; idempotent.

    Julia can be initialized only once per process, so a second call with the
    same bundle returns the already loaded library and a second call with a
    different bundle raises ``RuntimeError``.
    """
    global _lib, _bundle_dir, _dll_dir, _argv
    bundle_dir = resolve_bundle_dir(bundle_dir)
    key = os.path.normcase(bundle_dir)
    if _lib is not None:
        if key != _bundle_dir:
            raise RuntimeError(
                f"QULES is already loaded from {_bundle_dir!r}; "
                "only one bundle can be loaded per process")
        return _lib

    lib_path = library_path(bundle_dir)
    if not os.path.isfile(lib_path):
        raise FileNotFoundError(f"{os.path.basename(lib_path)} not found in {bundle_dir}")

    if sys.platform == "win32":
        # Julia loads its dependents by name: make bin/ visible both to
        # LoadLibrary (add_dll_directory) and to the Julia loader (PATH).
        bin_dir = os.path.dirname(lib_path)
        _dll_dir = os.add_dll_directory(bin_dir)
        os.environ["PATH"] = bin_dir + os.pathsep + os.environ.get("PATH", "")
        lib = ctypes.CDLL(lib_path)
    else:
        # Dependents are found through the library's rpath.
        lib = ctypes.CDLL(lib_path, mode=ctypes.RTLD_GLOBAL)
    _declare(lib)
    _argv = (ctypes.c_char_p * 2)(b"qules", None)
    lib.init_julia(1, _argv)
    atexit.register(lib.shutdown_julia, 0)
    _lib = lib
    _bundle_dir = key
    return lib


def require() -> ctypes.CDLL:
    """Return the loaded library, loading the default bundle on first use."""
    return _lib if _lib is not None else load(None)


def decode(data: Optional[bytes]) -> str:
    """Decode a log line from the native side."""
    return (data or b"").decode("utf-8", "replace")


def _declare(lib: ctypes.CDLL) -> None:
    """Set argtypes/restypes for every function in qules.h / julia_init.h."""
    c = ctypes
    signatures = [
        ("init_julia", None, [c.c_int, c.POINTER(c.c_char_p)]),
        ("shutdown_julia", None, [c.c_int]),
        ("qules_version_major", c.c_int, []),
        ("qules_version_minor", c.c_int, []),
        ("qules_version_patch", c.c_int, []),
        ("qules_set_log_mode", c.c_int, [c.c_int, c.c_void_p, c.c_void_p]),
        ("qules_log_read", c.c_size_t, [c.c_char_p, c.c_size_t]),
        ("qules_optimize_c", c.c_int, [
            c.c_void_p, c.c_size_t, c_double_p, c.c_size_t,
            c.c_double, c.c_double, c.c_double, c.c_int, c.c_int,
            c_double_p, c.POINTER(c.c_double), c.POINTER(c.c_size_t),
            c.POINTER(c.c_double), c.c_void_p]),
        ("qules_session_create", c.c_int64, [
            c.c_size_t, c_double_p, c.c_size_t,
            c.c_double, c.c_double, c.c_double, c.c_int, c.c_int]),
        ("qules_session_ask", c.c_int, [c.c_int64, c_double_p]),
        ("qules_session_tell", c.c_int, [c.c_int64, c.c_double]),
        ("qules_session_is_finished", c.c_int, [c.c_int64]),
        ("qules_session_get_best", c.c_int, [
            c.c_int64, c_double_p, c.POINTER(c.c_double),
            c.POINTER(c.c_size_t), c.POINTER(c.c_double)]),
        ("qules_session_free", c.c_int, [c.c_int64]),
    ]
    for name, restype, argtypes in signatures:
        fn = getattr(lib, name)
        fn.restype = restype
        fn.argtypes = argtypes
