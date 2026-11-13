/*
 * QULES C client library: implementation.
 *
 * qules.dll is loaded with LoadLibraryW after SetDllDirectoryW has pointed the
 * loader at <bundle>\bin, and every entry point is resolved with
 * GetProcAddress. Linking against an import library would not work: the
 * loader would then resolve qules.dll and its Julia dependencies at process
 * start, before any code could add the directory.
 *
 * The function prototypes in the ABI section mirror <bundle>/include/qules.h
 * and julia_init.h; nothing from the bundle's include directory is needed to
 * build this file.
 */
#ifndef _WIN32
#error "qules_client.c targets Windows, like the QULES bundle it loads."
#endif

#define WIN32_LEAN_AND_MEAN
#include <windows.h>

#include <math.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#include "qules_client.h"

/* ---- qules.dll ABI ------------------------------------------------------- */

typedef void    (*init_julia_fn)(int argc, char **argv);
typedef void    (*shutdown_julia_fn)(int retcode);
typedef int     (*version_fn)(void);
typedef int     (*set_log_mode_fn)(int mode, qules_client_log_fn callback, void *user_data);
typedef int     (*optimize_c_fn)(void *f_callback, size_t n_dim, const double *x_start,
                                 size_t max_evals, double delta0, double delta_min,
                                 double delta_max, int verbose, int rotation,
                                 double *x_best_out, double *f_best_out,
                                 size_t *evals_out, double *delta_out, void *user_data);
typedef int64_t (*session_create_fn)(size_t n_dim, const double *x_start,
                                     size_t max_evals, double delta0, double delta_min,
                                     double delta_max, int verbose, int rotation);
typedef int     (*session_ask_fn)(int64_t session_id, double *x_out);
typedef int     (*session_tell_fn)(int64_t session_id, double f_value);
typedef int     (*session_is_finished_fn)(int64_t session_id);
typedef int     (*session_get_best_fn)(int64_t session_id, double *x_best_out,
                                       double *f_best_out, size_t *evals_out,
                                       double *delta_out);
typedef int     (*session_free_fn)(int64_t session_id);

/* Entry points resolved by qules_client_init. */
static struct {
    HMODULE                dll;
    init_julia_fn          init_julia;
    shutdown_julia_fn      shutdown_julia;
    version_fn             version_major, version_minor, version_patch;
    set_log_mode_fn        set_log_mode;
    optimize_c_fn          optimize_c;
    session_create_fn      session_create;
    session_ask_fn         session_ask;
    session_tell_fn        session_tell;
    session_is_finished_fn session_is_finished;
    session_get_best_fn    session_get_best;
    session_free_fn        session_free;
} q;

enum { STATE_UNLOADED, STATE_READY, STATE_SHUTDOWN };
static int   g_state = STATE_UNLOADED;
static DWORD g_system_error;

/* ---- Diagnostics --------------------------------------------------------- */

const char *qules_client_strerror(int code)
{
    switch (code) {
    case QULES_CLIENT_OK:         return "success";
    case QULES_CLIENT_EINVAL:     return "invalid argument";
    case QULES_CLIENT_EOPTIMIZER: return "error inside the optimizer";
    case QULES_CLIENT_ENOTINIT:   return "qules_client_init has not succeeded";
    case QULES_CLIENT_ESHUTDOWN:  return "qules_client_shutdown has already been called";
    case QULES_CLIENT_EPATH:      return "bundle path is not valid UTF-8";
    case QULES_CLIENT_EDLLDIR:    return "SetDllDirectoryW on <bundle>\\bin failed";
    case QULES_CLIENT_ELOAD:      return "LoadLibraryW(qules.dll) failed";
    case QULES_CLIENT_ESYMBOL:    return "qules.dll does not export a required function";
    case QULES_CLIENT_ENOMEM:     return "out of memory";
    case QULES_CLIENT_ESTATE:     return "session is not in the required state";
    default:                      return "unknown status code";
    }
}

unsigned long qules_client_system_error(void)
{
    return g_system_error;
}

/* Status to return from any entry point when the runtime is unavailable. */
static int not_ready(void)
{
    return g_state == STATE_SHUTDOWN ? QULES_CLIENT_ESHUTDOWN : QULES_CLIENT_ENOTINIT;
}

/* Maps the -1 / -2 convention of qules_optimize_c and qules_session_create. */
static int map_abi_status(int abi_status)
{
    if (abi_status == 0) return QULES_CLIENT_OK;
    if (abi_status == -1) return QULES_CLIENT_EINVAL;
    return QULES_CLIENT_EOPTIMIZER;
}

/* ---- Loading ------------------------------------------------------------- */

static int resolve_entry_points(void)
{
    /* GetProcAddress returns FARPROC; copying the bytes converts it to the
     * specific function pointer type without a pedantic cast. */
#define RESOLVE(field, name)                                                   \
    do {                                                                       \
        FARPROC p = GetProcAddress(q.dll, name);                               \
        if (p == NULL) return QULES_CLIENT_ESYMBOL;                            \
        memcpy(&q.field, &p, sizeof p);                                        \
    } while (0)

    RESOLVE(init_julia,          "init_julia");
    RESOLVE(shutdown_julia,      "shutdown_julia");
    RESOLVE(version_major,       "qules_version_major");
    RESOLVE(version_minor,       "qules_version_minor");
    RESOLVE(version_patch,       "qules_version_patch");
    RESOLVE(set_log_mode,        "qules_set_log_mode");
    RESOLVE(optimize_c,          "qules_optimize_c");
    RESOLVE(session_create,      "qules_session_create");
    RESOLVE(session_ask,         "qules_session_ask");
    RESOLVE(session_tell,        "qules_session_tell");
    RESOLVE(session_is_finished, "qules_session_is_finished");
    RESOLVE(session_get_best,    "qules_session_get_best");
    RESOLVE(session_free,        "qules_session_free");
#undef RESOLVE
    return QULES_CLIENT_OK;
}

/* Converts the UTF-8 bundle path to UTF-16 and appends "\bin", dropping any
 * trailing separators first. The result is malloc'd; NULL with *status set on
 * failure. */
static wchar_t *bin_directory(const char *bundle_dir_utf8, int *status)
{
    int wlen = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS,
                                   bundle_dir_utf8, -1, NULL, 0);
    if (wlen <= 0) {
        g_system_error = GetLastError();
        *status = QULES_CLIENT_EPATH;
        return NULL;
    }

    /* wlen counts the terminating NUL; "\bin" needs four more characters. */
    wchar_t *bin = malloc(((size_t)wlen + 4) * sizeof *bin);
    if (bin == NULL) {
        *status = QULES_CLIENT_ENOMEM;
        return NULL;
    }
    MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, bundle_dir_utf8, -1, bin, wlen);

    size_t len = wcslen(bin);
    while (len > 0 && (bin[len - 1] == L'\\' || bin[len - 1] == L'/')) len--;
    memcpy(bin + len, L"\\bin", 5 * sizeof(wchar_t)); /* includes the NUL */
    return bin;
}

int qules_client_init(const char *bundle_dir_utf8)
{
    if (g_state == STATE_READY) return QULES_CLIENT_OK;
    if (g_state == STATE_SHUTDOWN) return QULES_CLIENT_ESHUTDOWN;
    if (bundle_dir_utf8 == NULL || bundle_dir_utf8[0] == '\0') return QULES_CLIENT_EINVAL;

    int status = QULES_CLIENT_OK;
    wchar_t *bin = bin_directory(bundle_dir_utf8, &status);
    if (bin == NULL) return status;

    /* Julia loads its own libraries from this directory by name during the
     * whole run, so the search path is deliberately left extended. */
    BOOL ok = SetDllDirectoryW(bin);
    free(bin);
    if (!ok) {
        g_system_error = GetLastError();
        return QULES_CLIENT_EDLLDIR;
    }

    q.dll = LoadLibraryW(L"qules.dll");
    if (q.dll == NULL) {
        g_system_error = GetLastError();
        return QULES_CLIENT_ELOAD;
    }

    status = resolve_entry_points();
    if (status != QULES_CLIENT_OK) {
        FreeLibrary(q.dll);
        memset(&q, 0, sizeof q);
        return status;
    }

    /* Julia keeps a reference to argv, so it must outlive the call. */
    static char  program_name[] = "qules";
    static char *argv[] = { program_name, NULL };
    q.init_julia(1, argv);

    g_system_error = 0;
    g_state = STATE_READY;
    return QULES_CLIENT_OK;
}

void qules_client_shutdown(void)
{
    if (g_state != STATE_READY) return;
    g_state = STATE_SHUTDOWN;
    q.shutdown_julia(0);
}

int qules_client_version(int *major, int *minor, int *patch)
{
    if (g_state != STATE_READY) return not_ready();
    if (major) *major = q.version_major();
    if (minor) *minor = q.version_minor();
    if (patch) *patch = q.version_patch();
    return QULES_CLIENT_OK;
}

/* ---- Options and verbose output ------------------------------------------ */

qules_client_options qules_client_default_options(void)
{
    qules_client_options o;
    o.max_evals     = 300;
    o.delta0        = 1.0;
    o.delta_min     = 1e-8;
    o.delta_max     = 100.0;
    o.verbose       = 0;
    o.rotation      = 1;
    o.log           = NULL;
    o.log_user_data = NULL;
    return o;
}

/* Where verbose lines go for one optimizer call. log == NULL means the
 * process's standard output, which is the bundle's default log mode (0) and
 * therefore needs no switching. */
typedef struct {
    qules_client_log_fn log;
    void               *user_data;
} log_sink;

static log_sink sink_from_options(const qules_client_options *o)
{
    log_sink s = { NULL, NULL };
    if (o->verbose && o->log != NULL) {
        s.log       = o->log;
        s.user_data = o->log_user_data;
    }
    return s;
}

/* The log mode is process-wide, so it is switched to the sink right before
 * each optimizer call and back to standard output right after. Sessions that
 * interleave with different sinks therefore do not disturb each other. */
static int log_begin(const log_sink *s)
{
    if (s->log == NULL) return QULES_CLIENT_OK;
    return q.set_log_mode(1, s->log, s->user_data) == 0 ? QULES_CLIENT_OK
                                                        : QULES_CLIENT_EOPTIMIZER;
}

static void log_end(const log_sink *s)
{
    if (s->log != NULL) q.set_log_mode(0, NULL, NULL);
}

static void clear_result(qules_client_result *out)
{
    out->f_best = NAN;
    out->evals  = 0;
    out->delta  = NAN;
}

/* ---- One-shot optimization ----------------------------------------------- */

int qules_client_optimize(qules_client_objective_fn f,
                          void *user_data,
                          size_t n,
                          const double *x0,
                          const qules_client_options *opts,
                          qules_client_result *out)
{
    if (g_state != STATE_READY) return not_ready();
    if (f == NULL || n == 0 || x0 == NULL || out == NULL) return QULES_CLIENT_EINVAL;

    qules_client_options o = opts ? *opts : qules_client_default_options();
    log_sink sink = sink_from_options(&o);
    clear_result(out);

    /* qules_optimize_c takes the objective's address as void *; copying the
     * bytes avoids a function-to-object pointer cast. */
    void *f_address;
    memcpy(&f_address, &f, sizeof f_address);

    int rc = log_begin(&sink);
    if (rc != QULES_CLIENT_OK) return rc;
    int status = q.optimize_c(f_address, n, x0, o.max_evals, o.delta0, o.delta_min,
                              o.delta_max, o.verbose, o.rotation, out->x_best,
                              &out->f_best, &out->evals, &out->delta, user_data);
    log_end(&sink);
    return map_abi_status(status);
}

/* ---- Ask/tell sessions --------------------------------------------------- */

struct qules_client_session {
    int64_t  id;
    log_sink sink;
};

qules_client_session_t *qules_client_session_create(size_t n,
                                                    const double *x0,
                                                    const qules_client_options *opts,
                                                    int *status)
{
    int dummy;
    if (status == NULL) status = &dummy;

    if (g_state != STATE_READY) { *status = not_ready(); return NULL; }
    if (n == 0 || x0 == NULL) { *status = QULES_CLIENT_EINVAL; return NULL; }

    qules_client_session_t *s = malloc(sizeof *s);
    if (s == NULL) { *status = QULES_CLIENT_ENOMEM; return NULL; }

    qules_client_options o = opts ? *opts : qules_client_default_options();
    s->sink = sink_from_options(&o);

    *status = log_begin(&s->sink);
    if (*status != QULES_CLIENT_OK) { free(s); return NULL; }
    int64_t id = q.session_create(n, x0, o.max_evals, o.delta0, o.delta_min,
                                  o.delta_max, o.verbose, o.rotation);
    log_end(&s->sink);

    if (id <= 0) {
        *status = map_abi_status((int)id);
        free(s);
        return NULL;
    }
    s->id = id;
    *status = QULES_CLIENT_OK;
    return s;
}

/* Maps the session ABI's -1 (unknown id / wrong state) and -2 (error). */
static int map_session_status(int abi_status)
{
    return abi_status == -1 ? QULES_CLIENT_ESTATE : QULES_CLIENT_EOPTIMIZER;
}

int qules_client_session_ask(qules_client_session_t *s, double *x_out)
{
    if (g_state != STATE_READY) return not_ready();
    if (s == NULL || x_out == NULL) return QULES_CLIENT_EINVAL;

    int rc = log_begin(&s->sink);
    if (rc != QULES_CLIENT_OK) return rc;
    rc = q.session_ask(s->id, x_out);
    log_end(&s->sink);

    return (rc == 1 || rc == 0) ? rc : map_session_status(rc);
}

int qules_client_session_tell(qules_client_session_t *s, double f_value)
{
    if (g_state != STATE_READY) return not_ready();
    if (s == NULL) return QULES_CLIENT_EINVAL;

    int rc = log_begin(&s->sink);
    if (rc != QULES_CLIENT_OK) return rc;
    rc = q.session_tell(s->id, f_value);
    log_end(&s->sink);

    if (rc == 0) return QULES_CLIENT_OK;
    if (rc == 1) return QULES_CLIENT_ESTATE; /* no point awaiting a value */
    return map_session_status(rc);
}

int qules_client_session_is_finished(qules_client_session_t *s)
{
    if (g_state != STATE_READY) return not_ready();
    if (s == NULL) return QULES_CLIENT_EINVAL;

    int rc = q.session_is_finished(s->id);
    return (rc == 1 || rc == 0) ? rc : map_session_status(rc);
}

int qules_client_session_best(qules_client_session_t *s, qules_client_result *out)
{
    if (g_state != STATE_READY) return not_ready();
    if (s == NULL || out == NULL) return QULES_CLIENT_EINVAL;
    clear_result(out);

    int rc = log_begin(&s->sink);
    if (rc != QULES_CLIENT_OK) return rc;
    rc = q.session_get_best(s->id, out->x_best, &out->f_best, &out->evals, &out->delta);
    log_end(&s->sink);

    return rc == 0 ? QULES_CLIENT_OK : map_session_status(rc);
}

void qules_client_session_free(qules_client_session_t *s)
{
    if (s == NULL) return;
    if (g_state == STATE_READY) q.session_free(s->id);
    free(s);
}
