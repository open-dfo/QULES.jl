/* Runtime start-up for the QULES Windows library bundle.
 *
 * Replaces PackageCompiler's default julia_init.c, which passes the bundle path
 * through the ANSI C runtime (_fullpath, getenv, _putenv_s). Julia itself works
 * in UTF-8, so a bundle under a non-ASCII directory (e.g. "Masaüstü") broke
 * unless the host process ran with a UTF-8 code page. This file keeps every
 * path in UTF-16 while talking to Windows and in UTF-8 while talking to Julia.
 */
#include <stdlib.h>
#include <string.h>
#include <wchar.h>
#include <winsock2.h>
#include <windows.h>

#include "julia.h"
#include "julia_init.h"
#include "uv.h"

#define DLLEXPORT __declspec(dllexport)

static wchar_t *utf8_to_wide(const char *utf8) {
    int count = MultiByteToWideChar(CP_UTF8, 0, utf8, -1, NULL, 0);
    wchar_t *wide = (wchar_t *)malloc(sizeof(wchar_t) * (size_t)count);
    MultiByteToWideChar(CP_UTF8, 0, utf8, -1, wide, count);
    return wide;
}

static char *wide_to_utf8(const wchar_t *wide) {
    int count = WideCharToMultiByte(CP_UTF8, 0, wide, -1, NULL, 0, NULL, NULL);
    char *utf8 = (char *)malloc((size_t)count);
    WideCharToMultiByte(CP_UTF8, 0, wide, -1, utf8, count, NULL, NULL);
    return utf8;
}

/* Prepend "<root>\share\julia" to a ;-separated environment list. */
static void prepend_share_dir(const wchar_t *name, const wchar_t *root) {
    const wchar_t *current = _wgetenv(name);
    size_t length = wcslen(root) + wcslen(L"\\share\\julia") + 1;
    if (current != NULL && current[0] != L'\0') {
        length += wcslen(current) + 1;
    }
    wchar_t *value = (wchar_t *)malloc(sizeof(wchar_t) * length);
    value[0] = L'\0';
    if (current != NULL && current[0] != L'\0') {
        wcscat(value, current);
        wcscat(value, L";");
    }
    wcscat(value, root);
    wcscat(value, L"\\share\\julia");
    _wputenv_s(name, value);
    free(value);
}

/* Truncate at the last path separator; returns 0 if there is none. */
static int strip_last_component(wchar_t *path) {
    wchar_t *separator = NULL;
    for (wchar_t *p = path; *p != L'\0'; p++) {
        if (*p == L'\\' || *p == L'/') {
            separator = p;
        }
    }
    if (separator == NULL) {
        return 0;
    }
    *separator = L'\0';
    return 1;
}

DLLEXPORT void init_julia(int argc, char **argv) {
    uv_setup_args(argc, argv);
    jl_parse_opts(&argc, &argv);

    void *handle = jl_load_dynamic_library(JULIAC_PROGRAM_LIBNAME, JL_RTLD_DEFAULT, 0);
    if (handle == NULL) {
        jl_errorf("qules: failed to load %s", JULIAC_PROGRAM_LIBNAME);
    }
    const char *library_path = jl_pathname_for_handle(handle); /* UTF-8 */
    if (library_path == NULL) {
        jl_errorf("qules: failed to locate %s", JULIAC_PROGRAM_LIBNAME);
    }

    wchar_t *wide_library = utf8_to_wide(library_path);
    wchar_t *wide_image = _wfullpath(NULL, wide_library, 0);
    free(wide_library);
    if (wide_image == NULL) {
        jl_errorf("qules: failed to resolve the path of %s", JULIAC_PROGRAM_LIBNAME);
    }

    /* <root>\bin\qules.dll -> <root> */
    wchar_t *wide_root = _wcsdup(wide_image);
    if (!strip_last_component(wide_root) || !strip_last_component(wide_root)) {
        jl_errorf("qules: unexpected bundle layout for %s", JULIAC_PROGRAM_LIBNAME);
    }
    prepend_share_dir(L"JULIA_DEPOT_PATH", wide_root);
    prepend_share_dir(L"JULIA_LOAD_PATH", wide_root);

    char *image = wide_to_utf8(wide_image);
    char *root = wide_to_utf8(wide_root);
    size_t bindir_length = strlen(root) + strlen("\\bin") + 1;
    char *bindir = (char *)malloc(bindir_length);
    strcpy(bindir, root);
    strcat(bindir, "\\bin");

    jl_init_with_image_file(bindir, image);

    free(bindir);
    free(root);
    free(image);
    free(wide_root);
    free(wide_image);
}

DLLEXPORT void shutdown_julia(int retcode) { jl_atexit_hook(retcode); }
