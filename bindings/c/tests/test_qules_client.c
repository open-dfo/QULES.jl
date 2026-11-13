/*
 * QULES C client library: self-test.
 *
 * Build (from bindings/c):
 *   gcc -std=c11 -Wall -Wextra -O2 -Iinclude src/qules_client.c tests/test_qules_client.c -o test_qules_client.exe
 * Run:
 *   test_qules_client.exe <bundle_dir>
 *
 * The bundle directory is taken from the Unicode command line and converted
 * to UTF-8, so non-ASCII paths work with any console code page.
 *
 * Exit code: number of failed checks (0 = all passed, 2 = usage error).
 */
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <shellapi.h>

#include <math.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "qules_client.h"

static int failures = 0;

static void check(int ok, const char *fmt, ...)
{
    char msg[256];
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(msg, sizeof msg, fmt, ap);
    va_end(ap);
    printf("%s %s\n", ok ? "PASS" : "FAIL", msg);
    if (!ok) failures++;
}

/* ---- Objectives --------------------------------------------------------- */

/* Passed through as user_data; counts evaluations. */
typedef struct {
    size_t calls;
} objective_state;

static double quadratic(size_t n, const double *x, void *user_data)
{
    objective_state *st = user_data;
    (void)n;
    st->calls++;
    return (x[0] - 1.0) * (x[0] - 1.0) + 10.0 * (x[1] + 2.0) * (x[1] + 2.0);
}

static double rosenbrock(size_t n, const double *x, void *user_data)
{
    objective_state *st = user_data;
    double f = 0.0;
    st->calls++;
    for (size_t i = 0; i + 1 < n; i++) {
        double a = x[i + 1] - x[i] * x[i];
        double b = 1.0 - x[i];
        f += 100.0 * a * a + b * b;
    }
    return f;
}

/* Simulates an evaluation that fails every third call. C has no exceptions,
 * so a failed evaluation is reported to the optimizer as NaN. */
static double sometimes_nan(size_t n, const double *x, void *user_data)
{
    objective_state *st = user_data;
    double f = quadratic(n, x, user_data);
    return (st->calls % 3 == 0) ? NAN : f;
}

/* ---- Log capture --------------------------------------------------------- */

typedef struct {
    char text[1 << 16];
    size_t len;
} log_buffer;

static void capture_line(const char *line, void *user_data)
{
    log_buffer *buf = user_data;
    size_t n = strlen(line);
    if (buf->len + n + 2 > sizeof buf->text) return; /* keep what fits */
    memcpy(buf->text + buf->len, line, n);
    buf->len += n;
    buf->text[buf->len++] = '\n';
    buf->text[buf->len] = '\0';
}

static log_buffer captured; /* static: 64 KiB is too big for the stack */

static void reset_capture(void)
{
    captured.len = 0;
    captured.text[0] = '\0';
}

/* ---- Tests -------------------------------------------------------------- */

static const double QUAD_X0[2] = {3.0, 1.0};
#define QUAD_MAX_EVALS 40

static qules_client_options quad_options(int rotation)
{
    qules_client_options o = qules_client_default_options();
    o.max_evals = QUAD_MAX_EVALS;
    o.rotation  = rotation;
    return o;
}

static void test_defaults(void)
{
    qules_client_options o = qules_client_default_options();
    check(o.max_evals == 300, "defaults: max_evals %zu", o.max_evals);
    check(o.delta0 == 1.0, "defaults: delta0 %g", o.delta0);
    check(o.delta_min == 1e-8, "defaults: delta_min %g", o.delta_min);
    check(o.delta_max == 100.0, "defaults: delta_max %g", o.delta_max);
    check(o.verbose == 0, "defaults: verbose %d", o.verbose);
    check(o.rotation == 1, "defaults: rotation %d", o.rotation);
    check(o.log == NULL && o.log_user_data == NULL, "defaults: no log sink");
}

static void test_strerror(void)
{
    int all_named = 1;
    for (int code = QULES_CLIENT_ESTATE; code <= QULES_CLIENT_OK; code++) {
        const char *msg = qules_client_strerror(code);
        if (msg == NULL || msg[0] == '\0' || strcmp(msg, "unknown status code") == 0)
            all_named = 0;
    }
    check(all_named, "strerror: every status code has a message");
    check(strcmp(qules_client_strerror(12345), "unknown status code") == 0,
          "strerror: unknown code");
}

static void test_before_init(void)
{
    objective_state st = {0};
    double x_best[2];
    qules_client_result res = { x_best, 0.0, 0, 0.0 };
    int rc = qules_client_optimize(quadratic, &st, 2, QUAD_X0, NULL, &res);
    check(rc == QULES_CLIENT_ENOTINIT, "before init: optimize -> %d", rc);
    int status = 0;
    qules_client_session_t *s = qules_client_session_create(2, QUAD_X0, NULL, &status);
    check(s == NULL && status == QULES_CLIENT_ENOTINIT,
          "before init: session_create -> NULL, status %d", status);
    check(qules_client_version(NULL, NULL, NULL) == QULES_CLIENT_ENOTINIT,
          "before init: version -> ENOTINIT");
    check(qules_client_init("") == QULES_CLIENT_EINVAL, "before init: empty path -> EINVAL");
    check(qules_client_init("\xff") == QULES_CLIENT_EPATH, "before init: bad UTF-8 -> EPATH");
}

static void test_init(const char *bundle_dir)
{
    int rc = qules_client_init(bundle_dir);
    check(rc == 0, "init: %s (system error %lu)", qules_client_strerror(rc),
          qules_client_system_error());
    if (rc != 0) {
        printf("%d failure(s)\n", failures);
        exit(failures);
    }
    check(qules_client_init("does-not-matter") == 0, "init: second call is a no-op");

    int major = -1, minor = -1, patch = -1;
    rc = qules_client_version(&major, &minor, &patch);
    check(rc == 0 && major >= 0 && minor >= 0 && patch >= 0,
          "version: QULES %d.%d.%d", major, minor, patch);
}

static void test_quadratic(int rotation)
{
    objective_state st = {0};
    double x_best[2];
    qules_client_result res = { x_best, 0.0, 0, 0.0 };
    qules_client_options o = quad_options(rotation);
    int rc = qules_client_optimize(quadratic, &st, 2, QUAD_X0, &o, &res);
    const char *tag = rotation ? "rotation=true" : "rotation=false";
    check(rc == 0, "quadratic %s: status %d", tag, rc);
    check(res.evals == QUAD_MAX_EVALS, "quadratic %s: evals %zu", tag, res.evals);
    check(st.calls == res.evals, "quadratic %s: callback calls %zu == evals", tag, st.calls);
    check(res.f_best < 1e-12, "quadratic %s: f_best %g", tag, res.f_best);
    check(fabs(x_best[0] - 1.0) < 1e-5, "quadratic %s: x1 %g", tag, x_best[0]);
    check(fabs(x_best[1] + 2.0) < 1e-5, "quadratic %s: x2 %g", tag, x_best[1]);
    check(isfinite(res.delta), "quadratic %s: delta %g finite", tag, res.delta);
}

static void test_rosenbrock(void)
{
    objective_state st = {0};
    const double x0[3] = {-1.2, 1.0, 0.5};
    double x_best[3];
    qules_client_result res = { x_best, 0.0, 0, 0.0 };
    qules_client_options o = qules_client_default_options();
    o.max_evals = 80;
    int rc = qules_client_optimize(rosenbrock, &st, 3, x0, &o, &res);
    check(rc == 0, "rosenbrock: status %d", rc);
    check(res.evals == 80, "rosenbrock: evals %zu", res.evals);
    check(isfinite(res.f_best), "rosenbrock: f_best %g finite", res.f_best);
}

static void test_verbose_sink(void)
{
    objective_state st = {0};
    double x_best[2];
    qules_client_result res = { x_best, 0.0, 0, 0.0 };
    qules_client_options o = quad_options(1);
    o.verbose = 1;
    o.log = capture_line;
    o.log_user_data = &captured;
    reset_capture();

    int rc = qules_client_optimize(quadratic, &st, 2, QUAD_X0, &o, &res);
    check(rc == 0, "verbose: status %d", rc);
    check(strstr(captured.text, "Termination") != NULL,
          "verbose: log (%zu bytes) contains \"Termination\"", captured.len);

    /* The log mode must be back at standard output: a second verbose run
     * without a sink must not touch the capture buffer. */
    size_t before = captured.len;
    o.log = NULL;
    o.log_user_data = NULL;
    rc = qules_client_optimize(quadratic, &st, 2, QUAD_X0, &o, &res);
    check(rc == 0 && captured.len == before, "verbose: sink restored to stdout afterwards");
}

/* Drives an ask/tell session with the same objective and settings as
 * test_quadratic. Returns the status of the first failing step, else 0. */
static int run_quadratic_session(const qules_client_options *o, objective_state *st,
                                 qules_client_result *res)
{
    int status = 0;
    qules_client_session_t *s = qules_client_session_create(2, QUAD_X0, o, &status);
    if (s == NULL) return status;

    double x[2];
    int rc;
    while ((rc = qules_client_session_ask(s, x)) == 1) {
        int t = qules_client_session_tell(s, quadratic(2, x, st));
        if (t != 0) { rc = t; break; }
    }
    if (rc == 0) {
        check(qules_client_session_is_finished(s) == 1, "session: is_finished after ask returned 0");
        rc = qules_client_session_best(s, res);
    }
    qules_client_session_free(s);
    return rc;
}

static void test_session_matches_callback(void)
{
    objective_state st_cb = {0}, st_s = {0};
    double xc[2], xs[2];
    qules_client_result rc_cb = { xc, 0.0, 0, 0.0 };
    qules_client_result rc_s  = { xs, 0.0, 0, 0.0 };
    qules_client_options o = quad_options(1);

    int status_cb = qules_client_optimize(quadratic, &st_cb, 2, QUAD_X0, &o, &rc_cb);
    int status_s = run_quadratic_session(&o, &st_s, &rc_s);

    check(status_cb == 0, "session: callback run status %d", status_cb);
    check(status_s == 0, "session: ask/tell run status %d", status_s);
    check(st_s.calls == QUAD_MAX_EVALS, "session: objective called %zu times", st_s.calls);
    check(rc_s.evals == rc_cb.evals, "session: evals %zu == %zu", rc_s.evals, rc_cb.evals);
    check(memcmp(xs, xc, sizeof xs) == 0, "session: x_best bit-identical");
    check(memcmp(&rc_s.f_best, &rc_cb.f_best, sizeof rc_s.f_best) == 0,
          "session: f_best bit-identical (%g vs %g)", rc_s.f_best, rc_cb.f_best);
    check(memcmp(&rc_s.delta, &rc_cb.delta, sizeof rc_s.delta) == 0,
          "session: delta bit-identical (%g vs %g)", rc_s.delta, rc_cb.delta);
}

static void test_session_verbose_sink(void)
{
    objective_state st = {0};
    double x_best[2];
    qules_client_result res = { x_best, 0.0, 0, 0.0 };
    qules_client_options o = quad_options(1);
    o.verbose = 1;
    o.log = capture_line;
    o.log_user_data = &captured;
    reset_capture();

    int rc = run_quadratic_session(&o, &st, &res);
    check(rc == 0, "session verbose: status %d", rc);
    check(strstr(captured.text, "Termination") != NULL,
          "session verbose: log (%zu bytes) contains \"Termination\"", captured.len);
}

static void test_session_states(void)
{
    int status = 0;
    qules_client_options o = quad_options(1);
    qules_client_session_t *s = qules_client_session_create(2, QUAD_X0, &o, &status);
    check(s != NULL && status == 0, "session states: create status %d", status);
    if (s == NULL) return;

    double x_best[2];
    qules_client_result res = { x_best, 0.0, 0, 0.0 };
    check(qules_client_session_best(s, &res) == QULES_CLIENT_ESTATE,
          "session states: best before first tell -> ESTATE");
    check(qules_client_session_tell(s, 1.0) == QULES_CLIENT_ESTATE,
          "session states: tell before ask -> ESTATE");
    check(qules_client_session_is_finished(s) == 0, "session states: not finished at start");

    double x[2];
    check(qules_client_session_ask(s, x) == 1, "session states: first ask -> 1");
    check(qules_client_session_tell(s, 1.0) == 0, "session states: tell -> 0");
    int best_rc = qules_client_session_best(s, &res);
    check(best_rc == 0 && res.evals == 1 && res.f_best == 1.0,
          "session states: best after one tell -> %d (evals %zu, f %g)",
          best_rc, res.evals, res.f_best);
    check(isnan(res.delta), "session states: delta NaN while unfinished");
    qules_client_session_free(s);
}

static void test_nan_objective(void)
{
    objective_state st = {0};
    double x_best[2];
    qules_client_result res = { x_best, 0.0, 0, 0.0 };
    qules_client_options o = quad_options(1);
    int rc = qules_client_optimize(sometimes_nan, &st, 2, QUAD_X0, &o, &res);
    check(rc == 0, "nan objective: status %d", rc);
    check(res.evals == QUAD_MAX_EVALS, "nan objective: evals %zu", res.evals);
}

static void test_bad_args(void)
{
    objective_state st = {0};
    double x_best[2];
    qules_client_result res = { x_best, 0.0, 0, 0.0 };
    check(qules_client_optimize(NULL, &st, 2, QUAD_X0, NULL, &res) == QULES_CLIENT_EINVAL,
          "bad args: NULL objective -> EINVAL");
    check(qules_client_optimize(quadratic, &st, 0, QUAD_X0, NULL, &res) == QULES_CLIENT_EINVAL,
          "bad args: n == 0 -> EINVAL");
    check(qules_client_optimize(quadratic, &st, 2, NULL, NULL, &res) == QULES_CLIENT_EINVAL,
          "bad args: NULL x0 -> EINVAL");
    check(qules_client_optimize(quadratic, &st, 2, QUAD_X0, NULL, NULL) == QULES_CLIENT_EINVAL,
          "bad args: NULL result -> EINVAL");

    /* NULL x_best is allowed: only the scalars are wanted. */
    qules_client_result scalars = { NULL, 0.0, 0, 0.0 };
    qules_client_options o = quad_options(1);
    int rc = qules_client_optimize(quadratic, &st, 2, QUAD_X0, &o, &scalars);
    check(rc == 0 && scalars.evals == QUAD_MAX_EVALS, "bad args: NULL x_best accepted (%d)", rc);

    int status = 0;
    check(qules_client_session_create(0, QUAD_X0, NULL, &status) == NULL
              && status == QULES_CLIENT_EINVAL,
          "bad args: session n == 0 -> EINVAL");
    check(qules_client_session_ask(NULL, x_best) == QULES_CLIENT_EINVAL,
          "bad args: ask on NULL session -> EINVAL");
    qules_client_session_free(NULL);
    check(1, "bad args: free(NULL) is a no-op");
}

static void test_shutdown(void)
{
    qules_client_shutdown();
    qules_client_shutdown(); /* second call must be harmless */
    objective_state st = {0};
    double x_best[2];
    qules_client_result res = { x_best, 0.0, 0, 0.0 };
    check(qules_client_optimize(quadratic, &st, 2, QUAD_X0, NULL, &res) == QULES_CLIENT_ESHUTDOWN,
          "shutdown: optimize afterwards -> ESHUTDOWN");
    check(qules_client_init("x") == QULES_CLIENT_ESHUTDOWN, "shutdown: init afterwards -> ESHUTDOWN");
}

/* ---- Setup -------------------------------------------------------------- */

/* Bundle directory from the Unicode command line as a malloc'd UTF-8 string;
 * NULL when the argument is missing. */
static char *bundle_dir_from_command_line(void)
{
    int wargc = 0;
    wchar_t **wargv = CommandLineToArgvW(GetCommandLineW(), &wargc);
    if (wargv == NULL) return NULL;
    char *utf8 = NULL;
    if (wargc >= 2) {
        int len = WideCharToMultiByte(CP_UTF8, 0, wargv[1], -1, NULL, 0, NULL, NULL);
        if (len > 0 && (utf8 = malloc((size_t)len)) != NULL)
            WideCharToMultiByte(CP_UTF8, 0, wargv[1], -1, utf8, len, NULL, NULL);
    }
    LocalFree(wargv);
    return utf8;
}

int main(void)
{
    char *bundle_dir = bundle_dir_from_command_line();
    if (bundle_dir == NULL) {
        fputs("usage: test_qules_client.exe <bundle_dir>\n", stderr);
        return 2;
    }

    test_defaults();
    test_strerror();
    test_before_init();
    test_init(bundle_dir);
    free(bundle_dir);

    test_quadratic(1);
    test_quadratic(0);
    test_rosenbrock();
    test_verbose_sink();
    test_session_matches_callback();
    test_session_verbose_sink();
    test_session_states();
    test_nan_objective();
    test_bad_args();
    test_shutdown();

    printf("%d failure(s)\n", failures);
    return failures;
}
