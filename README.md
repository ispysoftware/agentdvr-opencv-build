# AgentDVR — Custom Emgu CV native builds (Linux x64 / arm64 / armhf / Windows x64 / macOS x64 / arm64)

This folder builds **Emgu CV's native binary** from source for the platforms AgentDVR ships, with the same module set and CUDA-defensive patches applied to each. The Linux builds use Docker; the Windows build uses native MSVC.

Current target: **Emgu CV 5.0.0** (git tag `5.0.0`, NuGet `Emgu.CV` 5.0.0.6584), which wraps **OpenCV 5.0**. The managed `Emgu.CV` package version in `agent-service\CoreLogic\CoreLogic.csproj` must match the native binary — a 5.0 managed assembly against a 4.x `cvextern` fails with `EntryPointNotFoundException`, so ship both together.

## Why this exists

Emgu's `Emgu.CV.runtime.ubuntu-x64` NuGet (4.12.0.5764, when this was set up) is built against glibc 2.38 (Ubuntu 24.04 base), so on Ubuntu 22.04 and older it fails to load with `GLIBC_2.38 not found`. Emgu doesn't publish a version-specific `ubuntu.22.04-x64` package. Building on a Debian Buster base lowers the glibc floor to **2.28**, which is compatible with Debian 10+, Ubuntu 18.10+, RHEL 8+, and all Raspberry Pi OS Buster images — the same floor as our FFmpeg builds.

Separately, when AgentDVR runs with ONNX Runtime's CUDA execution provider, **Emgu's `cv::cuda::*` wrapper stubs throw `cv::Exception` on Linux even though we're not built with CUDA** — C++ exceptions through P/Invoke on .NET/Linux is undefined behavior and crashes the process. The portable build neutralizes these stubs into no-ops. The same patch goes into the Windows build for consistency.

| Target           | Build tooling                  | Floor / target           | Output                  |
| ---------------- | ------------------------------ | ------------------------ | ----------------------- |
| Linux x64        | Docker (Debian 10 Buster)      | glibc 2.28               | `linux-x64/libcvextern.so`   |
| Linux arm64      | Docker (Debian 10 Buster)      | glibc 2.28               | `linux-arm64/libcvextern.so` |
| Linux armhf      | Docker (Debian 10 Buster)      | glibc 2.28               | `linux-arm/libcvextern.so`   |
| Windows x64      | Native MSVC (VS 2022)          | Windows 10+ / .NET 8     | `win-x64/cvextern.dll`  |
| macOS x64        | Native Xcode CLT               | macOS 11+ (Big Sur)      | `macos-x64/libcvextern.dylib` |
| macOS arm64      | Native Xcode CLT               | macOS 11+ (Big Sur)      | `macos-arm64/libcvextern.dylib` |

## Prerequisites

### For the Linux builds (Docker)

- **Docker Desktop** (Windows/macOS) or **Docker Engine** (Linux) with `docker buildx` available (bundled since Docker 20.10).
- ~30 GB free disk for the build images and emgucv source + submodules.
- For arm64 emulation on an x64 host: QEMU binfmt handlers — the script installs these automatically via `tonistiigi/binfmt`.

### For the Windows build (native MSVC)

Install once via `winget` (or via the individual installer pages):

```powershell
winget install Microsoft.VisualStudio.2022.BuildTools `
    --override "--quiet --add Microsoft.VisualStudio.Workload.VCTools --add Microsoft.VisualStudio.Component.VC.CMake.Project"
winget install Git.Git
winget install Microsoft.DotNet.SDK.8
```

Then in a new PowerShell window (so PATH is refreshed):

```powershell
.\build-windows.ps1
```

VS Build Tools is the slimmest option (~3 GB). If you have VS Community or Pro installed already, the script will detect and use that instead.

### For the macOS builds (native Xcode CLT)

```bash
# Xcode Command Line Tools (gets clang, libc++, makefile generators, lipo, codesign):
xcode-select --install

# Homebrew if not already installed: https://brew.sh

brew install cmake git
brew install --cask dotnet-sdk    # or download .NET 8 SDK manually
```

Then:

```bash
chmod +x build-macos.sh    # one-time
./build-macos.sh           # both x64 and arm64
./build-macos.sh x64       # Intel Mac target only
./build-macos.sh arm64     # Apple Silicon target only
```

The script cross-compiles between architectures natively (clang supports `-arch x86_64` and `-arch arm64` interchangeably regardless of host), so you can build both archs from either an Intel or Apple Silicon Mac. Build time is ~30-45 min per arch on a modern M-series; longer on older Intel Macs.

## Building

### Linux builds via Docker (`build.ps1` / `build.sh`)

Use `build.ps1` on Windows — it runs in the current window and keeps all output visible. `build.sh` is the equivalent for Linux / macOS / WSL.

```powershell
# x64 + arm64 (default)
.\build.ps1

# Individual targets
.\build.ps1 -Arch x64
.\build.ps1 -Arch arm64   # slow via QEMU on x64 host — 2-6 hours. See "ARM via CI" below.
.\build.ps1 -Arch armhf   # 32-bit ARM / armv7 — slow via QEMU on x64 host (3-8 hours)
.\build.ps1 -Arch all     # x64 + arm64 + armhf

# Override Emgu git tag / build profile / parallelism
.\build.ps1 -EmguTag 5.0.0 -BuildType full -Jobs 8
```

```bash
./build.sh              # x64 + arm64
./build.sh x64
./build.sh arm64
./build.sh armhf
./build.sh all          # x64 + arm64 + armhf
EMGU_TAG=5.0.0 BUILD_TYPE=full JOBS=8 ./build.sh
```

### ARM builds via GitHub Actions (fast — no QEMU)

Building arm64/armhf via QEMU on an x64 host is slow (2-8 hours). The repo includes a
GitHub Actions workflow that runs the builds on GitHub's free ARM hosted runners
where arm64 is fully native (~45-75 min) and armhf runs via the ARM CPU's aarch32
user mode (~60-90 min) — no emulation in either case.

Trigger manually from the **Actions** tab (`Build Linux ARM libcvextern` →
`Run workflow`), or push a tag matching `opencv-v*` to build + attach to a release.
Artifacts are downloadable from the workflow run page for 30 days.

The workflow uses BuildKit's GitHub Actions cache (`type=gha`) to persist the ccache
data set up in the Dockerfiles, so subsequent runs that don't touch source rebuild
in 5-15 min per arch.

### Windows x64 build via native MSVC (`build-windows.ps1`)

```powershell
# Default: tag 5.0.0, VS 2022, all cores, portable patches enabled
.\build-windows.ps1

# Override tag / VS version
.\build-windows.ps1 -EmguTag 5.0.0 -VsVersion 2022

# Limit parallelism
.\build-windows.ps1 -Jobs 8

# Disable the AgentDVR-minimal patches (build Emgu's stock "full" set instead)
.\build-windows.ps1 -Portable:$false
```

Expected first-run time: 45-90 min on a fast 8-core box. Subsequent runs are much faster — by default the clone goes to `./src` (a subfolder of this directory) and persists across invocations, so the git clone + submodule init steps are skipped and cmake's incremental build cache only rebuilds changed files. Override the workspace location with `-WorkDir`.

**Switching Emgu tags:** the scripts refuse to reuse a clone of a different tag (they used to rebuild the old one silently). Delete `src\emgucv` — or pass a fresh `-WorkDir` / `WORK_DIR` — and re-run. The clone uses `core.longpaths=true` because OpenCV 5's contrib (`gapi` samples) has paths longer than `MAX_PATH`.

The Windows build produces `out/win-x64/cvextern.dll`. If the build ever links against `libusb-1.0.dll` (it doesn't with the portable patches active, but might if you turn them off), the script also copies that into the output folder.

The `src/` and `out/` subfolders are gitignored so they won't get committed if you put this directory under source control.

### Direct Docker invocations

If you'd rather skip the wrapper:

```bash
# x64
docker buildx build --platform linux/amd64 \
    -f Dockerfile.x64 \
    --output type=local,dest=./out/linux-x64 .

# arm64 (install QEMU once per host first)
docker run --privileged --rm tonistiigi/binfmt --install arm64
docker buildx create --use --name emgucv-builder 2>/dev/null || true
docker buildx build --platform linux/arm64 \
    -f Dockerfile.arm64 \
    --output type=local,dest=./out/linux-arm64 .

# armhf
docker run --privileged --rm tonistiigi/binfmt --install arm
docker buildx build --platform linux/arm/v7 \
    -f Dockerfile.armhf \
    --output type=local,dest=./out/linux-arm .
```

## Verification

The Dockerfile already runs `nm` and `ldd` checks before exporting the artifact. To re-verify after extraction:

```bash
# Should print no version higher than 2.28
nm --dynamic --undefined-only ./out/linux-x64/libcvextern.so \
    | grep -oE 'GLIBC_[0-9.]+' | sort -V | uniq | tail
# Expect max GLIBC_2.28 for all three Linux targets (x64, arm64, armhf)

# Should be empty
ldd ./out/linux-x64/libcvextern.so | grep "not found"
```

For arm64 / armhf binaries on an x64 box you'll need `aarch64-linux-gnu-nm` / `arm-linux-gnueabihf-nm` (or just run the check inside the Docker container).

If the glibc floor comes back higher than 2.28, something in the build is calling a newer libc symbol — check the build log (also exported as `./out/linux-x64/emgu_build.log`) for which dependency pulled it in.

## Wiring into AgentDVR

The binaries are **not uploaded anywhere** — they are checked into the agent-service repo and copied into every build from `AgentCore\runtimes\<rid>\native\`:

| Build output | Copy to (in `D:\Projects\agent-service\`) |
| ------------ | ----------------------------------------- |
| `out/win-x64/cvextern.dll` | `AgentCore\runtimes\win-x64\native\cvextern.dll` |
| `out/linux-x64/libcvextern.so` | `AgentCore\runtimes\linux-x64\native\libcvextern.so` |
| `out/linux-arm64/libcvextern.so` | `AgentCore\runtimes\linux-arm64\native\libcvextern.so` |
| `out/linux-arm/libcvextern.so` | `AgentCore\runtimes\linux-arm\native\libcvextern.so` |
| `out/macos-x64/libcvextern.dylib` | `AgentCore\runtimes\osx-x64\native\libcvextern.dylib` |
| `out/macos-arm64/libcvextern.dylib` | `AgentCore\runtimes\osx-arm64\native\libcvextern.dylib` |

From there:

- **Debug builds** (Windows): `AgentCore.csproj`'s `CopyWindowsNatives` target xcopies `runtimes\win-x64\native\*.dll` into `bin\...\dlls\x64\`.
- **Packages:** `AgentCore\Deploy\deploy.bat` copies `runtimes\<rid>\native\*` into `dlls\<arch>\` (Windows) or the package root (Linux / macOS).

To roll a new version:

1. Build every target (Linux via Docker or the workflows, Windows via `build-windows.ps1`, macOS via `build-macos.sh` or the workflow).
2. Copy the binaries into `AgentCore\runtimes\` per the table above, **all platforms in the same commit as** the `Emgu.CV` `PackageReference` bump in `CoreLogic\CoreLogic.csproj` — managed and native versions must match.
3. Update the hand-maintained notices in `SharedContent\Licenses\components.json` (Emgu / OpenCV versions, and any library compiled into cvextern — e.g. libjpeg-turbo since 5.0).

If you ever need a sibling lib alongside `libcvextern.so` (e.g. a custom `libgeotiff.so.5`), put it in the same `runtimes\<rid>\native\` folder — `deploy.bat` copies the whole folder.

## Build profile (`-BuildType` / `BUILD_TYPE`)

This argument is forwarded directly to Emgu's `cmake_configure` script. **With `PORTABLE=1` (the default), the AgentDVR-minimal BUILD_LIST overrides whatever module set the profile would have chosen** — so the practical difference between `full` / `core` / `mini` is small. The flag is left in place mostly so a non-portable build (`PORTABLE=0`) can still pick a profile.

| Profile | What it means (without `PORTABLE=1` override)                                   |
| ------- | ------------------------------------------------------------------------------- |
| `full`  | Default. opencv_contrib + VTK + Tesseract + FreeType. ~30-40 MB.                |
| `core`  | opencv core modules only, no contrib. ~15-20 MB. **NB: drops `tracking` — AgentDVR needs it, don't use this with `PORTABLE=0`.** |
| `mini`  | Excludes calib, dnn, photo, features, video. No contrib. **Same warning as core.** |

For AgentDVR, just stick with the default (`full` + `PORTABLE=1`) — the BUILD_LIST strip kicks in regardless.

## Portability flag (`-Portable` / `PORTABLE`)

Default ON. Strips OpenCV down to **only the 14 modules AgentDVR actually uses (directly or as dependencies)** and disables optional features that pull in version-pinned or unused runtime `.so` dependencies.

### OpenCV module whitelist (via `BUILD_LIST`)

Only these modules build. Everything else (dnn, ml, photo, stitching, gapi, highgui, world, dnn_*, face, optflow, xfeatures2d, ximgproc, and ~30 other contrib modules) is skipped entirely.

OpenCV 5 renamed and split modules relative to 4.x: `features2d` → `features`, `calib3d` → `geometry` + `calib` + `stereo`, and `CascadeClassifier` / `HOGDescriptor` moved out of `objdetect` into contrib `xobjdetect`. The managed Emgu namespaces did not change.

| Module | Type | AgentDVR usage |
| ------ | ---- | -------------- |
| `core` | main | foundational — mandatory |
| `imgproc` | main | image processing primitives |
| `geometry` | main | required by imgproc; also hosts `GetPerspectiveTransform` (LPR) |
| `flann` | main | required by geometry |
| `features` | main | required by objdetect / xobjdetect |
| `calib` | main | `CvInvoke.EstimateAffinePartial2D` (face alignment) — Emgu wraps it in `calib_c.cpp`, guarded by `HAVE_OPENCV_CALIB` |
| `stereo` | main | required by calib |
| `objdetect` | main | required by calib |
| `video` | main | motion analysis (MOG2 etc); required by tracking / bgsegm |
| `imgcodecs` | main | required by xobjdetect; Emgu's `cveImread` for `new Mat(filename)` (alert frames). JPEG only — see below |
| `xobjdetect` | contrib | CascadeClassifier, HOGDescriptor (ObjectFinder / PeopleFinder) |
| `tracking` | contrib | TrackerCSRT, TrackerMOSSE (TrackedObject) |
| `plot` | contrib | required by tracking |
| `bgsegm` | contrib | improved background subtraction (BackgroundSubtractorMOG/CNT/GMG — distinct from `video`'s MOG2) |

### Image codecs

`imgcodecs` is built with **JPEG only**, from OpenCV's bundled libjpeg-turbo (`WITH_JPEG=ON`, `BUILD_JPEG=ON`), so it is linked statically and adds no runtime library. Without `nasm` on the PATH, libjpeg-turbo builds without its x86 SIMD code — non-fatal, and scalar decode is plenty for alert frames. PNG / TIFF / WebP / OpenEXR / JPEG 2000 / AVIF / JPEG XL are all off. Every build script fails if the output doesn't export `cveImread`.

### Optional features disabled

| Disabled | Avoids runtime dep | Notes |
| -------- | ------------------ | ----- |
| FFmpeg / GStreamer / V4L | `libavcodec.so.X`, `libgstreamer-1.0.so.0`, `libv4l*.so` | OpenCV's videoio. AgentDVR has its own ffmpeg fork. Versioned `.so`s are hard-pinned per Ubuntu release. |
| HDF5 / `opencv_hdf` module | `libhdf5_serial.so.103` | Scientific data file format. |
| VTK | `libvtk*.so.X` | 3D visualization toolkit. |
| GDAL / GeoTIFF (`EMGU_CV_WITH_TIFF`) | `libgeotiff.so.5`, `libgdal.so.X` | Geographic-tagged raster I/O. |
| Tesseract (`EMGU_CV_WITH_TESSERACT`) | `libtesseract.so.X`, `libleptonica.so.X` | OCR. Emgu builds these from vendored source in "full" mode — turning off skips the build. |
| FreeType (`EMGU_CV_WITH_FREETYPE`) | (vendored, no runtime dep) | Text rendering inside images. |
| Unifont (`WITH_UNIFONT`) | (embedded, no runtime dep) | OpenCV 5 downloads and embeds a ~4 MB CJK font for `putText`. AgentDVR draws its own text. |

With everything stripped, the resulting `libcvextern.so` only links against libc, libstdc++, libgcc_s, libm, libdl, libpthread, libdc1394, and libusb-1.0 — all guaranteed present on any glibc-floor-compliant distro. Verify with:

```bash
ldd ./out/linux-x64/libcvextern.so | grep "not found"   # should be empty
```

### Estimated impact vs Emgu's stock "full" build

| Metric | Stock full | AgentDVR-minimal |
| ------ | ---------- | ---------------- |
| Build time (x64, 8 cores) | 45-90 min | 20-35 min |
| `libcvextern.so` size | ~50-70 MB unstripped | ~25-30 MB after strip + aggressive cuts |
| Runtime `.so` deps (ldd lines) | ~50+ | ~8 |

### Aggressive size cuts beyond BUILD_LIST

OpenCV's defaults bundle a lot of heavyweight features. For surveillance video workloads, none of these are useful — the portable build disables them:

| Disabled | Default behavior | Why we skip it |
| -------- | ---------------- | -------------- |
| `WITH_IPP` | Intel Performance Primitives statically bundled (~5-10 MB) | Only kicks in on Intel CPUs; modest perf benefit on imgproc; not worth the size cost. |
| `WITH_OPENCL` | T-API for GPU dispatch via OpenCL (~2-4 MB) | UMat falls back to Mat. AgentDVR handles GPU dispatch via ONNX, not OpenCV. |
| `WITH_LAPACK` | Linear algebra acceleration (~1-3 MB) | Mostly used by calib / geometry solvers (OpenCV falls back to its own); AgentDVR doesn't run camera calibration. |
| `WITH_TBB` | Intel Threading Building Blocks (~2-3 MB) | OpenCV uses pthread instead. Slightly less efficient parallelism but no measurable AgentDVR impact. |
| `WITH_QUIRC` | QR code decoder inside objdetect | AgentDVR doesn't scan QR codes. |
| `WITH_ITT` / `BUILD_ITT` | Intel profiling hooks (~1 MB) | Useless without Intel VTune. |
| `BUILD_IPP_IW` | IPP integration wrappers (with IPP off, this is dead weight) | — |

**CPU dispatch.** OpenCV compiles separate optimized kernels per SIMD level. The x64 build sets `CPU_BASELINE=SSE4_2` (mandatory floor — works on every x64 CPU made since ~2009) and `CPU_DISPATCH=AVX,FP16,AVX2,AVX_512F,AVX512_SKX` — runtime selects the best variant per function based on detected CPU capability. Server-grade Intel/AMD with AVX-512 gets the fastest path; older / consumer-grade CPUs without AVX-512 silently fall back to AVX2 or SSE4.2. Adds ~3-6 MB to the binary vs dropping AVX-512 entirely, but useful for customers running on Xeon Scalable / EPYC Genoa / Ice Lake+ hardware.

**Strip mode.** The Dockerfile runs `strip --strip-all` after the build — Emgu's stock configure produces an unstripped Release binary which is ~40-50% larger than necessary. `--strip-all` removes both debug info and the static symbol table (only the dynamic symbol table needed for runtime linking is kept).

### CUDA throws — neutralized via stub patch

Even though we're not building with CUDA (`WITH_CUDA=OFF`), Emgu's `Emgu.CV.Extern/cuda*` wrapper subdirectories get globbed and compiled unconditionally. The wrapper code's `#else` branch calls `throw_no_cudaarithm()` etc, which internally calls `CV_Error()` to throw a `cv::Exception`. When AgentDVR runs under ONNX Runtime's CUDA execution provider, something in the code path triggers one of those cuda calls without first checking `CudaInvoke.HasCuda` — and C++ exceptions propagating through P/Invoke into .NET on Linux are **undefined behavior**, typically crashing the whole process.

Trying to delete the `cuda*` subdirs doesn't work — Emgu's `CREATE_OCV_CLASS_PROPERTY` macro has three calls (`cudaimgproc/cuda_hough_lines_detector_property`, `cudaobjdetect/cuda_hog_property`, `cudaobjdetect/cuda_cascade_classifier_property`) that re-create files inside those dirs during cmake configure, so the rm gets reversed.

The portable build's defensive patch instead **neutralizes the throw_no_cuda* stubs**:

```bash
# In each cuda*/*_c.h header:
sed -i 's|CV_NORETURN ||g; s|CV_Error([^)]*);|/* defensive no-op */;|g' "$h"
```

Result:

- `static inline CV_NORETURN void throw_no_cudaarithm() { CV_Error(...); }` becomes `static inline void throw_no_cudaarithm() { /* no-op */; }`.
- Any C# P/Invoke that hits a cuda wrapper now returns silently instead of throwing.
- Symbols remain in `libcvextern.so`, so calls don't fail with EntryPointNotFoundException either — they just no-op.
- `CudaInvoke.HasCuda` still works correctly (backed by `core/core_cuda_c.cpp`, which doesn't go through any throw stub — `cv::cuda::getCudaEnabledDeviceCount` returns 0 in non-CUDA builds). It returns `false`, so well-behaved code paths skip cuda calls entirely.

The Linux and macOS builds apply the same no-op to **OpenCV's own** `throw_no_cuda()`, which OpenCV core's `cv::cuda::setDevice` / `getDevice` call directly. OpenCV 5 moved it from `core/private.cuda.hpp` to `core/private/cuda_stubs.hpp`. `sed -i` exits 0 when nothing matches, so a moved file silently disables the fix — the scripts now grep the result and fail the build if the patch didn't apply.

`patches/core_cuda_c.cpp.stub` replaces Emgu's `core_cuda_c.cpp` on every platform, and its signatures must match Emgu's `core_cuda_c.h` exactly. When bumping Emgu, diff that header against the stub first (5.0 switched `CvSize` / `CvScalar` / `CvRect` to `cv::Size` / `cv::Scalar` / `cv::Rect` and dropped five `gpuMat*` functions).

**Known limitation — undefined behavior for non-void cuda functions.** ~55 of the cuda wrapper functions return non-void (int, double, bool, pointers). With the throw silenced, they fall off without a return statement — returning whatever was last in the return register. For value types this is a garbage int/float (probably harmless). For pointer types it's a garbage address that will crash on use.

For AgentDVR's case this only matters if something is calling a cuda function *without* checking `HasCuda` first. The proper long-term fix is to find that unguarded call site in AgentDVR's code and add the `if (CudaInvoke.HasCuda) { ... }` guard. Use a stack trace from the runtime failure to locate it.

### Disabling the strip

If you ever need a feature back (rebuilt AgentDVR uses YOLO via cv::dnn, say, or you want to ship a CUDA-enabled build), set `-Portable:$false` (PowerShell) or `PORTABLE=0 ./build.sh` (bash). That restores Emgu's stock "full" configure — every module enabled, every dep present.

## Troubleshooting

**"`dotnet` not found" during cmake configure.**  
Emgu's `FindCSharp` errors out without dotnet SDK 8 even for a native-only build. The Dockerfile installs `dotnet-sdk-8.0` from the Microsoft apt feed — if you customize and skip that step, the build will fail at the configure stage.

**"Filename too long" checking out `opencv_contrib` on Windows.**  
OpenCV 5's contrib `gapi` samples exceed `MAX_PATH`. `build-windows.ps1` clones with `core.longpaths=true`; for a manual clone run `git config --global core.longpaths true` first.

**Link errors mentioning `std::filesystem` on the Buster images.**  
GCC 8 (Debian 10, OpenCV 5's stated compiler floor) needs `-lstdc++fs` for `std::filesystem`. Add it to the link flags if a module starts using it.

**Build hangs at "Cloning into 'opencv'..."**  
The OpenCV submodule fork is ~1.5 GB shallow. Slow or flaky networks can stall it. Re-run; `git submodule update --init` resumes.

**arm64 build seems to do nothing for hours.**  
Normal under QEMU emulation. `docker stats` will show CPU pegged. Switch to a native arm64 host (AWS Graviton t4g.medium is ~$0.034/hr, a Pi 5 has ~8 GB RAM, GitHub Actions has hosted arm64 runners) for a 4–10x speedup.

**`ldd` reports "not found" for a system lib.**  
Means the build linked against a system library not present in your target distro. Two options: (1) install the missing lib on the target, or (2) rebuild with that feature disabled via an extra `-DWITH_*=OFF` in the configure.

**Glibc floor is higher than expected.**  
Some transitively-linked system lib is calling a newer libc symbol. Find the offender with:
```bash
for lib in $(ldd libcvextern.so | awk '{print $3}' | grep -v '^$'); do
    echo "=== $lib ===";
    nm --dynamic --undefined-only "$lib" 2>/dev/null | grep -oE 'GLIBC_[0-9.]+' | sort -V | uniq | tail -3
done
```

## File map

| File                  | Purpose                                                                            |
| --------------------- | ---------------------------------------------------------------------------------- |
| `Dockerfile.x64`      | Debian Buster Docker build for linux-x64; produces `libcvextern.so` (glibc 2.28 floor). |
| `Dockerfile.arm64`    | Debian Buster Docker build for linux-arm64; produces `libcvextern.so` (glibc 2.28 floor). |
| `Dockerfile.armhf`    | Debian Buster Docker build for linux-arm (armv7); produces `libcvextern.so` (glibc 2.28 floor). |
| `build.ps1`           | Orchestrator for Linux Docker builds. PowerShell. Use this on Windows.             |
| `build.sh`            | Orchestrator for Linux Docker builds. Bash. Use this on Linux / macOS / WSL.       |
| `build-windows.ps1`   | Orchestrator for the native Windows x64 build (MSVC + cmake). PowerShell.          |
| `build-macos.sh`      | Orchestrator for macOS x64 and arm64 builds (Xcode CLT + cmake). Bash.             |
| `patches/`            | Stub files applied during the Docker build (core_cuda_c.cpp safe stub etc.).       |
| `.github/workflows/build-macos.yml` | GitHub Actions workflow for macOS x64 + arm64 builds. Triggers on `workflow_dispatch` (manual) and `push` on `opencv-v*` tags. |
| `out/`                | Created at build time. Holds extracted `.so` / `.dll` / `.dylib` files and build logs. Gitignored. |

## CI/CD

### macOS — GitHub Actions (`.github/workflows/build-macos.yml`)

The macOS builds run in GitHub Actions on the hosted `macos-14` runner (Apple Silicon / M1). Because clang supports `-arch x86_64` and `-arch arm64` interchangeably, **both architectures build from a single runner** — no Intel Mac needed.

#### Triggers

| Event | When it fires |
| ----- | ------------- |
| `workflow_dispatch` | Manual run from the **Actions** tab — you choose the Emgu tag, arch, and patch level |
| `push` on `opencv-v*` tags | Automatically builds on any tag like `opencv-v5.0.0` or `opencv-v5.0.0.6584` |

The tag step strips the NuGet build revision so `opencv-v5.0.0.6584` correctly checks out the git tag `5.0.0`.

#### Manual run (Actions tab)

1. Go to **Actions → Build macOS libcvextern → Run workflow**.
2. Fill in the inputs:
   - **Emgu CV git tag** — e.g. `5.0.0`
   - **Architecture** — `both` (default), `x64`, or `arm64`
   - **Apply AgentDVR-minimal patches** — `true` (default) or `false`
3. Click **Run workflow**. Typical run time is 60–90 min.

#### Tag-triggered run

Push a tag from the format `opencv-v<X.Y.Z>` to trigger automatically:

```bash
git tag opencv-v5.0.0
git push origin opencv-v5.0.0
```

The workflow builds both archs with the default settings (portable patches on) and attaches the two zip files to a GitHub Release for that tag via `softprops/action-gh-release`.

#### Artifacts

After a run completes, two zip files are available under **Actions → the run → Artifacts** (retained 30 days):

| Artifact name | Contents |
| ------------- | -------- |
| `macos-x64`   | `out/macos-x64.zip` — `libcvextern.dylib` for Intel Macs |
| `macos-arm64` | `out/macos-arm64.zip` — `libcvextern.dylib` for Apple Silicon |

On a tag-triggered run these are also attached directly to the GitHub Release, so you can download them without going into the Actions tab.

#### Source caching

The workflow caches the full emgucv source tree (including submodules) under the key `emgucv-src-<tag>-v1` via `actions/cache@v4`. A re-run for the same tag skips the ~1.5 GB clone + submodule init and goes straight to the build step. If you change the submodule set or patches, bump the cache key suffix to `-v2`.

#### Permissions

The workflow grants `contents: write` so `softprops/action-gh-release` can create the release and upload assets. All other permissions remain at their read-only defaults.

#### Linux / Windows CI (future)

The Linux Docker builds and Windows MSVC build don't have a CI workflow yet. When added, the sketch would be:

```yaml
jobs:
  linux-x64:
    runs-on: ubuntu-22.04        # Docker base (Buster) controls the glibc 2.28 floor, not the host
    steps:
      - uses: actions/checkout@v4
      - uses: docker/setup-buildx-action@v3
      - run: docker buildx build --platform linux/amd64 -f Dockerfile.x64 --output type=local,dest=./out/linux-x64 .
      - uses: actions/upload-artifact@v4
        with: { name: linux-x64, path: out/linux-x64/libcvextern.so }
  linux-arm64:
    runs-on: ubuntu-22.04-arm   # native arm64 runner — 4-10x faster than QEMU
    steps: ...                  # mirror with Dockerfile.arm64
  linux-armhf:
    runs-on: ubuntu-22.04       # QEMU emulation (no native armhf runner available)
    steps: ...                  # mirror with Dockerfile.armhf + tonistiigi/binfmt --install arm
```
