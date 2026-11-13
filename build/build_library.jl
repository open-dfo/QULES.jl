# Builds the Windows x64 native library bundle. Run from the repository root:
#   julia --startup-file=no --project=build build/build_library.jl [output_directory]
# Output (default build/libqules): bin/qules.dll plus the runtime it needs,
# include/qules.h and include/julia_init.h. Distribute the whole directory.
using Pkg
using TOML

VERSION >= v"1.10" || error("The library build requires Julia 1.10 or newer.")
Sys.iswindows() && Sys.ARCH === :x86_64 ||
    error("Build this Windows x64 library with Windows x64 Julia.")
length(ARGS) <= 1 || error("Usage: build_library.jl [output_directory]")

const BUILD_DIR = @__DIR__
const PACKAGE_DIR = dirname(BUILD_DIR)
const OUTPUT_DIR = isempty(ARGS) ? joinpath(BUILD_DIR, "libqules") : abspath(only(ARGS))

# Never delete or overwrite an existing bundle, even after an interrupted build.
ispath(OUTPUT_DIR) && error("Output already exists: $OUTPUT_DIR. Choose a fresh output directory.")

# ---------------------------------------------------------------------------
# Build environment: the runtime manifest plus PackageCompiler, so building
# never upgrades the pinned JuMP/Ipopt versions. The root project is untouched.
const RUNTIME_MANIFEST = joinpath(PACKAGE_DIR, "Manifest.toml")
const BUILD_MANIFEST = joinpath(BUILD_DIR, "Manifest.toml")
isfile(RUNTIME_MANIFEST) || error("Instantiate the root QULES project before building.")
if !isfile(BUILD_MANIFEST)
    manifest = TOML.parsefile(RUNTIME_MANIFEST)
    for entries in values(manifest["deps"]), entry in entries
        if haskey(entry, "path")
            entry["path"] = abspath(joinpath(PACKAGE_DIR, entry["path"]))
        end
    end
    open(BUILD_MANIFEST, "w") do io
        TOML.print(io, manifest; sorted=true)
    end
end

Pkg.activate(BUILD_DIR)
Pkg.develop(Pkg.PackageSpec(path=PACKAGE_DIR); preserve=Pkg.PRESERVE_ALL)
Pkg.instantiate()

using PackageCompiler  # only in this build process

# ---------------------------------------------------------------------------
# Compile. With --strip-ir, the native bundle cannot JIT missing code paths.
# Exercise the native entry points with a separate build-only workload.
# Compile the source package, not the PackageCompiler build environment.
const WORKLOAD_FILE = joinpath(BUILD_DIR, "precompile_library.jl")

PackageCompiler.create_library(
    PACKAGE_DIR,
    OUTPUT_DIR;
    lib_name="qules",
    precompile_execution_file=WORKLOAD_FILE,
    header_files=[joinpath(BUILD_DIR, "qules.h")],
    julia_init_c_file=joinpath(BUILD_DIR, "qules_init.c"),
    incremental=false,
    filter_stdlibs=true,
    include_transitive_dependencies=true,
    include_lazy_artifacts=false,
    cpu_target="generic",
    sysimage_build_args=`--strip-metadata --strip-ir`,
    force=false,
)
rm(joinpath(BUILD_DIR, "qules_init.o"); force=true)  # PackageCompiler leaves it beside the source

# ---------------------------------------------------------------------------
# Trim. Everything removed here was verified unused by running the C, C++,
# Python and MATLAB test programs against the trimmed bundle.
const BIN_DIR = joinpath(OUTPUT_DIR, "bin")
const ARTIFACTS_DIR = joinpath(OUTPUT_DIR, "share", "julia", "artifacts")

function remove_file(path)
    chmod(path, 0o777)  # artifacts are installed read-only
    rm(path)
end

# Julia compiler: unusable without IR. Base libraries QULES never loads:
# 16/32-bit PCRE, GMP C++ bindings, and unversioned duplicates of libgmp/libmpfr.
for name in ("libjulia-codegen.dll", "libLLVM-18jl.dll",
             "libpcre2-16.dll", "libpcre2-16-0.dll", "libpcre2-32.dll", "libpcre2-32-0.dll",
             "libpcre2-posix-3.dll", "libgmpxx.dll", "libgmpxx-4.dll",
             "libgmp.dll", "libmpfr.dll")
    remove_file(joinpath(BIN_DIR, name))
end

# Build-time material shipped inside artifacts: static/import libraries,
# headers, docs, man pages and command-line tools (bzip2, xmllint, lstopo, ...).
const BUILD_ONLY_EXTENSIONS = (".a", ".h", ".pdf", ".exe", ".pc", ".cmake", ".la")
const BUILD_ONLY_DIRS = ("include", "doc", "man")
for (root, _, files) in walkdir(ARTIFACTS_DIR), file in files
    path = joinpath(root, file)
    parts = splitpath(relpath(path, ARTIFACTS_DIR))
    in_bin = length(parts) >= 2 && parts[2] == "bin"
    is_tool = in_bin && !endswith(lowercase(file), ".dll")
    if is_tool || any(ext -> endswith(lowercase(file), ext), BUILD_ONLY_EXTENSIONS) ||
       any(in(BUILD_ONLY_DIRS), parts[2:end-1])
        remove_file(path)
    end
end

# Native debug sections: large, never needed at run time.
strip_tool = Sys.which("strip")
if strip_tool === nothing
    @warn "strip not found; DLL debug sections kept (bundle is larger)"
else
    for (root, _, files) in walkdir(OUTPUT_DIR), file in files
        endswith(lowercase(file), ".dll") || continue
        path = joinpath(root, file)
        chmod(path, 0o755)
        run(`$strip_tool --strip-debug $path`)
    end
end

total = sum(filesize(joinpath(root, f)) for (root, _, files) in walkdir(OUTPUT_DIR) for f in files)
println("QULES library bundle: ", OUTPUT_DIR)
println("Windows x64 library: ", joinpath(BIN_DIR, "qules.dll"))
println("Bundle size: ", round(total / 2^20; digits=1), " MiB")
