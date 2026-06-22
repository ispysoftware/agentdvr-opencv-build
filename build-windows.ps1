# build-windows.ps1 -- Build cvextern.dll for win-x64 with the AgentDVR-minimal module set.
#
# Native MSVC build (no Docker). Runs cmake with the Visual Studio generator + builds the
# `cvextern` target only (skips Emgu's managed projects, OpenCV docs, perf tests, etc.).
#
# Applies the same patches as Dockerfile.x64: 10-module BUILD_LIST, all WITH_* disables,
# CPU_DISPATCH limit, Feature2D forward-decl fix, imgcodecs wrapper removal, cuda throw
# neutralization. Output: ./out/win-x64/cvextern.dll + ./out/win-x64.zip.
#
# Usage:
#   .\build-windows.ps1                          # default: tag 4.12.0, VS 2022, all cores
#   .\build-windows.ps1 -EmguTag 4.12.0          # pin to a specific Emgu tag
#   .\build-windows.ps1 -VsVersion 2019          # use VS 2019 instead
#   .\build-windows.ps1 -Jobs 8                  # limit parallelism
#   .\build-windows.ps1 -Portable:$false         # disable the minimal patches; build Emgu's full default
#   .\build-windows.ps1 -SkipZip                 # produce .dll but not .zip
#   .\build-windows.ps1 -WorkDir D:\path         # override workspace location (defaults to ./src)
#
# Source clone lands at ./src/emgucv by default. ~5-7 GB on disk after build.
# Reuses across runs -- second build skips the clone and only recompiles changed files.

[CmdletBinding()]
param(
    [string]$EmguTag = '4.12.0',

    [ValidateSet('2022','2019')]
    [string]$VsVersion = '2022',

    [int]$Jobs = 0,

    [switch]$Portable = $true,

    [switch]$SkipZip,

    [string]$OutDir = './out',

    [string]$WorkDir
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

function Write-Section($msg) { Write-Host "`n==> $msg" -ForegroundColor Cyan }
function Write-Ok($msg)      { Write-Host $msg -ForegroundColor Green }
function Write-Warn($msg)    { Write-Warning $msg }
function Die($msg)           { Write-Host $msg -ForegroundColor Red; throw $msg }

# ---- Preflight ------------------------------------------------------------
Write-Section "Preflight checks"

# Resolve script directory so the build works from any CWD
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition
Set-Location $scriptDir

# git
if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
    Die "git not found. Install Git for Windows: https://git-scm.com/download/win"
}

# cmake -- prefer the version bundled with VS, fall back to system
$cmakeExe = $null
foreach ($candidate in @(
    "${env:ProgramFiles}\Microsoft Visual Studio\$VsVersion\BuildTools\Common7\IDE\CommonExtensions\Microsoft\CMake\CMake\bin\cmake.exe",
    "${env:ProgramFiles}\Microsoft Visual Studio\$VsVersion\Community\Common7\IDE\CommonExtensions\Microsoft\CMake\CMake\bin\cmake.exe",
    "${env:ProgramFiles}\Microsoft Visual Studio\$VsVersion\Professional\Common7\IDE\CommonExtensions\Microsoft\CMake\CMake\bin\cmake.exe",
    "${env:ProgramFiles}\Microsoft Visual Studio\$VsVersion\Enterprise\Common7\IDE\CommonExtensions\Microsoft\CMake\CMake\bin\cmake.exe",
    "${env:ProgramFiles}\CMake\bin\cmake.exe",
    "${env:ProgramFiles(x86)}\CMake\bin\cmake.exe"
)) {
    if (Test-Path $candidate) { $cmakeExe = $candidate; break }
}
if (-not $cmakeExe) {
    if (Get-Command cmake -ErrorAction SilentlyContinue) {
        $cmakeExe = (Get-Command cmake).Source
    } else {
        Die "cmake not found. Install CMake (https://cmake.org/download/) or VS Build Tools with the C++ CMake tools component."
    }
}
Write-Host "Using cmake: $cmakeExe"

# Visual Studio -- use vswhere if available
$vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
$vsInstallPath = $null
if (Test-Path $vswhere) {
    $versionRange = if ($VsVersion -eq '2022') { '[17.0,18.0)' } else { '[16.0,17.0)' }
    $vsInstallPath = & $vswhere -version $versionRange -requires Microsoft.VisualStudio.Workload.VCTools `
        -property installationPath -latest 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $vsInstallPath) {
        # Fall back: any VS install of the right version range (not just BuildTools workload)
        $vsInstallPath = & $vswhere -version $versionRange -property installationPath -latest 2>$null
    }
}
if (-not $vsInstallPath) {
    Die "Visual Studio $VsVersion (or Build Tools) with C++ workload not found. Install from https://visualstudio.microsoft.com/downloads/ -- pick 'Desktop development with C++'."
}
Write-Host "Using Visual Studio: $vsInstallPath"

# dotnet SDK 8 (required by Emgu's CMake even for native-only builds)
if (-not (Get-Command dotnet -ErrorAction SilentlyContinue)) {
    Die ".NET SDK not found. Install .NET 8.0 SDK: https://dotnet.microsoft.com/download/dotnet/8.0"
}
$dotnetVer = (dotnet --version) 2>$null
Write-Host "Using dotnet: $dotnetVer"

# ---- Workspace -----------------------------------------------------------
# Default to a `src` subfolder beside the script. Stable path (no timestamp) so the
# second build skips clone+submodule init (which takes 20-30 min) and cmake's incremental
# build cache survives between runs. Override with -WorkDir to put it elsewhere.
if (-not $WorkDir) {
    $WorkDir = Join-Path $scriptDir 'src'
}
$WorkDir = [System.IO.Path]::GetFullPath($WorkDir)
Write-Host "Work dir: $WorkDir"
if (-not (Test-Path $WorkDir)) { New-Item -ItemType Directory -Path $WorkDir | Out-Null }

$srcDir = Join-Path $WorkDir "emgucv"
if (-not (Test-Path $srcDir)) {
    Write-Section "Cloning emgucv at tag $EmguTag"
    & git clone --depth 1 --branch $EmguTag https://github.com/emgucv/emgucv.git $srcDir
    if ($LASTEXITCODE -ne 0) { Die "git clone failed" }

    Write-Section "Initializing submodules"
    Push-Location $srcDir
    try {
        & git submodule update --init --depth 1 --recursive `
            -- opencv opencv_contrib opencv_extra eigen harfbuzz hdf5 vtk `
            3rdParty/freetype2 `
            Emgu.CV.Extern/tesseract/libtesseract/tesseract-ocr.git `
            Emgu.CV.Extern/tesseract/libtesseract/leptonica/leptonica.git
        if ($LASTEXITCODE -ne 0) { Die "git submodule update failed" }
    } finally {
        Pop-Location
    }
} else {
    Write-Host "Source directory already exists, reusing: $srcDir"
}

# ---- Apply patches -------------------------------------------------------
if ($Portable) {
    Write-Section "Applying AgentDVR-minimal patches"

    # Restore source files we touch from git first, so the patches are applied to a clean
    # baseline. Makes the script idempotent across runs even if a previous run sed-patched
    # something we no longer want to touch. Need to cd into each submodule for files that
    # live inside one (the opencv repo is a submodule of emgucv).
    $prevEAP = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        # opencv submodule -- has its own .git dir, files only resolvable from within
        $opencvDir = Join-Path $srcDir 'opencv'
        if (Test-Path (Join-Path $opencvDir '.git')) {
            Push-Location $opencvDir
            try {
                & git checkout HEAD -- 'modules/core/include/opencv2/core/private.cuda.hpp' 2>&1 | Out-Null
            } finally { Pop-Location }
        }

        # emgucv main repo files (Emgu.CV.Extern/...)
        Push-Location $srcDir
        try {
            $emguFiles = @(
                'Emgu.CV.Extern/stitching/stitching_c.h',
                'Emgu.CV.Extern/xfeatures2d/nonfree_c.h',
                'Emgu.CV.Extern/cudaarithm/cudaarithm_c.h',
                'Emgu.CV.Extern/cudabgsegm/cudabgsegm_c.h',
                'Emgu.CV.Extern/cudacodec/cudacodec_c.h',
                'Emgu.CV.Extern/cudafeatures2d/cudafeatures2d_c.h',
                'Emgu.CV.Extern/cudafilters/cudafilters_c.h',
                'Emgu.CV.Extern/cudaimgproc/cudaimgproc_c.h',
                'Emgu.CV.Extern/cudalegacy/cudalegacy_c.h',
                'Emgu.CV.Extern/cudaobjdetect/cudaobjdetect_c.h',
                'Emgu.CV.Extern/cudaoptflow/cudaoptflow_c.h',
                'Emgu.CV.Extern/cudastereo/cudastereo_c.h',
                'Emgu.CV.Extern/cudawarping/cudawarping_c.h',
                'Emgu.CV.Extern/core/core_cuda_c.cpp'
            )
            foreach ($f in $emguFiles) {
                if (Test-Path (Join-Path $srcDir $f)) {
                    & git checkout HEAD -- $f 2>&1 | Out-Null
                }
            }
        } finally { Pop-Location }

        Write-Host "  Restored source files from git baseline"
    } finally {
        $ErrorActionPreference = $prevEAP
    }

    # Feature2D stub: empty class def -> forward decl (avoids collision with the real cv::Feature2D
    # from features2d.hpp when both end up in the same translation unit via generated headers).
    foreach ($relPath in @('Emgu.CV.Extern/stitching/stitching_c.h',
                           'Emgu.CV.Extern/xfeatures2d/nonfree_c.h')) {
        $f = Join-Path $srcDir $relPath
        if (Test-Path $f) {
            (Get-Content $f -Raw) -replace 'class Feature2D \{\};', 'class Feature2D;' |
                Set-Content $f -NoNewline
            Write-Host "  Patched Feature2D stub in $relPath"
        }
    }

    # Remove imgcodecs Emgu wrapper (imgcodecs_c_extra.cpp references cv::Animation which only
    # exists in the built imgcodecs module; AgentDVR uses .NET for image I/O anyway).
    $imgcodecsDir = Join-Path $srcDir 'Emgu.CV.Extern/imgcodecs'
    if (Test-Path $imgcodecsDir) {
        Remove-Item -Recurse -Force $imgcodecsDir
        Write-Host "  Removed Emgu.CV.Extern/imgcodecs wrapper subdir"
    }

    # NOTE: We deliberately do NOT neutralize the throw_no_cuda() function on Windows the
    # way the Linux Dockerfiles do. Reasons:
    #
    # 1. MSVC enforces C4716 "must return a value" as a hard error for non-void functions.
    #    The Linux gcc patch (removes CV_NORETURN, makes body a no-op) leaves ~30 non-void
    #    methods in cuda_info.cpp (maxTexture1DLinear, ECCEnabled, pciBusID, etc) without
    #    return statements -- gcc accepts this as a warning, MSVC rejects it as an error.
    #
    # 2. On Windows, .NET's SEH integration handles native C++ exceptions cleanly through
    #    P/Invoke -- the cv::Exception from throw_no_cuda is caught by Emgu's registered
    #    error handler (cveCvErrorHandlerThrowException) and re-raised as a managed
    #    Emgu.CV.Util.CvException, which the calling code can catch with try/catch. Linux
    #    .NET doesn't have SEH, which is why the Linux Dockerfile aggressively neutralizes
    #    these throws -- but that's not a Windows problem.
    #
    # So on Windows: leave Emgu's cuda*/_c.h and OpenCV's private.cuda.hpp untouched. The
    # throws fire normally, get translated to managed CvException, and AgentDVR can catch
    # them. The core_cuda_c.cpp stub (below) still applies cross-platform because that one
    # bypasses CV_Assert -- assertions are not catchable C++ exceptions the same way.

    # Overlay the stub core_cuda_c.cpp. The original calls cv::cuda::DeviceInfo ctor which
    # CV_Asserts when device count is 0 -- that's an assertion, not a throw_no_cuda call, so
    # SEH translation won't catch it. The stub replaces every function with a safe-default
    # returning no-op. See patches/core_cuda_c.cpp.stub for full rationale.
    $stubPath = Join-Path $scriptDir 'patches/core_cuda_c.cpp.stub'
    $coreTarget = Join-Path $srcDir 'Emgu.CV.Extern/core/core_cuda_c.cpp'
    if ((Test-Path $stubPath) -and (Test-Path $coreTarget)) {
        Copy-Item -Force $stubPath $coreTarget
        Write-Host "  Replaced Emgu.CV.Extern/core/core_cuda_c.cpp with safe stub"
    }

    Write-Ok "Patches applied."
}

# ---- Configure -----------------------------------------------------------
Write-Section "cmake configure (VS $VsVersion / x64)"

$generator = if ($VsVersion -eq '2022') { 'Visual Studio 17 2022' } else { 'Visual Studio 16 2019' }
$buildDir = Join-Path $srcDir 'build_win-x64'

# Auto-clean stale build dir in two cases:
#   1. CMakeCache.txt was generated for a different source dir (WorkDir got renamed/copied).
#   2. With Portable=true, the cached BUILD_SHARED_LIBS doesn't match our init-cache target.
#      cmake init-cache files don't override existing cache values, so if the previous run
#      set BUILD_SHARED_LIBS=ON we'd be silently ignored. Detect and wipe.
# In either case the source clone stays — only the cmake build dir gets wiped.
$existingCache = Join-Path $buildDir 'CMakeCache.txt'
$wipeReason = $null
if (Test-Path $existingCache) {
    $cachedHomeMatch = Select-String -Path $existingCache -Pattern '^CMAKE_HOME_DIRECTORY:INTERNAL=(.*)$' | Select-Object -First 1
    if ($cachedHomeMatch) {
        $cachedHomeDir = $cachedHomeMatch.Matches.Groups[1].Value
        $expectedHomeDir = $srcDir -replace '\\','/'
        if ($cachedHomeDir.TrimEnd('/').ToLower() -ne $expectedHomeDir.TrimEnd('/').ToLower()) {
            $wipeReason = "source path changed (cached=$cachedHomeDir, expected=$expectedHomeDir)"
        }
    }
    if (-not $wipeReason -and $Portable) {
        $sharedMatch = Select-String -Path $existingCache -Pattern '^BUILD_SHARED_LIBS:BOOL=(.*)$' | Select-Object -First 1
        if ($sharedMatch -and $sharedMatch.Matches.Groups[1].Value -eq 'ON') {
            $wipeReason = "BUILD_SHARED_LIBS is ON in cached config but portable build needs OFF"
        }
    }
    if (-not $wipeReason -and $Portable) {
        $staticCrtMatch = Select-String -Path $existingCache -Pattern '^BUILD_WITH_STATIC_CRT:BOOL=(.*)$' | Select-Object -First 1
        if ($staticCrtMatch -and $staticCrtMatch.Matches.Groups[1].Value -eq 'ON') {
            $wipeReason = "BUILD_WITH_STATIC_CRT is ON in cached config but portable build needs OFF (CRT mismatch with cvextern)"
        }
    }
}
if ($wipeReason) {
    Write-Warn "Wiping build dir: $wipeReason"
    Write-Warn "Path: $buildDir (source clone preserved)"
    Remove-Item -Recurse -Force $buildDir
}
if (-not (Test-Path $buildDir)) { New-Item -ItemType Directory -Path $buildDir | Out-Null }

# Build args go via a cmake init-cache file rather than -D flags. Reason: PowerShell 5.1
# doesn't quote native command args correctly when a -D value contains a space (which it
# will, since WorkDir is inside this folder and the folder has "opencv build" with a space).
# Init-cache uses cmake's own parser for values, so spaces are fine inside CACHE strings.
$initCacheFile = Join-Path $buildDir 'init-cache.cmake'
$cacheLines = @(
    '# Auto-generated by build-windows.ps1 -- do not edit manually.',
    'set(CMAKE_BUILD_TYPE "Release" CACHE STRING "")',
    # Static link everything into cvextern.dll so the deploy is one DLL, not a swarm of
    # opencv_*.dll files. Matches what Emgu''s Linux build does. Cmake on Windows defaults
    # this to ON for shared libs, so we override.
    'set(BUILD_SHARED_LIBS OFF CACHE BOOL "")',
    # MSVC-specific: with BUILD_SHARED_LIBS=OFF, OpenCV otherwise switches its static libs
    # to /MT (static CRT). Emgu''s cvextern.dll uses /MD (dynamic CRT) by default. Mixing
    # them produces LNK2038 "mismatch detected for RuntimeLibrary". Force OpenCV to also
    # use /MD so the link succeeds. cvextern.dll will depend on msvcp140.dll / vcruntime140.dll
    # at runtime, which is fine -- those are the VC++ Redistributable, present on virtually
    # every modern Windows install.
    'set(BUILD_WITH_STATIC_CRT OFF CACHE BOOL "")',
    'set(BUILD_TESTS OFF CACHE BOOL "")',
    'set(BUILD_PERF_TESTS OFF CACHE BOOL "")',
    'set(BUILD_DOCS OFF CACHE BOOL "")',
    'set(BUILD_opencv_apps OFF CACHE BOOL "")',
    'set(BUILD_opencv_ts OFF CACHE BOOL "")',
    'set(BUILD_opencv_python2 OFF CACHE BOOL "")',
    'set(BUILD_opencv_python3 OFF CACHE BOOL "")',
    'set(BUILD_opencv_java OFF CACHE BOOL "")',
    'set(BUILD_JAVA OFF CACHE BOOL "")',
    'set(CMAKE_POSITION_INDEPENDENT_CODE ON CACHE BOOL "")',
    'set(CMAKE_CXX_STANDARD "17" CACHE STRING "")',
    'set(WITH_EIGEN ON CACHE BOOL "")'
)

if ($Portable) {
    $contribPath = (Join-Path $srcDir 'opencv_contrib/modules') -replace '\\', '/'
    $cacheLines += @(
        '# AgentDVR-minimal portable build flags',
        'set(BUILD_LIST "core,imgproc,calib3d,features2d,flann,video,objdetect,tracking,plot,bgsegm" CACHE STRING "")',
        "set(OPENCV_EXTRA_MODULES_PATH `"$contribPath`" CACHE PATH `"`")",
        'set(WITH_FFMPEG OFF CACHE BOOL "")',
        'set(WITH_GSTREAMER OFF CACHE BOOL "")',
        'set(WITH_V4L OFF CACHE BOOL "")',
        'set(WITH_HDF5 OFF CACHE BOOL "")',
        'set(WITH_VTK OFF CACHE BOOL "")',
        'set(WITH_GDAL OFF CACHE BOOL "")',
        'set(WITH_IPP OFF CACHE BOOL "")',
        'set(WITH_OPENCL OFF CACHE BOOL "")',
        'set(WITH_LAPACK OFF CACHE BOOL "")',
        'set(WITH_TBB OFF CACHE BOOL "")',
        'set(WITH_QUIRC OFF CACHE BOOL "")',
        'set(WITH_ITT OFF CACHE BOOL "")',
        'set(BUILD_IPP_IW OFF CACHE BOOL "")',
        'set(BUILD_ITT OFF CACHE BOOL "")',
        'set(BUILD_opencv_hdf OFF CACHE BOOL "")',
        'set(EMGU_CV_WITH_TIFF FALSE CACHE BOOL "")',
        'set(EMGU_CV_WITH_TESSERACT FALSE CACHE BOOL "")',
        'set(EMGU_CV_WITH_FREETYPE FALSE CACHE BOOL "")',
        'set(BUILD_PNG OFF CACHE BOOL "")',
        'set(BUILD_JPEG OFF CACHE BOOL "")',
        'set(BUILD_TIFF OFF CACHE BOOL "")',
        'set(BUILD_WEBP OFF CACHE BOOL "")',
        'set(BUILD_JASPER OFF CACHE BOOL "")',
        'set(BUILD_OPENEXR OFF CACHE BOOL "")',
        '# Baseline lowered SSE4_2 -> SSE3 so pre-SSE4.2 x86 CPUs (e.g. AMD K10) can run;',
        '# SSSE3/SSE4_1/POPCNT/SSE4_2 moved to dispatch so modern CPUs still pick them at runtime.',
        '# Keep in sync with Dockerfile.x64 (linux-x64) and the SSE3 guard in CoreLogic Threads.StartUp.',
        'set(CPU_BASELINE "SSE3" CACHE STRING "")',
        'set(CPU_DISPATCH "SSSE3;SSE4_1;POPCNT;SSE4_2;AVX;FP16;AVX2;AVX_512F;AVX512_SKX" CACHE STRING "")'
    )
}

Set-Content -Path $initCacheFile -Value $cacheLines -Encoding ASCII
Write-Host "Init cache  -> $initCacheFile"

# Only -G, -A, -C, and the source dir go on the command line. Everything else is in the cache.
$cmakeArgs = @(
    '-G', $generator,
    '-A', 'x64',
    '-C', $initCacheFile,
    $srcDir
)

$configureLog = Join-Path $WorkDir 'cmake-configure.log'
$buildLog     = Join-Path $WorkDir 'cmake-build.log'

# cmake writes warnings (deprecation notices, optional-feature notices) to stderr even on
# successful runs. With $ErrorActionPreference = Stop and 2>&1 merging stderr into stdout,
# PS treats those warnings as terminating errors before cmake even exits. We rely on
# $LASTEXITCODE for the real go/no-go decision, so silence the noise from PS's side.
$prevEAP = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
try {
    Push-Location $buildDir
    try {
        Write-Host "Configure log -> $configureLog"
        & $cmakeExe @cmakeArgs 2>&1 | Tee-Object -FilePath $configureLog
        if ($LASTEXITCODE -ne 0) {
            $ErrorActionPreference = $prevEAP
            Write-Host ""
            Write-Host "=== Last 80 lines of $configureLog ===" -ForegroundColor Yellow
            Get-Content $configureLog -Tail 80 | ForEach-Object { Write-Host $_ }
            Die "cmake configure failed (full log: $configureLog)"
        }
    } finally {
        Pop-Location
    }
}
finally {
    $ErrorActionPreference = $prevEAP
}

# ---- Build ----------------------------------------------------------------
Write-Section "cmake --build (target: cvextern)"

$parallel = if ($Jobs -gt 0) { $Jobs } else { [Environment]::ProcessorCount }
Write-Host "Parallel jobs: $parallel"
Write-Host "Build log     -> $buildLog"

$prevEAP = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
try {
    Push-Location $buildDir
    try {
        & $cmakeExe --build . --config Release --target cvextern --parallel $parallel 2>&1 |
            Tee-Object -FilePath $buildLog
        if ($LASTEXITCODE -ne 0) {
            $ErrorActionPreference = $prevEAP
            Write-Host ""
            Write-Host "=== Last 100 lines of $buildLog (look for 'error C' / 'fatal error') ===" -ForegroundColor Yellow
            Get-Content $buildLog -Tail 100 | ForEach-Object { Write-Host $_ }
            Write-Host ""
            Write-Host "=== Lines containing 'error C' / 'fatal error' / 'LNK' ===" -ForegroundColor Yellow
            Select-String -Path $buildLog -Pattern 'error C[0-9]|fatal error|LNK[0-9]{4}' |
                Select-Object -Last 30 |
                ForEach-Object { Write-Host "  line $($_.LineNumber): $($_.Line.Trim())" }
            Die "cmake build failed (full log: $buildLog)"
        }
    } finally {
        Pop-Location
    }
}
finally {
    $ErrorActionPreference = $prevEAP
}

# ---- Locate + copy output ------------------------------------------------
Write-Section "Locating output cvextern.dll"

$dllSearchPaths = @(
    "$srcDir/libs/runtimes/win-x64/native/cvextern.dll",
    "$srcDir/libs/runtimes/win10-x64/native/cvextern.dll"
)
$dllPath = $null
foreach ($p in $dllSearchPaths) {
    if (Test-Path $p) { $dllPath = (Resolve-Path $p).Path; break }
}
if (-not $dllPath) {
    $dllPath = (Get-ChildItem $srcDir -Recurse -Filter 'cvextern.dll' -ErrorAction SilentlyContinue |
                Sort-Object LastWriteTime -Descending | Select-Object -First 1).FullName
}
if (-not $dllPath -or -not (Test-Path $dllPath)) { Die "cvextern.dll was not produced" }
Write-Host "Found: $dllPath ($([math]::Round((Get-Item $dllPath).Length / 1MB, 2)) MB)"

$winOutDir = Join-Path $OutDir 'win-x64'
if (-not (Test-Path $winOutDir)) { New-Item -ItemType Directory -Force -Path $winOutDir | Out-Null }
Copy-Item -Force $dllPath (Join-Path $winOutDir 'cvextern.dll')

# Look for libusb-1.0.dll (only present if depthai or libusb-dependent module was built; with
# the minimal portable set, it usually isn't -- but if cvextern.dll ldd'd against libusb, copy it).
$libusbCandidates = Get-ChildItem $srcDir -Recurse -Filter 'libusb-1.0.dll' -ErrorAction SilentlyContinue
if ($libusbCandidates) {
    Copy-Item -Force $libusbCandidates[0].FullName (Join-Path $winOutDir 'libusb-1.0.dll')
    Write-Host "Also copied libusb-1.0.dll from $($libusbCandidates[0].FullName)"
}

# ---- Verify --------------------------------------------------------------
Write-Section "Verify (size + exports check)"
$finalDll = Join-Path $winOutDir 'cvextern.dll'
$sizeMB = [math]::Round((Get-Item $finalDll).Length / 1MB, 2)
Write-Host "cvextern.dll size: $sizeMB MB"

# Optional: dumpbin /exports check if dumpbin is on PATH (it is when run from a VS dev prompt)
if (Get-Command dumpbin -ErrorAction SilentlyContinue) {
    $exports = & dumpbin /exports $finalDll 2>$null | Select-String 'CvInvoke|cve[A-Z]' | Measure-Object
    Write-Host "Exported symbols matching cve* / CvInvoke*: $($exports.Count)"
}

# ---- Zip -----------------------------------------------------------------
if (-not $SkipZip) {
    Write-Section "Packaging win-x64.zip"
    $zipPath = Join-Path $OutDir 'win-x64.zip'
    if (Test-Path $zipPath) { Remove-Item -Force $zipPath }
    Compress-Archive -Path (Join-Path $winOutDir '*') -DestinationPath $zipPath
    Write-Ok ("Created {0} ({1:N1} MB)" -f $zipPath, ((Get-Item $zipPath).Length / 1MB))
}

Write-Section "Done"
Write-Host "Upload $((Resolve-Path (Join-Path $OutDir 'win-x64.zip') -ErrorAction SilentlyContinue).Path) to https://files.ispyconnect.com/libs/opencv/$EmguTag.5764/ and bump OpenCvVersion in Dependencies.cs."
