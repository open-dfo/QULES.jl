"""Python binding for the QULES optimizer (Windows x64 native bundle).

Uses only ctypes. `load` starts Julia once per process; it is shut down at
interpreter exit. See README.md for usage.
"""

from __future__ import annotations

import ctypes
import math
import os
from dataclasses import dataclass
from typing import Callable, List, Optional, Sequence, Tuple, Union

from . import _native

__all__ = ["load", "optimize", "Session", "Result", "QulesError", "version"]

__version__ = "0.1.0"

Objective = Callable[[List[float]], float]
LogSink = Callable[[str], None]


class QulesError(RuntimeError):
    """Raised when a QULES C function reports a non-zero status."""

    def __init__(self, status: int, function: str):
        self.status = int(status)
        self.function = function
        super().__init__(f"{function} failed with status {self.status}")


@dataclass
class Result:
    """Outcome of an optimization run.

    `delta` is the final trust-region radius; for a `Session` it is NaN until
    the session has finished.
    """

    x_best: List[float]
    f_best: float
    evals: int
    delta: float


def load(bundle_dir: Union[str, os.PathLike, None] = None) -> None:
    """Load the native bundle and initialize Julia. Must precede every other call.

    `bundle_dir` is the directory containing `bin/qules.dll`; when omitted the
    `QULES_BUNDLE` environment variable is used. Loading is idempotent for the
    same directory. Julia cannot be re-initialized, so only one bundle can be
    loaded per process and it is never unloaded before interpreter exit.
    """
    _native.load(bundle_dir)


def version() -> Tuple[int, int, int]:
    """Return the loaded bundle's (major, minor, patch) version."""
    lib = _native.require()
    return (lib.qules_version_major(), lib.qules_version_minor(), lib.qules_version_patch())


def _start_vector(x0: Sequence[float]):
    x0 = [float(v) for v in x0]
    if not x0:
        raise ValueError("x0 must not be empty")
    return x0, (ctypes.c_double * len(x0))(*x0)


def _set_log_mode(lib: ctypes.CDLL, mode: int, callback=None) -> None:
    pointer = ctypes.cast(callback, ctypes.c_void_p) if callback is not None else None
    rc = lib.qules_set_log_mode(mode, pointer, None)
    if rc != 0:
        raise QulesError(rc, "qules_set_log_mode")


def optimize(f: Objective, x0: Sequence[float], *, max_evals: int = 300, delta0: float = 1.0,
             delta_min: float = 1e-8, delta_max: float = 100.0, verbose: bool = False,
             rotation: bool = True, log: LogSink = print) -> Result:
    """Minimize `f(x)` starting from `x0` and return a `Result`.

    `f` receives a fresh list of floats and must return a number. If `f`
    raises, the optimizer sees NaN for that point and the original exception is
    re-raised once the native call has returned. With `verbose=True` each line
    of the iteration table is passed to `log(line)` (without a trailing
    newline); the default sink is `print`, i.e. Python's `sys.stdout`.
    """
    lib = _native.require()
    x0, x_start = _start_vector(x0)
    n = len(x0)
    errors: List[BaseException] = []  # first exception raised inside a callback

    def objective(n_x, x_ptr, _user_data):
        try:
            return float(f(x_ptr[:n_x]))
        except BaseException as exc:  # never let anything cross the C ABI
            errors.append(exc)
            return math.nan

    def on_line(line, _user_data):
        try:
            log(_native.decode(line).rstrip("\n"))
        except BaseException as exc:
            errors.append(exc)

    objective_cb = _native.OBJECTIVE(objective)   # must outlive the C call
    log_cb = _native.LOG(on_line) if verbose else None
    x_best = (ctypes.c_double * n)()
    f_best = ctypes.c_double()
    evals = ctypes.c_size_t()
    delta = ctypes.c_double()

    if verbose:
        _set_log_mode(lib, 1, log_cb)
    try:
        status = lib.qules_optimize_c(
            ctypes.cast(objective_cb, ctypes.c_void_p), n, x_start, max_evals,
            delta0, delta_min, delta_max, int(bool(verbose)), int(bool(rotation)),
            x_best, ctypes.byref(f_best), ctypes.byref(evals), ctypes.byref(delta), None)
    finally:
        if verbose:
            _set_log_mode(lib, 0)
    if errors:
        raise errors[0]
    if status != 0:
        raise QulesError(status, "qules_optimize_c")
    return Result(list(x_best), f_best.value, evals.value, delta.value)


class Session:
    """Ask/tell driver for the same algorithm as `optimize()`.

        with qules.Session(x0, max_evals=40) as s:
            while (x := s.ask()) is not None:
                s.tell(f(x))
            result = s.best()

    With `verbose=True` the log goes through the process-wide buffered mode and
    is handed to `log(line)` after each `tell()` and at `close()`; the log mode
    is reset to stdout at `close()`. Use the session as a context manager or
    call `close()` to release the native state.
    """

    def __init__(self, x0: Sequence[float], *, max_evals: int = 300, delta0: float = 1.0,
                 delta_min: float = 1e-8, delta_max: float = 100.0, verbose: bool = False,
                 rotation: bool = True, log: LogSink = print):
        self._lib = lib = _native.require()
        x0, x_start = _start_vector(x0)
        self._n = len(x0)
        self._x = (ctypes.c_double * self._n)()
        self._log: Optional[LogSink] = log if verbose else None
        self._tail = ""  # incomplete last log line carried between drains
        self._id: Optional[int] = None
        if verbose:
            _set_log_mode(lib, 2)
        sid = lib.qules_session_create(
            self._n, x_start, max_evals, delta0, delta_min, delta_max,
            int(bool(verbose)), int(bool(rotation)))
        if sid <= 0:
            if verbose:
                _set_log_mode(lib, 0)
            raise QulesError(sid, "qules_session_create")
        self._id = sid

    def __enter__(self) -> "Session":
        return self

    def __exit__(self, *exc_info) -> None:
        self.close()

    def _open_id(self) -> int:
        if self._id is None:
            raise RuntimeError("session is closed")
        return self._id

    def ask(self) -> Optional[List[float]]:
        """Return the next point to evaluate as a list, or None when finished."""
        rc = self._lib.qules_session_ask(self._open_id(), self._x)
        if rc == 1:
            return list(self._x)
        if rc == 0:
            self._drain_log()
            return None
        raise QulesError(rc, "qules_session_ask")

    def tell(self, f_value: float) -> None:
        """Report the objective value for the point returned by the last `ask()`."""
        rc = self._lib.qules_session_tell(self._open_id(), float(f_value))
        self._drain_log()
        if rc != 0:
            raise QulesError(rc, "qules_session_tell")

    def finished(self) -> bool:
        """True once the session has reached its termination condition."""
        rc = self._lib.qules_session_is_finished(self._open_id())
        if rc < 0:
            raise QulesError(rc, "qules_session_is_finished")
        return rc != 0

    def best(self) -> Result:
        """Best point so far as a `Result` (`delta` is NaN until finished)."""
        x_best = (ctypes.c_double * self._n)()
        f_best = ctypes.c_double()
        evals = ctypes.c_size_t()
        delta = ctypes.c_double()
        rc = self._lib.qules_session_get_best(
            self._open_id(), x_best, ctypes.byref(f_best), ctypes.byref(evals), ctypes.byref(delta))
        if rc != 0:
            raise QulesError(rc, "qules_session_get_best")
        return Result(list(x_best), f_best.value, evals.value, delta.value)

    def close(self) -> None:
        """Free the native session. Safe to call more than once."""
        if self._id is None:
            return
        sid, self._id = self._id, None
        try:
            self._drain_log(flush=True)
        finally:
            rc = self._lib.qules_session_free(sid)
            if self._log is not None:
                _set_log_mode(self._lib, 0)
        if rc != 0:
            raise QulesError(rc, "qules_session_free")

    def _drain_log(self, flush: bool = False) -> None:
        if self._log is None:
            return
        lib = self._lib
        pending = lib.qules_log_read(None, 0)
        if pending:
            buf = ctypes.create_string_buffer(pending + 1)
            got = lib.qules_log_read(buf, pending + 1)
            self._tail += _native.decode(buf.raw[:got])
        lines = self._tail.split("\n")
        self._tail = lines.pop()  # text after the last newline is not a complete line yet
        if flush and self._tail:
            lines.append(self._tail)
            self._tail = ""
        for line in lines:
            self._log(line.rstrip("\r"))
