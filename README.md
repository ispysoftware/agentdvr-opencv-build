# AgentDVR — Custom Emgu CV native builds (Linux x64 / arm64 / Windows x64)

This folder builds **Emgu CV's native binary** from source for the platforms AgentDVR ships, with the same module set and CUDA-defensive patches applied to each. The Linux builds use Docker; the Windows build uses native MSVC.

## Why this exists

Emgu's `Emgu.CV.runtime.ubuntu-x64` NuGet (4.12.0.5764) is built against glibc 2.38 (Ubuntu 24.04 base), so on Ubuntu 22.04 and older it fails to load with `GLIBC_2.38 not found`. Emgu doesn't publish a version-specific `ubuntu.22.04-x64` Emgu.CV package. Building on a 20.04 base ourselves lowers the glibc floor to 2.31. Same idea for Bullseye-based Pi OS on arm64.

Separately, when AgentDVR runs with ONNX Runtime's CUDA execution provider, **Emgu's `cv::cuda::*` wrapper stubs throw `cv::Exception` on Linux even though we're not built with CUDA** — C++ exceptions through P/Invoke on .NET/Linux is undefined behavior and crashes the process. The portable build neutralizes these stubs into no-ops. The same patch goes into the Windows build for consistency.

| Target           | Build tooling          | Floor / target           | Output zip          |
| ---------------- | ---------------------- | ------------------------ | ------------------- |
| Linux x64        | Docker (Ubuntu 20.04)  | glibc 2.31               | `linux-x64.zip`     |
| Linux arm64      | Docker (Debian 11)     | glibc 2.31               | `linux-arm64.zip`   |
| Windows x64      | Native MSVC (VS 2022)  | Windows 10+ / .NET 8     | `win-x64.zip`       |
| macOS x64        | Native Xcode CLT       | macOS 11+ (Big Sur)      | `macos-x64.zip`     |
| macOS arm64      | Native Xcode CLT       | macOS 11+ (Big Sur)      | `macos-arm64.zip`   |

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

```powershell
# Both Linux archs
.\build.ps1

# x64 only (fast — ~20-35 min on 8 cores)
.\build.ps1 -Arch x64

# arm64 only (slow under QEMU — 2-6 hours, or 60-90 min on a native arm64 host)
.\build.ps1 -Arch arm64

# Override Emgu git tag / build profile / parallelism
.\build.ps1 -EmguTag 4.12.0 -BuildType full -Jobs 8

# Skip the .zip packaging step
.\build.ps1 -SkipZip
```

```bash
./build.sh              # both Linux archs
./build.sh x64          # x64 only
./build.sh arm64        # arm64 only
EMGU_TAG=4.12.0 BUILD_TYPE=full JOBS=8 ./build.sh
```

### Windows x64 build via native MSVC (`build-windows.ps1`)

```powershell
# Default: tag 4.12.0, VS 2022, all cores, portable patches enabled
.\build-windows.ps1

# Override tag / VS version
.\build-windows.ps1 -EmguTag 4.12.0 -VsVersion 2022

# Limit parallelism
.\build-windows.ps1 -Jobs 8

# Disable the AgentDVR-minimal patches (build Emgu's stock "full" set instead)
.\build-windows.ps1 -Portable:$false

# Skip the .zip packaging step
.\build-windows.ps1 -SkipZip
```

Expected first-run time: 45-90 min on a fast 8-core box. Subsequent runs are much faster — by default the clone goes to `./src` (a subfolder of this directory) and persists across invocations, so the git clone + submodule init steps are skipped and cmake's incremental build cache only rebuilds changed files. Override the workspace location with `-WorkDir`.

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
```

## Verification

The Dockerfile already runs `nm` and `ldd` checks before exporting the artifact. To re-verify after extraction:

```bash
# Should print no version higher than the target floor
nm --dynamic --undefined-only ./out/linux-x64/libcvextern.so \
    | grep -oE 'GLIBC_[0-9.]+' | sort -V | uniq | tail
# Expect max GLIBC_2.31 for both x64 and arm64

# Should be empty
ldd ./out/linux-x64/libcvextern.so | grep "not found"
```

For arm64 binaries on an x64 box you'll need `aarch64-linux-gnu-nm` and `qemu-aarch64-static` (or just run the check inside the Docker container).

If the glibc floor comes back higher than the target, something in the build is calling a newer libc symbol — check the build log (also exported as `./out/linux-x64/emgu_build.log`) for which dependency pulled it in.

## Wiring into AgentDVR

The managed `Dependencies.cs` downloader expects:

```
https://files.ispyconnect.com/libs/opencv/<OpenCvVersion>/linux-x64.zip
https://files.ispyconnect.com/libs/opencv/<OpenCvVersion>/linux-arm64.zip
```

with each zip containing **`libcvextern.so` at the root**. The wrapper packages exactly this layout.

To roll a new version:

1. Build both zips: `./build.ps1` (or `./build.sh`).
2. Upload `out/linux-x64.zip` and `out/linux-arm64.zip` to the CDN under `libs/opencv/<new-version>/`.
3. Bump `const string OpenCvVersion = "..."` in `D:\Projects\agent-service\SharedLogic\Dependencies.cs`.
4. Existing installs will see the new version, blow away `.opencv_version`, and re-download.

If you ever need a sibling lib alongside `libcvextern.so` (e.g. a custom `libgeotiff.so.5`), drop it into the zip alongside the .so — the install code copies everything to `Statics.AppPath` and the dynamic loader will find it.

## Build profile (`-BuildType` / `BUILD_TYPE`)

This argument is forwarded directly to Emgu's `cmake_configure` script. **With `PORTABLE=1` (the default), the AgentDVR-minimal BUILD_LIST overrides whatever module set the profile would have chosen** — so the practical difference between `full` / `core` / `mini` is small. The flag is left in place mostly so a non-portable build (`PORTABLE=0`) can still pick a profile.

| Profile | What it means (without `PORTABLE=1` override)                                   |
| ------- | ------------------------------------------------------------------------------- |
| `full`  | Default. opencv_contrib + VTK + Tesseract + FreeType. ~30-40 MB.                |
| `core`  | opencv core modules only, no contrib. ~15-20 MB. **NB: drops `tracking` — AgentDVR needs it, don't use this with `PORTABLE=0`.** |
| `mini`  | Excludes dnn, ml, photo, features2d, calib3d, video, gapi, flann. No contrib. **Same warning as core.** |

For AgentDVR, just stick with the default (`full` + `PORTABLE=1`) — the BUILD_LIST strip kicks in regardless.

## Portability flag (`-Portable` / `PORTABLE`)

Default ON. Strips OpenCV down to **only the 10 modules AgentDVR actually uses** and disables optional features that pull in version-pinned or unused runtime `.so` dependencies.

### OpenCV module whitelist (via `BUILD_LIST`)

Only these modules build. Everything else (dnn, ml, photo, stitching, gapi, highgui, world, imgcodecs, aruco, dnn_*, face, optflow, xfeatures2d, ximgproc, and ~30 other contrib modules) is skipped entirely. `imgcodecs` is dropped because AgentDVR uses .NET (System.Drawing / SkiaSharp) for image encoding/decoding, not OpenCV.

| Module | Type | AgentDVR usage |
| ------ | ---- | -------------- |
| `core` | main | foundational — mandatory |
| `imgproc` | main | image processing primitives |
| `calib3d` | main | required transitively by objdetect |
| `features2d` | main | required by calib3d |
| `flann` | main | required by calib3d |
| `video` | main | motion analysis (MOG2 etc); required by tracking |
| `objdetect` | main | CascadeClassifier, HOGDescriptor (PeopleFinder / ObjectFinder) |
| `tracking` | contrib | TrackerCSRT, TrackerMOSSE (TrackedObject) |
| `plot` | contrib | required by tracking |
| `bgsegm` | contrib | improved background subtraction (BackgroundSubtractorMOG/CNT/GMG — distinct from `video`'s MOG2) |

### Optional features disabled

| Disabled | Avoids runtime dep | Notes |
| -------- | ------------------ | ----- |
| FFmpeg / GStreamer / V4L | `libavcodec.so.X`, `libgstreamer-1.0.so.0`, `libv4l*.so` | OpenCV's videoio. AgentDVR has its own ffmpeg fork. Versioned `.so`s are hard-pinned per Ubuntu release. |
| HDF5 / `opencv_hdf` module | `libhdf5_serial.so.103` | Scientific data file format. |
| VTK | `libvtk*.so.X` | 3D visualization toolkit. |
| GDAL / GeoTIFF (`EMGU_CV_WITH_TIFF`) | `libgeotiff.so.5`, `libgdal.so.X` | Geographic-tagged raster I/O. |
| Tesseract (`EMGU_CV_WITH_TESSERACT`) | `libtesseract.so.X`, `libleptonica.so.X` | OCR. Emgu builds these from vendored source in "full" mode — turning off skips the build. |
| FreeType (`EMGU_CV_WITH_FREETYPE`) | (vendored, no runtime dep) | Text rendering inside images. |

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
| `WITH_LAPACK` | Linear algebra acceleration (~1-3 MB) | Mostly used by calib3d's solvers; AgentDVR doesn't run camera calibration. |
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

**Known limitation — undefined behavior for non-void cuda functions.** ~55 of the cuda wrapper functions return non-void (int, double, bool, pointers). With the throw silenced, they fall off without a return statement — returning whatever was last in the return register. For value types this is a garbage int/float (probably harmless). For pointer types it's a garbage address that will crash on use.

For AgentDVR's case this only matters if something is calling a cuda function *without* checking `HasCuda` first. The proper long-term fix is to find that unguarded call site in AgentDVR's code and add the `if (CudaInvoke.HasCuda) { ... }` guard. Use a stack trace from the runtime failure to locate it.

### Disabling the strip

If you ever need a feature back (rebuilt AgentDVR uses YOLO via cv::dnn, say, or you want to ship a CUDA-enabled build), set `-Portable:$false` (PowerShell) or `PORTABLE=0 ./build.sh` (bash). That restores Emgu's stock "full" configure — every module enabled, every dep present.

## Troubleshooting

**"`dotnet` not found" during cmake configure.**  
Emgu's `FindCSharp` errors out without dotnet SDK 8 even for a native-only build. The Dockerfile installs `dotnet-sdk-8.0` from the Microsoft apt feed — if you customize and skip that step, the build will fail at the configure stage.

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
| `Dockerfile.x64`      | Ubuntu 20.04 Docker build; produces `libs/runtimes/ubuntu-x64/native/libcvextern.so`. |
| `Dockerfile.arm64`    | Debian 11 (Bullseye) Docker build; produces `libs/runtimes/linux-arm64/native/libcvextern.so`. |
| `build.ps1`           | Orchestrator for Linux Docker builds. PowerShell.                                  |
| `build.sh`            | Orchestrator for Linux Docker builds. Bash.                                        |
| `build-windows.ps1`   | Orchestrator for the native Windows x64 build (MSVC + cmake). PowerShell.          |
| `out/`                | Created at build time. Holds extracted `.so` / `.dll` files, build logs, and zip outputs. |

## CI/CD (future)

The Dockerfiles are CI-friendly:

```yaml
# .github/workflows/build-opencv.yml (sketch)
jobs:
  x64:
    runs-on: ubuntu-22.04        # any runner; the build host doesn't matter — the Docker base controls glibc floor
    steps:
      - uses: actions/checkout@v4
      - uses: docker/setup-buildx-action@v3
      - run: docker buildx build --platform linux/amd64 -f Dockerfile.x64 --output type=local,dest=./out .
      - uses: actions/upload-artifact@v4
        with: { name: linux-x64, path: out/libcvextern.so }
  arm64:
    runs-on: ubuntu-22.04-arm   # native arm64 runner
    steps: ...                  # mirror with Dockerfile.arm64
```
