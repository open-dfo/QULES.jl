# QULES for C

C client library for the QULES native bundle. Windows x64.

## Usage

Compile `src/qules_client.c` with your program:

```sh
gcc -O2 -Ibindings/c/include bindings/c/src/qules_client.c main.c -o main.exe
```

```c
#include "qules_client.h"

static double f(size_t n, const double *x, void *user_data) {
    return (x[0] - 1) * (x[0] - 1) + 10 * (x[1] + 2) * (x[1] + 2);
}

int main(void) {
    qules_client_init("C:\\path\\to\\libqules");

    qules_client_options opts = qules_client_default_options();
    opts.max_evals = 150;

    double x0[2] = {3.0, 1.0}, x_best[2];
    qules_client_result r = { x_best };
    int rc = qules_client_optimize(f, NULL, 2, x0, &opts, &r);
    if (rc != 0) puts(qules_client_strerror(rc));
}
```

Options: `max_evals` (300), `delta0` (1.0), `delta_min` (1e-8), `delta_max`
(100.0), `verbose` (0), `rotation` (1). The ask/tell interface is declared in
`include/qules_client.h`.

## Test

```sh
cd bindings/c
gcc -O2 -Iinclude src/qules_client.c tests/test_qules_client.c -o test.exe
test.exe C:\path\to\libqules
```
