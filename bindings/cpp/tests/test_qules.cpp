// test_qules.cpp -- contract test for the QULES C++ binding.
//
// Build (from bindings/cpp):
//   g++ -std=c++17 -Wall -Wextra -O2 -Iinclude tests/test_qules.cpp -o test_qules.exe -lshell32
// Run:   test_qules.exe <bundle_dir>      (exit code = number of failed checks)
#include <qules/qules.hpp>

#include <shellapi.h>

#include <cmath>
#include <cstdio>
#include <cstring>
#include <string>
#include <vector>

namespace {

int failures = 0;

void report(bool ok, const std::string& name) {
    std::printf("%s %s\n", ok ? "PASS" : "FAIL", name.c_str());
    if (!ok) ++failures;
}

// Runs one check; an unexpected exception counts as a failure instead of aborting.
template <class Test>
void run(const std::string& name, Test test) {
    try {
        report(test(), name);
    } catch (const std::exception& e) {
        report(false, name + " (" + e.what() + ")");
    }
}

double quadratic(const std::vector<double>& x) {
    return (x[0] - 1.0) * (x[0] - 1.0) + 10.0 * (x[1] + 2.0) * (x[1] + 2.0);
}

double rosenbrock(const std::vector<double>& x) {
    double sum = 0.0;
    for (std::size_t i = 0; i + 1 < x.size(); ++i) {
        double a = x[i + 1] - x[i] * x[i];
        double b = 1.0 - x[i];
        sum += 100.0 * a * a + b * b;
    }
    return sum;
}

bool same_bits(double a, double b) { return std::memcmp(&a, &b, sizeof a) == 0; }

bool same_bits(const std::vector<double>& a, const std::vector<double>& b) {
    if (a.size() != b.size()) return false;
    for (std::size_t i = 0; i < a.size(); ++i) {
        if (!same_bits(a[i], b[i])) return false;
    }
    return true;
}

struct ObjectiveFailure : std::runtime_error {
    using std::runtime_error::runtime_error;
};

bool test_quadratic(bool rotation) {
    qules::Options options;
    options.max_evals = 40;
    options.rotation = rotation;
    qules::Result r = qules::optimize(quadratic, {3.0, 1.0}, options);
    return r.evals == 40 && r.f_best < 1e-12 && std::fabs(r.x_best[0] - 1.0) < 1e-5 &&
           std::fabs(r.x_best[1] + 2.0) < 1e-5;
}

bool test_rosenbrock() {
    qules::Options options;
    options.max_evals = 80;
    qules::Result r = qules::optimize(rosenbrock, {-1.2, 1.0, 0.5}, options);
    return r.evals == 80 && std::isfinite(r.f_best);
}

bool test_verbose_log() {
    std::vector<std::string> lines;
    qules::Options options;
    options.max_evals = 40;
    options.verbose = true;
    options.log = [&lines](std::string_view line) { lines.emplace_back(line); };
    qules::optimize(quadratic, {3.0, 1.0}, options);
    for (const std::string& line : lines) {
        if (line.find("Termination") != std::string::npos) return true;
    }
    return false;
}

bool test_objective_exception() {
    int calls = 0;
    auto failing = [&calls](const std::vector<double>& x) {
        if (++calls == 3) throw ObjectiveFailure("boom");
        return quadratic(x);
    };
    qules::Options options;
    options.max_evals = 40;
    try {
        qules::optimize(failing, {3.0, 1.0}, options);
    } catch (const ObjectiveFailure& e) {
        // f must not be called again once it has thrown.
        return std::strcmp(e.what(), "boom") == 0 && calls == 3;
    }
    return false;
}

bool test_session_matches_optimize() {
    qules::Options options;
    options.max_evals = 40;
    qules::Result direct = qules::optimize(quadratic, {3.0, 1.0}, options);

    qules::Session session({3.0, 1.0}, options);
    std::vector<double> x;
    while (session.ask(x)) session.tell(quadratic(x));
    bool finished = session.finished();
    qules::Result driven = session.best();
    session.close();

    return finished && same_bits(direct.x_best, driven.x_best) &&
           same_bits(direct.f_best, driven.f_best) && direct.evals == driven.evals &&
           same_bits(direct.delta, driven.delta);
}

bool test_second_runtime_rejected(const std::filesystem::path& bundle) {
    try {
        qules::Runtime again(bundle);
    } catch (const std::logic_error&) {
        return true;
    }
    return false;
}

std::string wide_to_narrow(const std::wstring& wide, UINT code_page) {
    int needed = WideCharToMultiByte(code_page, 0, wide.c_str(), -1, nullptr, 0, nullptr, nullptr);
    std::string narrow(static_cast<std::size_t>(needed > 0 ? needed - 1 : 0), '\0');
    if (needed > 0) {
        WideCharToMultiByte(code_page, 0, wide.c_str(), -1, narrow.data(), needed, nullptr,
                            nullptr);
    }
    return narrow;
}

// The narrow-string overload must decode the real bundle path (given as UTF-8
// or in the ANSI code page, as narrow argv delivers it) back to the wide
// original, and then hit the same single-Runtime guard.
bool test_second_runtime_rejected_narrow(const std::filesystem::path& bundle, UINT code_page) {
    std::string narrow = wide_to_narrow(bundle.wstring(), code_page);
    if (qules::detail::narrow_to_wide(narrow) != bundle.wstring()) return false;
    try {
        qules::Runtime again(narrow);
    } catch (const std::logic_error&) {
        return true;
    }
    return false;
}

}  // namespace

int main() {
    // The wide command line keeps non-ASCII bundle directories intact.
    int argc = 0;
    wchar_t** argv = CommandLineToArgvW(GetCommandLineW(), &argc);
    if (argv == nullptr || argc != 2) {
        std::fprintf(stderr, "usage: test_qules.exe <bundle_dir>\n");
        return 2;
    }
    std::filesystem::path bundle(argv[1]);
    LocalFree(argv);

    try {
        qules::Runtime runtime(bundle);

        run("quadratic rotation=true", [] { return test_quadratic(true); });
        run("quadratic rotation=false", [] { return test_quadratic(false); });
        run("rosenbrock 3-D", test_rosenbrock);
        run("verbose log contains Termination", test_verbose_log);
        run("objective exception propagates", test_objective_exception);
        run("session matches optimize bit-for-bit", test_session_matches_optimize);
        run("second Runtime is rejected", [&bundle] { return test_second_runtime_rejected(bundle); });
        run("second Runtime (UTF-8 string) is rejected",
            [&bundle] { return test_second_runtime_rejected_narrow(bundle, CP_UTF8); });
        run("second Runtime (ANSI string) is rejected",
            [&bundle] { return test_second_runtime_rejected_narrow(bundle, CP_ACP); });
    } catch (const std::exception& e) {
        std::fprintf(stderr, "error: %s\n", e.what());
        return 1;
    }

    std::printf("%d failure(s)\n", failures);
    return failures;
}
