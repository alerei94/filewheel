# Builds FileWheel and puts the result in .\dist\FileWheel.exe
#
#   .\build.ps1                    small exe, needs the .NET 8 Desktop Runtime on the PC
#   .\build.ps1 -SelfContained     bigger exe (about 70 MB), runs on any Windows 10/11 PC
#   .\build.ps1 -Arch arm64        build for ARM PCs (default: x64)
#
# Requirements: Windows 10/11 and the .NET 8 SDK:  winget install Microsoft.DotNet.SDK.8
param(
    [switch]$SelfContained,
    [ValidateSet("x64", "arm64")]
    [string]$Arch = "x64"
)

$ErrorActionPreference = "Stop"
Set-Location $PSScriptRoot

if (-not (Get-Command dotnet -ErrorAction SilentlyContinue)) {
    Write-Host ".NET SDK not found. Install it with: winget install Microsoft.DotNet.SDK.8"
    exit 1
}

$sc = if ($SelfContained) { "true" } else { "false" }
Write-Host "Building FileWheel for win-$Arch (self-contained: $sc) ..."

if (Test-Path .\dist) { Remove-Item .\dist -Recurse -Force }
dotnet publish .\FileWheel.csproj -c Release -r "win-$Arch" --self-contained $sc `
    -p:PublishSingleFile=true -p:DebugType=none -p:DebugSymbols=false -o .\dist
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

Write-Host ""
Write-Host "Done: $(Join-Path $PSScriptRoot 'dist\FileWheel.exe')"
Write-Host "Launch it with: .\dist\FileWheel.exe   (it lives in the system tray, with no window)"
