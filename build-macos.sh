#!/usr/bin/env bash
# build-macos.sh -- Build libcvextern.dylib for macOS x64 and/or arm64.
#
# Native build using Xcode Command Line Tools (clang). Produces TWO separate
# arch-specific dylibs (no universal/lipo step), since AgentDVR's installer
# downloads per-arch zips.
#
# Output:
#   ./out/macos-x64/libcvextern.dylib
#   ./out/macos-x64.zip
#   ./out/macos-arm64/libcvextern.dylib
#   ./out/macos-arm64.zip
#
# Usage:
#   ./build-macos.sh                # both archs
#   ./build-macos.sh x64            # Intel only
#   ./build-macos.sh arm64          # Apple Silicon only
#   EMGU_TAG=4.12.0 ./build-macos.sh
#   MACOS_MIN=12.0 ./build-macos.sh # bump minimum macOS version (default 11.0)
#   PORTABLE=0 ./build-macos.sh     # build Emgu's stock "full" without the minimal patches

set -euo pipefail

# ---- Configurable knobs --------------------------------------------------
ARCH_ARG="${1:-both}"
EMGU_TAG="${EMGU_TAG:-4.12.0}"
JOBS="${JOBS:-0}"
PORTABLE="${PORTABLE:-1}"
OUT_DIR="${OUT_DIR:-./out}"
MACOS_MIN="${MACOS_MIN:-11.0}"   # Big Sur. Drops 10.15/Catalina users; bump to 10.15 if needed.

# ---- Setup ---------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

WORK_DIR="${WORK_DIR:-$SCRIPT_DIR/src}"
SRC_DIR="$WORK_DIR/emgucv"
PATCHES_DIR="$SCRIPT_DIR/patches"

section() { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
ok()      { printf '\033[1;32m%s\033[0m\n' "$*"; }
warn()    { printf '\033[1;33m%s\033[0m\n' "$*"; }
fail()    { printf '\033[1;31m%s\033[0m\n' "$*" >&2; exit 1; }

# ---- Preflight -----------------------------------------------------------
section "Preflight"

[ "$(uname)" = "Darwin" ] || fail "This script must run on macOS."

if ! command -v cmake >/dev/null 2>&1; then
    fail "cmake not found. Install with: brew install cmake"
fi
if ! command -v git >/dev/null 2>&1; then
    fail "git not found. Install Xcode Command Line Tools: xcode-select --install"
fi
if ! command -v clang >/dev/null 2>&1; then
    fail "clang not found. Install Xcode Command Line Tools: xcode-select --install"
fi
if ! command -v dotnet >/dev/null 2>&1; then
    fail "dotnet not found. Install .NET 8 SDK: brew install --cask dotnet-sdk"
fi

# ccache: optional but highly recommended. Reduces rebuild time from ~60-90 min to
# ~10-15 min when source is unchanged (e.g., iterating on portable patches or flags).
# Detect Homebrew's ccache libexec dir for both Intel (/usr/local) and Apple Silicon
# (/opt/homebrew) prefixes. Prepending libexec to PATH puts ccache-wrapped clang/clang++
# symlinks ahead of the real compilers, and cmake picks them up transparently.
CCACHE_LIBEXEC=""
if command -v ccache >/dev/null 2>&1; then
    for candidate in /opt/homebrew/opt/ccache/libexec /usr/local/opt/ccache/libexec; do
        if [ -d "$candidate" ]; then
            CCACHE_LIBEXEC="$candidate"
            break
        fi
    done
    if [ -n "$CCACHE_LIBEXEC" ]; then
        export PATH="$CCACHE_LIBEXEC:$PATH"
        export CCACHE_COMPILERCHECK=content
        export CCACHE_MAXSIZE=10G
        export CCACHE_SLOPPINESS=time_macros,include_file_mtime,include_file_ctime
        echo "ccache: $(ccache --version | head -1) — wrapping via $CCACHE_LIBEXEC"
    else
        warn "ccache found but Homebrew libexec dir not located — proceeding without."
    fi
else
    warn "ccache not installed — rebuilds will be slow. Install with: brew install ccache"
fi

echo "Host: $(uname -m) ($(sw_vers -productName) $(sw_vers -productVersion))"
echo "cmake: $(cmake --version | head -1)"
echo "clang: $(clang --version | head -1)"
echo "dotnet: $(dotnet --version)"
echo "Targets: $ARCH_ARG"
echo "macOS deployment target: $MACOS_MIN"
echo

mkdir -p "$WORK_DIR" "$OUT_DIR"
WORK_DIR="$(cd "$WORK_DIR" && pwd)"
OUT_DIR="$(cd "$OUT_DIR" && pwd)"

# ---- Source ---------------------------------------------------------------
if [ ! -d "$SRC_DIR" ]; then
    section "Cloning emgucv at tag $EMGU_TAG"
    git clone --depth 1 --branch "$EMGU_TAG" https://github.com/emgucv/emgucv.git "$SRC_DIR"

    section "Initializing submodules"
    ( cd "$SRC_DIR" && git submodule update --init --depth 1 --recursive \
        -- opencv opencv_contrib opencv_extra eigen harfbuzz hdf5 vtk \
           3rdParty/freetype2 \
           Emgu.CV.Extern/tesseract/libtesseract/tesseract-ocr.git \
           Emgu.CV.Extern/tesseract/libtesseract/leptonica/leptonica.git )
else
    echo "Source directory already exists, reusing: $SRC_DIR"
fi

# ---- Apply patches -------------------------------------------------------
if [ "$PORTABLE" = "1" ]; then
    section "Applying AgentDVR-minimal patches"

    # Restore patched files from git so re-runs apply patches to a clean baseline.
    # opencv is a submodule of emgucv so we cd into it.
    ( cd "$SRC_DIR/opencv" && \
        git checkout HEAD -- 'modules/core/include/opencv2/core/private.cuda.hpp' 2>/dev/null ) || true

    ( cd "$SRC_DIR" && for f in \
        Emgu.CV.Extern/stitching/stitching_c.h \
        Emgu.CV.Extern/xfeatures2d/nonfree_c.h \
        Emgu.CV.Extern/core/core_cuda_c.cpp \
        Emgu.CV.Extern/cudaarithm/cudaarithm_c.h \
        Emgu.CV.Extern/cudabgsegm/cudabgsegm_c.h \
        Emgu.CV.Extern/cudacodec/cudacodec_c.h \
        Emgu.CV.Extern/cudafeatures2d/cudafeatures2d_c.h \
        Emgu.CV.Extern/cudafilters/cudafilters_c.h \
        Emgu.CV.Extern/cudaimgproc/cudaimgproc_c.h \
        Emgu.CV.Extern/cudalegacy/cudalegacy_c.h \
        Emgu.CV.Extern/cudaobjdetect/cudaobjdetect_c.h \
        Emgu.CV.Extern/cudaoptflow/cudaoptflow_c.h \
        Emgu.CV.Extern/cudastereo/cudastereo_c.h \
        Emgu.CV.Extern/cudawarping/cudawarping_c.h
    do
        git checkout HEAD -- "$f" 2>/dev/null || true
    done )
    echo "  Restored source files from git baseline"

    # Feature2D stub -> forward decl (avoids collision with real cv::Feature2D)
    sed -i '' 's|class Feature2D {};|class Feature2D;|g' \
        "$SRC_DIR/Emgu.CV.Extern/stitching/stitching_c.h"
    sed -i '' 's|class Feature2D {};|class Feature2D;|g' \
        "$SRC_DIR/Emgu.CV.Extern/xfeatures2d/nonfree_c.h"
    echo "  Patched Feature2D stubs"

    # Remove imgcodecs Emgu wrapper (references cv::Animation, which only exists in built imgcodecs module)
    rm -rf "$SRC_DIR/Emgu.CV.Extern/imgcodecs"
    echo "  Removed Emgu.CV.Extern/imgcodecs wrapper subdir"

    # Neutralize Emgu cuda*/*_c.h throw stubs. macOS .NET handles native exceptions similar
    # to Linux (no SEH), so propagating cv::Exception through P/Invoke is risky. Same fix as
    # the Linux Dockerfiles. clang on macOS is permissive about missing returns (warning,
    # not error like MSVC) so this is safe.
    find "$SRC_DIR/Emgu.CV.Extern" -type d -name 'cuda*' | while read -r d; do
        for h in "$d"/*_c.h; do
            [ -f "$h" ] || continue
            sed -i '' 's|CV_NORETURN ||g; s|CV_Error([^)]*);|/* defensive no-op */;|g' "$h"
        done
    done
    echo "  Neutralized Emgu cuda throw stubs"

    # Patch OpenCV's internal throw_no_cuda() in private.cuda.hpp -- same rationale
    sed -i '' 's|CV_NORETURN void throw_no_cuda() { CV_Error([^)]*); }|void throw_no_cuda() { /* defensive no-op */ }|g' \
        "$SRC_DIR/opencv/modules/core/include/opencv2/core/private.cuda.hpp"
    echo "  Patched OpenCV internal throw_no_cuda()"

    # Overlay the core_cuda_c.cpp stub (avoids CV_Assert in DeviceInfo constructor)
    if [ -f "$PATCHES_DIR/core_cuda_c.cpp.stub" ]; then
        cp "$PATCHES_DIR/core_cuda_c.cpp.stub" "$SRC_DIR/Emgu.CV.Extern/core/core_cuda_c.cpp"
        echo "  Replaced Emgu.CV.Extern/core/core_cuda_c.cpp with safe stub"
    else
        warn "patches/core_cuda_c.cpp.stub not found -- skipping core stub overlay"
    fi

    ok "Patches applied."
fi

# ---- Build helper --------------------------------------------------------
build_arch() {
    local logical_arch="$1"     # x64 or arm64 (Emgu's naming)
    local cmake_arch            # x86_64 or arm64 (Apple's naming)
    case "$logical_arch" in
        x64)   cmake_arch="x86_64" ;;
        arm64) cmake_arch="arm64" ;;
        *)     fail "Unknown arch: $logical_arch" ;;
    esac

    section "Building macOS $logical_arch ($cmake_arch)"

    local build_dir="$SRC_DIR/build_macos-$logical_arch"
    mkdir -p "$build_dir"

    # If the cached CMakeCache.txt is for a different source dir or different arch,
    # wipe and re-configure clean.
    local cache="$build_dir/CMakeCache.txt"
    local wipe_reason=""
    if [ -f "$cache" ]; then
        local cached_home
        cached_home="$(grep '^CMAKE_HOME_DIRECTORY:INTERNAL=' "$cache" | head -1 | cut -d= -f2-)"
        local expected_home="$SRC_DIR"
        if [ -n "$cached_home" ] && [ "$cached_home" != "$expected_home" ]; then
            wipe_reason="source path changed (cached=$cached_home, expected=$expected_home)"
        fi
        if [ -z "$wipe_reason" ]; then
            local cached_arch
            cached_arch="$(grep '^CMAKE_OSX_ARCHITECTURES:STRING=' "$cache" | head -1 | cut -d= -f2-)"
            if [ -n "$cached_arch" ] && [ "$cached_arch" != "$cmake_arch" ]; then
                wipe_reason="arch changed (cached=$cached_arch, expected=$cmake_arch)"
            fi
        fi
        if [ -z "$wipe_reason" ] && [ "$PORTABLE" = "1" ]; then
            local cached_shared
            cached_shared="$(grep '^BUILD_SHARED_LIBS:BOOL=' "$cache" | head -1 | cut -d= -f2-)"
            if [ "$cached_shared" = "ON" ]; then
                wipe_reason="BUILD_SHARED_LIBS is ON in cached config but portable build needs OFF"
            fi
        fi
    fi
    if [ -n "$wipe_reason" ]; then
        warn "Wiping $build_dir: $wipe_reason"
        rm -rf "$build_dir"
        mkdir -p "$build_dir"
    fi

    # Init cache (mirrors the AgentDVR-minimal Linux build)
    local init_cache="$build_dir/init-cache.cmake"
    {
        echo '# Auto-generated by build-macos.sh -- do not edit manually.'
        echo 'set(CMAKE_BUILD_TYPE "Release" CACHE STRING "")'
        # Static-link everything into libcvextern.dylib instead of producing separate
        # libopencv_core/imgproc/etc dylibs. Matches Linux/Windows builds.
        echo 'set(BUILD_SHARED_LIBS OFF CACHE BOOL "")'
        echo "set(CMAKE_OSX_ARCHITECTURES \"$cmake_arch\" CACHE STRING \"\")"
        echo "set(CMAKE_OSX_DEPLOYMENT_TARGET \"$MACOS_MIN\" CACHE STRING \"\")"
        echo 'set(BUILD_TESTS OFF CACHE BOOL "")'
        echo 'set(BUILD_PERF_TESTS OFF CACHE BOOL "")'
        echo 'set(BUILD_DOCS OFF CACHE BOOL "")'
        echo 'set(BUILD_opencv_apps OFF CACHE BOOL "")'
        echo 'set(BUILD_opencv_ts OFF CACHE BOOL "")'
        echo 'set(BUILD_opencv_python2 OFF CACHE BOOL "")'
        echo 'set(BUILD_opencv_python3 OFF CACHE BOOL "")'
        echo 'set(BUILD_opencv_java OFF CACHE BOOL "")'
        echo 'set(BUILD_JAVA OFF CACHE BOOL "")'
        echo 'set(CMAKE_POSITION_INDEPENDENT_CODE ON CACHE BOOL "")'
        echo 'set(CMAKE_CXX_STANDARD "17" CACHE STRING "")'
        echo 'set(WITH_EIGEN ON CACHE BOOL "")'
        if [ "$PORTABLE" = "1" ]; then
            local contrib_path="$SRC_DIR/opencv_contrib/modules"
            echo '# AgentDVR-minimal portable build flags'
            echo 'set(BUILD_LIST "core,imgproc,calib3d,features2d,flann,video,objdetect,tracking,plot,bgsegm" CACHE STRING "")'
            echo "set(OPENCV_EXTRA_MODULES_PATH \"$contrib_path\" CACHE PATH \"\")"
            # CRITICAL: WITH_*=OFF flags below prevent OpenCV's CMake from auto-detecting
            # and linking Homebrew-provided libs (libtiff, libpng, libjpeg, etc.) at
            # paths like /opt/homebrew/opt/libtiff/lib/libtiff.dylib or
            # /usr/local/opt/libtiff/lib/libtiff.dylib. Those absolute paths get baked
            # into the dylib's LC_LOAD_DYLIB load commands and break on end-user machines
            # that don't have Homebrew installed (or have it at a different prefix).
            # BUILD_*=OFF (further below) just tells OpenCV not to compile its bundled
            # copy — without WITH_*=OFF, the system version still gets linked.
            # Same fix as the Linux Dockerfiles; see Dockerfile.x64 for full rationale.
            echo 'set(WITH_FFMPEG OFF CACHE BOOL "")'
            echo 'set(WITH_GSTREAMER OFF CACHE BOOL "")'
            echo 'set(WITH_V4L OFF CACHE BOOL "")'
            echo 'set(WITH_HDF5 OFF CACHE BOOL "")'
            echo 'set(WITH_VTK OFF CACHE BOOL "")'
            echo 'set(WITH_GDAL OFF CACHE BOOL "")'
            echo 'set(WITH_TIFF OFF CACHE BOOL "")'
            echo 'set(WITH_JPEG OFF CACHE BOOL "")'
            echo 'set(WITH_PNG OFF CACHE BOOL "")'
            echo 'set(WITH_WEBP OFF CACHE BOOL "")'
            echo 'set(WITH_OPENEXR OFF CACHE BOOL "")'
            echo 'set(WITH_JASPER OFF CACHE BOOL "")'
            echo 'set(WITH_OPENJPEG OFF CACHE BOOL "")'
            echo 'set(WITH_FREETYPE OFF CACHE BOOL "")'
            echo 'set(WITH_PROTOBUF OFF CACHE BOOL "")'
            echo 'set(WITH_ADE OFF CACHE BOOL "")'
            echo 'set(WITH_OBSENSOR OFF CACHE BOOL "")'
            echo 'set(WITH_1394 OFF CACHE BOOL "")'
            # macOS-specific: AVFoundation is Apple's video capture framework, pulled
            # in by videoio module (not in BUILD_LIST anyway, but disable explicitly).
            echo 'set(WITH_AVFOUNDATION OFF CACHE BOOL "")'
            echo 'set(WITH_IPP OFF CACHE BOOL "")'
            echo 'set(WITH_OPENCL OFF CACHE BOOL "")'
            echo 'set(WITH_LAPACK OFF CACHE BOOL "")'
            echo 'set(WITH_TBB OFF CACHE BOOL "")'
            echo 'set(WITH_QUIRC OFF CACHE BOOL "")'
            echo 'set(WITH_ITT OFF CACHE BOOL "")'
            echo 'set(BUILD_IPP_IW OFF CACHE BOOL "")'
            echo 'set(BUILD_ITT OFF CACHE BOOL "")'
            echo 'set(BUILD_opencv_hdf OFF CACHE BOOL "")'
            echo 'set(EMGU_CV_WITH_TIFF FALSE CACHE BOOL "")'
            echo 'set(EMGU_CV_WITH_TESSERACT FALSE CACHE BOOL "")'
            echo 'set(EMGU_CV_WITH_FREETYPE FALSE CACHE BOOL "")'
            echo 'set(BUILD_PNG OFF CACHE BOOL "")'
            echo 'set(BUILD_JPEG OFF CACHE BOOL "")'
            echo 'set(BUILD_TIFF OFF CACHE BOOL "")'
            echo 'set(BUILD_WEBP OFF CACHE BOOL "")'
            echo 'set(BUILD_JASPER OFF CACHE BOOL "")'
            echo 'set(BUILD_OPENEXR OFF CACHE BOOL "")'
            # CPU dispatch: only matters for x86_64. arm64 always uses NEON (baseline).
            if [ "$cmake_arch" = "x86_64" ]; then
                echo 'set(CPU_BASELINE "SSE4_2" CACHE STRING "")'
                echo 'set(CPU_DISPATCH "AVX;FP16;AVX2;AVX_512F;AVX512_SKX" CACHE STRING "")'
            fi
        fi
    } > "$init_cache"

    # Configure
    local jobs=${JOBS}
    if [ "$jobs" -eq 0 ]; then jobs=$(sysctl -n hw.ncpu); fi

    echo "Configure log -> $build_dir/cmake-configure.log"
    ( cd "$build_dir" && cmake -G "Unix Makefiles" -C "$init_cache" "$SRC_DIR" 2>&1 | tee cmake-configure.log )
    if [ ! -f "$cache" ]; then fail "cmake configure failed (no CMakeCache.txt produced)"; fi

    # Build only the cvextern target (skips Emgu's dotnet projects, examples, etc.)
    section "cmake --build (target: cvextern, jobs: $jobs)"
    echo "Build log    -> $build_dir/cmake-build.log"
    if [ -n "$CCACHE_LIBEXEC" ]; then
        echo "=== ccache stats (before build) ==="; ccache -s
    fi
    ( cd "$build_dir" && cmake --build . --config Release --target cvextern --parallel "$jobs" 2>&1 | tee cmake-build.log ) || {
        warn "Last 80 lines of build log:"
        tail -80 "$build_dir/cmake-build.log"
        fail "cmake build failed for $logical_arch"
    }
    if [ -n "$CCACHE_LIBEXEC" ]; then
        echo "=== ccache stats (after build) ==="; ccache -s
    fi

    # Locate output
    local dylib="$SRC_DIR/libs/runtimes/osx/native/$logical_arch/libcvextern.dylib"
    if [ ! -f "$dylib" ]; then
        # Fallback search
        dylib="$(find "$SRC_DIR/libs" -name libcvextern.dylib -type f 2>/dev/null | head -1)"
        [ -n "$dylib" ] && [ -f "$dylib" ] || fail "libcvextern.dylib not produced"
        warn "Output found at unexpected path: $dylib"
    fi

    # Strip
    echo "Size before strip: $(du -h "$dylib" | cut -f1)"
    strip -x "$dylib"
    echo "Size after strip:  $(du -h "$dylib" | cut -f1)"

    # Verify arch
    echo "Verify arch:"
    file "$dylib"
    if ! file "$dylib" | grep -q "$cmake_arch"; then
        warn "Output dylib arch doesn't match expected $cmake_arch"
    fi

    # Verify load commands against an allowed-system-only whitelist.
    # Linux equivalent: the readelf NEEDED whitelist in Dockerfile.x64. Same goal —
    # fail the build if any load command references a path that isn't guaranteed
    # to exist on every end-user macOS install. The big risks on macOS are Homebrew
    # paths (/opt/homebrew/... on Apple Silicon, /usr/local/opt/... on Intel) — those
    # only exist if the user has Homebrew installed at the same prefix.
    #
    # Allowed:
    #   /usr/lib/lib{System,c++,objc,z,iconv,resolv}.* — base macOS, present on every install
    #   /System/Library/{Frameworks,PrivateFrameworks}/* — built-in Apple frameworks
    #   @rpath / @loader_path / @executable_path — relocatable refs (self-ref typically)
    echo "Verify load commands (otool -L whitelist):"
    otool -L "$dylib"
    # Build the allowed regex as ERE. Single-quoted so backslashes pass through
    # literally to grep. Anchored with ^...$ so partial matches don't slip by.
    local allowed_re='^(/usr/lib/(libSystem\.B|libc\+\+\.1|libc\+\+abi|libobjc\.A|libz\.1|libiconv\.2|libresolv\.9)\.dylib|/System/Library/(Frameworks|PrivateFrameworks)/.*|@rpath/.*|@loader_path/.*|@executable_path/.*)$'
    # Initialize to empty so set -u doesn't complain if the assignment below
    # somehow produces nothing.
    local unexpected_deps=""
    # `grep -Ev` prints lines NOT matching the allowed regex (i.e. unexpected deps).
    # `|| true` swallows grep's exit 1 ("no matches") so the assignment doesn't
    # fail the script via set -e when everything is properly whitelisted.
    unexpected_deps="$(otool -L "$dylib" | tail -n +2 | awk '{print $1}' | grep -Ev "$allowed_re" || true)"
    if [ -n "$unexpected_deps" ]; then
        warn "!!! Unexpected dylib load commands (non-portable):"
        echo "$unexpected_deps" | sed 's/^/    /' >&2
        warn "These paths are NOT guaranteed to exist on end-user macOS installs."
        warn "Homebrew paths (/opt/homebrew/..., /usr/local/opt/...) are the usual culprit."
        warn "Add the corresponding -DWITH_<NAME>=OFF flag to the init_cache above."
        fail "Aborting: libcvextern.dylib has non-portable dependencies."
    fi
    ok "Load commands OK — only portable system deps."

    # Copy to output
    local arch_out_dir="$OUT_DIR/macos-$logical_arch"
    mkdir -p "$arch_out_dir"
    cp -p "$dylib" "$arch_out_dir/libcvextern.dylib"

    # Zip
    local zip_path="$OUT_DIR/macos-$logical_arch.zip"
    rm -f "$zip_path"
    ( cd "$arch_out_dir" && zip -q "$zip_path" libcvextern.dylib )

    ok "macos-$logical_arch build OK: $arch_out_dir/libcvextern.dylib ($(du -h "$arch_out_dir/libcvextern.dylib" | cut -f1))"
    ok "Zip: $zip_path ($(du -h "$zip_path" | cut -f1))"
}

# ---- Dispatch ------------------------------------------------------------
case "$ARCH_ARG" in
    x64)   build_arch x64 ;;
    arm64) build_arch arm64 ;;
    both)  build_arch x64; build_arch arm64 ;;
    *)     fail "Unknown arch '$ARCH_ARG' (expected: x64 | arm64 | both)" ;;
esac

section "Done"
echo "Upload the .zip files to https://files.ispyconnect.com/libs/opencv/${EMGU_TAG}.5764/ and bump OpenCvVersion in Dependencies.cs."
