# build.ps1 — Build libcvextern.so for linux-x64, linux-arm64, and linux-arm via Docker.
# Outputs:
#   ./out/linux-x64/libcvextern.so
#   ./out/linux-arm64/libcvextern.so
#   ./out/linux-arm/libcvextern.so
#
# Usage:
#   .\build.ps1                       # prints usage
#   .\build.ps1 -Arch x64             # x64 only
#   .\build.ps1 -Arch arm64           # arm64 only (slow via QEMU)
#   .\build.ps1 -Arch armhf           # 32-bit ARM / armv7 (slow via QEMU)
#   .\build.ps1 -Arch all             # x64 + arm64 + armhf
#   .\build.ps1 -EmguTag 4.12.0       # override the emgucv git tag
#   .\build.ps1 -BuildType core       # override Emgu's build profile (full|core|mini)

[CmdletBinding()]
param(
    [ValidateSet('both','x64','arm64','armhf','all')]
    [string]$Arch = '',

    [string]$EmguTag = '4.12.0',

    [ValidateSet('full','core','mini')]
    [string]$BuildType = 'full',

    [int]$Jobs = 0,

    [switch]$Portable = $true,

    [string]$OutDir = './out'
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

if (-not $Arch) {
    Write-Host ""
    Write-Host "Usage:  .\build.ps1 -Arch <target> [options]" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "Targets (-Arch):"
    Write-Host "  x64     linux-x64   (Debian Buster, glibc 2.28)  ~20-35 min"
    Write-Host "  arm64   linux-arm64 (Debian Buster, glibc 2.28)  ~2-6 h via QEMU"
    Write-Host "  armhf   linux-arm   (Debian Buster, glibc 2.28)  ~3-8 h via QEMU"
    Write-Host "  both    x64 + arm64"
    Write-Host "  all     x64 + arm64 + armhf"
    Write-Host ""
    Write-Host "Options:"
    Write-Host "  -EmguTag   <tag>          Emgu CV git tag           (default: 4.12.0)"
    Write-Host "  -BuildType full|core|mini Emgu build profile        (default: full)"
    Write-Host "  -Jobs      <n>            Parallel make jobs        (default: all cores)"
    Write-Host "  -Portable                 AgentDVR-minimal patches  (default: on)"
    Write-Host "  -OutDir    <path>         Output directory          (default: ./out)"
    Write-Host ""
    Write-Host "Examples:"
    Write-Host "  .\build.ps1 -Arch x64"
    Write-Host "  .\build.ps1 -Arch all -EmguTag 4.12.0"
    Write-Host "  .\build.ps1 -Arch arm64 -Jobs 8"
    Write-Host ""
    exit 0
}

function Write-Section($msg) {
    Write-Host ""
    Write-Host "==> $msg" -ForegroundColor Cyan
}

function Assert-Cmd($cmd, $help) {
    if (-not (Get-Command $cmd -ErrorAction SilentlyContinue)) {
        throw "Required command '$cmd' not found. $help"
    }
}

# ---- Preflight ----
Assert-Cmd 'docker' 'Install Docker Desktop from https://www.docker.com/products/docker-desktop'

$dockerVersion = docker version --format '{{.Server.Version}}' 2>$null
if (-not $dockerVersion) {
    throw "Docker daemon is not running. Start Docker Desktop and try again."
}
Write-Host "Docker server version: $dockerVersion"

# buildx is bundled with modern Docker Desktop
$null = docker buildx version 2>$null
if ($LASTEXITCODE -ne 0) {
    throw "docker buildx is not available. Update Docker Desktop or install the buildx plugin."
}

# Resolve script directory so the build works from any CWD
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition
Push-Location $scriptDir
try {
    $absOut = (Resolve-Path -LiteralPath $OutDir -ErrorAction SilentlyContinue)
    if (-not $absOut) {
        New-Item -ItemType Directory -Path $OutDir | Out-Null
        $absOut = (Resolve-Path -LiteralPath $OutDir).Path
    } else {
        $absOut = $absOut.Path
    }
    Write-Host "Output directory: $absOut"

    $buildArgs = @(
        '--build-arg', "EMGU_TAG=$EmguTag",
        '--build-arg', "BUILD_TYPE=$BuildType",
        '--build-arg', ("PORTABLE=" + ($(if ($Portable) { 1 } else { 0 })))
    )
    if ($Jobs -gt 0) {
        $buildArgs += @('--build-arg', "JOBS=$Jobs")
    }

    # ---- Build x64 ----
    if ($Arch -in @('both','x64','all')) {
        Write-Section "Building linux-x64 (Debian Buster base, glibc 2.28 target)"
        $x64Out = Join-Path $absOut 'linux-x64'
        New-Item -ItemType Directory -Force -Path $x64Out | Out-Null

        docker buildx build `
            --platform linux/amd64 `
            -f Dockerfile.x64 `
            @buildArgs `
            --output "type=local,dest=$x64Out" `
            .
        if ($LASTEXITCODE -ne 0) { throw "x64 build failed." }

        $soPath = Join-Path $x64Out 'libcvextern.so'
        if (-not (Test-Path $soPath)) { throw "Expected $soPath was not produced." }
        Write-Host "linux-x64 build OK: $soPath ($([math]::Round((Get-Item $soPath).Length / 1MB, 1)) MB)" -ForegroundColor Green
    }

    # ---- Build arm64 ----
    if ($Arch -in @('both','arm64','all')) {
        Write-Section "Building linux-arm64 (Debian Buster base, glibc 2.28 target)"
        Write-Host "NOTE: arm64 via QEMU emulation typically takes 2-6 hours." -ForegroundColor Yellow

        # Ensure QEMU binfmt is installed for emulating arm64 on this host
        Write-Host "Installing QEMU binfmt handlers for arm64 (no-op if already present)..."
        docker run --privileged --rm tonistiigi/binfmt --install arm64 | Out-Null
        if ($LASTEXITCODE -ne 0) {
            Write-Warning "binfmt install returned non-zero. If you're already on arm64 hardware this is fine."
        }

        # Ensure a buildx builder exists
        $builderName = 'emgucv-builder'
        $existing = docker buildx ls | Select-String -Pattern $builderName -Quiet
        if (-not $existing) {
            docker buildx create --name $builderName --use | Out-Null
        } else {
            docker buildx use $builderName | Out-Null
        }
        docker buildx inspect --bootstrap | Out-Null

        $armOut = Join-Path $absOut 'linux-arm64'
        New-Item -ItemType Directory -Force -Path $armOut | Out-Null

        docker buildx build `
            --platform linux/arm64 `
            -f Dockerfile.arm64 `
            @buildArgs `
            --output "type=local,dest=$armOut" `
            .
        if ($LASTEXITCODE -ne 0) { throw "arm64 build failed." }

        $soPath = Join-Path $armOut 'libcvextern.so'
        if (-not (Test-Path $soPath)) { throw "Expected $soPath was not produced." }
        Write-Host "linux-arm64 build OK: $soPath ($([math]::Round((Get-Item $soPath).Length / 1MB, 1)) MB)" -ForegroundColor Green
    }

    # ---- Build armhf ----
    if ($Arch -in @('armhf','all')) {
        Write-Section "Building linux-arm (armv7/armhf, Debian Buster base, glibc 2.28 target)"
        Write-Host "NOTE: armhf via QEMU emulation typically takes 3-8 hours." -ForegroundColor Yellow

        Write-Host "Installing QEMU binfmt handlers for arm (no-op if already present)..."
        docker run --privileged --rm tonistiigi/binfmt --install arm | Out-Null
        if ($LASTEXITCODE -ne 0) {
            Write-Warning "binfmt install returned non-zero. If you're already on arm hardware this is fine."
        }

        $builderName = 'emgucv-builder'
        $existing = docker buildx ls | Select-String -Pattern $builderName -Quiet
        if (-not $existing) {
            docker buildx create --name $builderName --use | Out-Null
        } else {
            docker buildx use $builderName | Out-Null
        }
        docker buildx inspect --bootstrap | Out-Null

        $armhfOut = Join-Path $absOut 'linux-arm'
        New-Item -ItemType Directory -Force -Path $armhfOut | Out-Null

        docker buildx build `
            --platform linux/arm/v7 `
            -f Dockerfile.armhf `
            @buildArgs `
            --output "type=local,dest=$armhfOut" `
            .
        if ($LASTEXITCODE -ne 0) { throw "armhf build failed." }

        $soPath = Join-Path $armhfOut 'libcvextern.so'
        if (-not (Test-Path $soPath)) { throw "Expected $soPath was not produced." }
        Write-Host "linux-arm build OK: $soPath ($([math]::Round((Get-Item $soPath).Length / 1MB, 1)) MB)" -ForegroundColor Green
    }

    Write-Section "Done"
}
finally {
    Pop-Location
}
