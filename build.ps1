# build.ps1 — Build libcvextern.so for linux-x64 and linux-arm64 via Docker.
# Outputs:
#   ./out/linux-x64/libcvextern.so
#   ./out/linux-arm64/libcvextern.so
#   ./out/linux-x64.zip
#   ./out/linux-arm64.zip
#
# Usage:
#   .\build.ps1                       # builds both x64 and arm64
#   .\build.ps1 -Arch x64             # x64 only
#   .\build.ps1 -Arch arm64           # arm64 only (slow via QEMU)
#   .\build.ps1 -EmguTag 4.12.0       # override the emgucv git tag
#   .\build.ps1 -BuildType core       # override Emgu's build profile (full|core|mini)
#   .\build.ps1 -SkipZip              # skip producing the .zip files

[CmdletBinding()]
param(
    [ValidateSet('both','x64','arm64')]
    [string]$Arch = 'both',

    [string]$EmguTag = '4.12.0',

    [ValidateSet('full','core','mini')]
    [string]$BuildType = 'full',

    [int]$Jobs = 0,

    [switch]$SkipZip,

    [switch]$Portable = $true,

    [string]$OutDir = './out'
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

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
    if ($Arch -in @('both','x64')) {
        Write-Section "Building linux-x64 (Ubuntu 20.04 base, glibc 2.31 target)"
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
    if ($Arch -in @('both','arm64')) {
        Write-Section "Building linux-arm64 (Debian 11 base, glibc 2.31 target)"
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

    # ---- Package ----
    if (-not $SkipZip) {
        Write-Section "Packaging CDN zips"
        foreach ($a in @('x64','arm64')) {
            if ($Arch -ne 'both' -and $Arch -ne $a) { continue }
            $dir = Join-Path $absOut "linux-$a"
            $zip = Join-Path $absOut "linux-$a.zip"
            if (-not (Test-Path (Join-Path $dir 'libcvextern.so'))) { continue }
            if (Test-Path $zip) { Remove-Item -Force $zip }
            Compress-Archive -Path (Join-Path $dir 'libcvextern.so') -DestinationPath $zip
            Write-Host ("Created {0} ({1:N1} MB)" -f $zip, ((Get-Item $zip).Length / 1MB)) -ForegroundColor Green
        }
    }

    Write-Section "Done"
    Write-Host "Upload the .zip files to https://files.ispyconnect.com/libs/opencv/$EmguTag.5764/ and bump OpenCvVersion in Dependencies.cs."
}
finally {
    Pop-Location
}
