#ifndef QULES_H
#define QULES_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Supplied by the bundle's include directory. Call init_julia(argc, argv) once
 * before any QULES function and shutdown_julia(retcode) once when the hosting
 * process is exiting. The bundle's bin directory must be loadable (on PATH or
 * added with AddDllDirectory / os.add_dll_directory). */
#include "julia_init.h"

int qules_version_major(void);
int qules_version_minor(void);
int qules_version_patch(void);

/* ---- Verbose output -----------------------------------------------------
 * With verbose != 0 the optimizer prints an iteration table. Where it goes is
 * process-wide and selected once:
 *   mode 0 (default): the process's standard output.
 *   mode 1: `callback(line, user_data)` for each completed line.
 *   mode 2: an internal buffer drained with qules_log_read.
 * Returns 0, or -1 for an invalid mode / NULL callback in mode 1. */
typedef void (*qules_log_callback)(const char *line, void *user_data);
int qules_set_log_mode(int mode, qules_log_callback callback, void *user_data);

/* Copies up to capacity-1 buffered bytes into buffer, NUL-terminates it, and
 * returns the number of bytes copied; the rest stays buffered. With a NULL
 * buffer or zero capacity it returns the number of pending bytes. */
size_t qules_log_read(char *buffer, size_t capacity);

/* ---- One-shot optimization with a callback ------------------------------
 * The callback is synchronous. x has n elements and is valid only during the
 * callback; user_data is passed through unchanged. Do not throw across the ABI.
 * qules_optimize_c accepts this function's address as void *. */
typedef double (*qules_objective_callback)(size_t n, const double *x, void *user_data);

/* x_start points to n_dim doubles. Non-null x_best_out must hold n_dim doubles;
 * scalar output pointers may be NULL. Returns 0 on success, -1 for an invalid
 * callback/start pointer or dimension, -2 for an error inside the optimizer.
 * verbose and rotation use zero for false and nonzero for true. */
int qules_optimize_c(
    void *f_callback,
    size_t n_dim,
    const double *x_start,
    size_t max_evals,
    double delta0,
    double delta_min,
    double delta_max,
    int verbose,
    int rotation,
    double *x_best_out,
    double *f_best_out,
    size_t *evals_out,
    double *delta_out,
    void *user_data
);

/* ---- Ask/tell sessions ---------------------------------------------------
 * Same algorithm as qules_optimize_c, driven by the host:
 *
 *   id = qules_session_create(...);
 *   while (qules_session_ask(id, x) == 1) qules_session_tell(id, f(x));
 *   qules_session_get_best(id, x_best, &f_best, &evals, &delta);
 *   qules_session_free(id);
 *
 * create returns a positive id, -1 for invalid arguments, -2 on error.
 * ask writes the next point and returns 1; 0 once finished; -2 on error.
 * tell returns 0; 1 if no point is awaiting a value; -1 unknown id; -2 error.
 * get_best returns 0; -1 for an unknown id or before the first tell. delta_out
 * is NaN until the session has finished. free returns 0, -1 for unknown id. */
int64_t qules_session_create(
    size_t n_dim,
    const double *x_start,
    size_t max_evals,
    double delta0,
    double delta_min,
    double delta_max,
    int verbose,
    int rotation
);
int qules_session_ask(int64_t session_id, double *x_out);
int qules_session_tell(int64_t session_id, double f_value);
int qules_session_is_finished(int64_t session_id);
int qules_session_get_best(
    int64_t session_id,
    double *x_best_out,
    double *f_best_out,
    size_t *evals_out,
    double *delta_out
);
int qules_session_free(int64_t session_id);

#ifdef __cplusplus
}
#endif

#endif /* QULES_H */
