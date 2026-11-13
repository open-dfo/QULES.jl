/*
 * QULES C client library.
 *
 * Loads the QULES bundle (qules.dll and its embedded Julia runtime) at run
 * time; no import library is needed. Windows only. See README.md for usage.
 *
 * Not thread-safe: call every function from the thread that called
 * qules_client_init, and run one optimization at a time.
 */
#ifndef QULES_CLIENT_H
#define QULES_CLIENT_H

#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

/* ---- Status codes ---------------------------------------------------------
 * Every function that returns `int` returns QULES_CLIENT_OK (0) on success or
 * one of the negative codes below, except qules_client_session_ask and
 * qules_client_session_is_finished, which also return 1 (see their comments).
 * qules_client_strerror turns a code into a short English message. */
enum {
    QULES_CLIENT_OK          =  0,
    QULES_CLIENT_EINVAL      = -1, /* NULL pointer, n == 0, or rejected option */
    QULES_CLIENT_EOPTIMIZER  = -2, /* error raised inside the optimizer       */
    QULES_CLIENT_ENOTINIT    = -3, /* qules_client_init has not succeeded yet */
    QULES_CLIENT_ESHUTDOWN   = -4, /* qules_client_shutdown was already called*/
    QULES_CLIENT_EPATH       = -5, /* bundle path is not valid UTF-8          */
    QULES_CLIENT_EDLLDIR     = -6, /* SetDllDirectoryW(<bundle>\bin) failed   */
    QULES_CLIENT_ELOAD       = -7, /* LoadLibraryW(qules.dll) failed          */
    QULES_CLIENT_ESYMBOL     = -8, /* qules.dll lacks a required export       */
    QULES_CLIENT_ENOMEM      = -9, /* allocation failed                       */
    QULES_CLIENT_ESTATE      = -10 /* session not in the required state       */
};

/* Short, static, English description of a status code. Never NULL. */
const char *qules_client_strerror(int code);

/* Win32 error code (GetLastError) recorded by the most recent failing call to
 * qules_client_init, or 0. Meaningful after QULES_CLIENT_EPATH,
 * QULES_CLIENT_EDLLDIR and QULES_CLIENT_ELOAD. */
unsigned long qules_client_system_error(void);

/* ---- Lifetime ------------------------------------------------------------- */

/* Loads <bundle_dir>\bin\qules.dll and starts the embedded Julia runtime.
 *
 * bundle_dir_utf8 is the UTF-8 path of the unpacked bundle (the directory that
 * contains bin\, include\ and share\). Forward or backward slashes and a
 * trailing separator are accepted.
 *
 * Returns 0 on success. The call is idempotent: once it has succeeded, further
 * calls return 0 immediately and ignore their argument (the Julia runtime can
 * be started only once per process). A failed call leaves the library
 * uninitialised and may be retried, e.g. with a different path.
 *
 * Side effect: the process's DLL search path is extended with <bundle>\bin via
 * SetDllDirectoryW and stays that way, because Julia loads further libraries
 * from that directory by name while the program runs. */
int qules_client_init(const char *bundle_dir_utf8);

/* Stops the embedded Julia runtime. OPTIONAL and only for the very end of the
 * process: Julia cannot be restarted, so after this call every other function
 * (including qules_client_init) fails with QULES_CLIENT_ESHUTDOWN. It is safe
 * to skip this entirely and simply let the process exit. Calling it more than
 * once, or before qules_client_init, is a harmless no-op. */
void qules_client_shutdown(void);

/* Version of the loaded qules.dll. Output pointers may be NULL.
 * Returns 0, or QULES_CLIENT_ENOTINIT / QULES_CLIENT_ESHUTDOWN. */
int qules_client_version(int *major, int *minor, int *patch);

/* ---- Options and results -------------------------------------------------- */

/* Receives one completed line of the verbose iteration table, without a
 * trailing newline. user_data is passed through unchanged. */
typedef void (*qules_client_log_fn)(const char *line, void *user_data);

typedef struct {
    size_t max_evals;   /* evaluation budget (default 300)                   */
    double delta0;      /* initial trust-region radius (default 1.0)         */
    double delta_min;   /* stop at this radius (default 1e-8)                */
    double delta_max;   /* largest trust-region radius (default 100.0)       */
    int    verbose;     /* nonzero: print the iteration table (default 0)    */
    int    rotation;    /* nonzero: learn the envelope orientation (default 1)*/

    /* Where verbose output goes. NULL (default): the process's standard
     * output. Otherwise every line is delivered to `log(line, log_user_data)`
     * instead. Ignored when verbose == 0. The callback must not call back
     * into this library. */
    qules_client_log_fn log;
    void              *log_user_data;
} qules_client_options;

/* The defaults listed above. Copy, adjust the fields you need, pass the
 * address to qules_client_optimize / qules_client_session_create. */
qules_client_options qules_client_default_options(void);

typedef struct {
    /* Supplied by the caller: storage for n doubles that receives the best
     * point found, or NULL if the point is not needed. */
    double *x_best;
    /* Filled in by the library. */
    double f_best;      /* objective value at x_best                        */
    size_t evals;       /* objective evaluations performed                  */
    double delta;       /* final trust-region radius (NaN while unfinished) */
} qules_client_result;

/* ---- One-shot optimization --------------------------------------------------
 * The objective is called synchronously with x pointing at n doubles that are
 * valid only for the duration of the call. user_data is passed through
 * unchanged. Return NaN (or infinity) for a failed evaluation; the optimizer
 * treats such points as unusable and carries on. The function must not
 * longjmp or raise a structured exception across the call. */
typedef double (*qules_client_objective_fn)(size_t n, const double *x, void *user_data);

/* Minimises f starting from x0 (n doubles). opts may be NULL for the defaults.
 * out->x_best must be set by the caller (see qules_client_result); the other
 * fields are written on success. Returns 0, QULES_CLIENT_EINVAL,
 * QULES_CLIENT_EOPTIMIZER, QULES_CLIENT_ENOTINIT or QULES_CLIENT_ESHUTDOWN. */
int qules_client_optimize(qules_client_objective_fn f,
                          void *user_data,
                          size_t n,
                          const double *x0,
                          const qules_client_options *opts,
                          qules_client_result *out);

/* ---- Ask/tell sessions -------------------------------------------------------
 * The same algorithm, driven by the caller: the session hands out points and
 * the caller reports their objective values whenever it likes (useful when
 * evaluations happen elsewhere or cannot be wrapped in a C callback).
 *
 *   qules_client_session_t *s = qules_client_session_create(n, x0, NULL, &rc);
 *   double x[n];
 *   while (qules_client_session_ask(s, x) == 1)
 *       qules_client_session_tell(s, f(x));
 *   qules_client_session_best(s, &result);
 *   qules_client_session_free(s);
 *
 * Driving a session to completion yields results identical to
 * qules_client_optimize with the same inputs. */
typedef struct qules_client_session qules_client_session_t;

/* Creates a session for an n-dimensional problem starting at x0. opts may be
 * NULL for the defaults. Returns the handle, or NULL on failure; if status is
 * not NULL it receives the status code in either case. */
qules_client_session_t *qules_client_session_create(size_t n,
                                                    const double *x0,
                                                    const qules_client_options *opts,
                                                    int *status);

/* Writes the next point to evaluate into x_out (n doubles) and returns 1.
 * Returns 0 once the session has finished (x_out untouched), or a negative
 * status code. Asking twice without telling repeats the pending point. */
int qules_client_session_ask(qules_client_session_t *s, double *x_out);

/* Reports the objective value of the point returned by the last ask. Returns
 * 0, QULES_CLIENT_ESTATE if no point is awaiting a value, or another
 * negative status code. */
int qules_client_session_tell(qules_client_session_t *s, double f_value);

/* Returns 1 if the session has finished, 0 if it still has points to offer,
 * or a negative status code. */
int qules_client_session_is_finished(qules_client_session_t *s);

/* Best point seen so far. out->x_best must be set by the caller (see
 * qules_client_result). Returns 0, QULES_CLIENT_ESTATE before the first
 * successful tell, or another negative status code. out->delta is NaN until
 * the session has finished. */
int qules_client_session_best(qules_client_session_t *s, qules_client_result *out);

/* Releases the session. NULL is ignored. */
void qules_client_session_free(qules_client_session_t *s);

#ifdef __cplusplus
}
#endif

#endif /* QULES_CLIENT_H */
