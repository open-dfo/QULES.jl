#!/bin/bash
# Build and test the Linux wheel inside a quay.io/pypa/manylinux_2_28_<arch>
# container (AlmaLinux 8, glibc 2.28), so the wheel runs on glibc 2.28+:
# RHEL/Rocky 8 and later (most HPC clusters), Ubuntu 20.04+, Debian 11+.
#   docker run --rm -v "$PWD:/io" -w /io quay.io/pypa/manylinux_2_28_x86_64 \
#       bash .github/scripts/manylinux_wheel.sh 1.12.6
set -euo pipefail

julia_version=$1
arch=$(uname -m)
case $arch in
    x86_64) julia_arch=x64 ;;
    aarch64) julia_arch=aarch64 ;;
    *) echo "unsupported architecture $arch" >&2; exit 1 ;;
esac

curl -fsSL "https://julialang-s3.julialang.org/bin/linux/$julia_arch/${julia_version%.*}/julia-$julia_version-linux-$arch.tar.gz" |
    tar -xz -C /opt
export PATH="/opt/julia-$julia_version/bin:$PATH"
python=/opt/python/cp311-cp311/bin/python

julia --startup-file=no --project=. -e 'using Pkg; Pkg.instantiate()'
julia --startup-file=no --project=build build/build_library.jl
"$python" bindings/python/build_wheel.py --plat-name "manylinux_2_28_$arch"

"$python" -m pip install bindings/python/dist/pyqules-*.whl
cd /tmp
"$python" /io/bindings/python/tests/test_qules.py
"$python" /io/bindings/python/tests/test_stress.py
