#!/usr/bin/env bash
set -euo pipefail

SOURCE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="${BUILD_DIR:-${SOURCE_DIR}/build-android-arm64-cpu}"
OPENBLAS_ROOT="${OPENBLAS_ROOT:?Set OPENBLAS_ROOT to the Android OpenBLAS install prefix}"
ANDROID_NDK_ROOT="${ANDROID_NDK_ROOT:?Set ANDROID_NDK_ROOT to the Android NDK r27c directory}"
NDK_BIN="${ANDROID_NDK_ROOT}/toolchains/llvm/prebuilt/linux-x86_64/bin"
CROSS_FILE="${SOURCE_DIR}/cross-files/aarch64-linux-android-cpu"

export PATH="${NDK_BIN}:${PATH}"

for tool in meson ninja aarch64-linux-android24-clang aarch64-linux-android24-clang++ llvm-ar llvm-strip llvm-readelf llvm-nm ispc; do
  command -v "${tool}" >/dev/null 2>&1 || {
    echo "ERROR: Required build tool not found: ${tool}" >&2
    exit 1
  }
done

for file in \
  "${OPENBLAS_ROOT}/include/cblas.h" \
  "${OPENBLAS_ROOT}/include/openblas_config.h" \
  "${OPENBLAS_ROOT}/lib/libopenblas.a"; do
  test -f "${file}" || {
    echo "ERROR: Required OpenBLAS file missing: ${file}" >&2
    exit 1
  }
done

test -f "${CROSS_FILE}" || {
  echo "ERROR: Android cross file missing: ${CROSS_FILE}" >&2
  exit 1
}

# Match LC0's established Android defaults: avoid speculative prefetching.
cat > "${SOURCE_DIR}/params_override.h" <<'PARAMS'
#define DEFAULT_MAX_PREFETCH 0
#define DEFAULT_TASK_WORKERS 0
PARAMS

rm -rf "${BUILD_DIR}"

meson setup "${BUILD_DIR}" "${SOURCE_DIR}" \
  --cross-file "${CROSS_FILE}" \
  --buildtype=release \
  --wrap-mode=forcefallback \
  -Dcpp_std=c++20 \
  -Db_lto=true \
  -Ddefault_library=static \
  -Ddefault_backend=blas \
  -Dbuild_backends=true \
  -Dblas=true \
  -Dopenblas=true \
  -Dopenblas_include="${OPENBLAS_ROOT}/include" \
  -Dopenblas_libdirs="${OPENBLAS_ROOT}/lib" \
  -Daccelerate=false \
  -Dmkl=false \
  -Ddnnl=false \
  -Dneon=true \
  -Dispc=true \
  -Dispc_native_only=false \
  -Dnative_arch=false \
  -Dnative_cuda=false \
  -Dgtest=false \
  -Dembed=false \
  -Drescorer=false \
  -Dpython_bindings=false \
  -Dplain_cuda=false \
  -Dcudnn=false \
  -Dcutlass=false \
  -Dnvcc=false \
  -Dopencl=false \
  -Dhip=false \
  -Ddx=false \
  -Dtensorflow=false \
  -Donednn=false \
  -Donnx=false \
  -Dmetal=disabled \
  -Dsycl=off \
  -Dxla=false \
  -Dcorex=false

# Confirm that the engine's first/default neural backend is BLAS.
grep -F '#define DEFAULT_BACKEND "blas"' "${BUILD_DIR}/default_backend.h" >/dev/null

ninja -C "${BUILD_DIR}" -j "${NINJA_JOBS:-$(nproc)}"

ENGINE="${BUILD_DIR}/lc0"
test -x "${ENGINE}"

# Verify this is an Android AArch64 executable.
"${NDK_BIN}/llvm-readelf" -h "${ENGINE}" | grep -q 'AArch64' || {
  echo "ERROR: lc0 output is not AArch64." >&2
  exit 1
}

# The BLAS backend calls these OpenBLAS symbols; their presence proves the
# OpenBLAS archive was linked into the executable rather than left optional.
"${NDK_BIN}/llvm-nm" --defined-only "${ENGINE}" | grep -q 'openblas_get_config' || {
  echo "ERROR: OpenBLAS symbols were not linked into lc0." >&2
  exit 1
}

# No GPU backend libraries may appear in the executable's dynamic dependencies.
DYNAMIC_SECTION="$("${NDK_BIN}/llvm-readelf" -d "${ENGINE}" 2>/dev/null || true)"
if printf '%s\n' "${DYNAMIC_SECTION}" | grep -Eiq 'lib(cuda|cudnn|cublas|OpenCL|vulkan|onnxruntime|dnnl|metal)'; then
  echo "ERROR: Unexpected GPU/accelerator runtime dependency found:" >&2
  printf '%s\n' "${DYNAMIC_SECTION}" >&2
  exit 1
fi

"${NDK_BIN}/llvm-strip" --strip-unneeded "${ENGINE}"

printf '\nCPU-only LC0 build complete.\n'
printf 'Binary: %s\n' "${ENGINE}"
printf 'Default backend: blas (OpenBLAS)\n'
printf 'GPU backends: disabled at compile time\n'
printf 'OpenBLAS archive: %s\n' "${OPENBLAS_ROOT}/lib/libopenblas.a"
printf 'ISPC: %s\n' "$(ispc --version | head -n 1)"
