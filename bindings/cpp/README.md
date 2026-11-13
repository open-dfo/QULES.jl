# QULES for C++

Header-only C++17 binding for the QULES native bundle. Windows x64.

## Usage

```sh
g++ -std=c++17 -O2 -Ibindings/cpp/include main.cpp -o main.exe -lshell32
```

```cpp
#include <qules/qules.hpp>

int main() {
    qules::Runtime rt("C:\\path\\to\\libqules");

    qules::Options opts;
    opts.max_evals = 150;

    auto f = [](const std::vector<double>& x) {
        return (x[0] - 1) * (x[0] - 1) + 10 * (x[1] + 2) * (x[1] + 2);
    };
    qules::Result r = qules::optimize(f, {3.0, 1.0}, opts);
}
```

Options: `max_evals` (300), `delta0` (1.0), `delta_min` (1e-8), `delta_max`
(100.0), `verbose` (false), `rotation` (true).

Ask/tell interface:

```cpp
qules::Session s({3.0, 1.0}, opts);
std::vector<double> x;
while (s.ask(x)) s.tell(f(x));
qules::Result r = s.best();
```

## Test

```sh
cd bindings/cpp
g++ -std=c++17 -O2 -Iinclude tests/test_qules.cpp -o test.exe -lshell32
test.exe C:\path\to\libqules
```
