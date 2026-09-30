<#
.SYNOPSIS
    Builds dist\PingAlert.zip - the distributable package for your techs.

.DESCRIPTION
    Zips PingAlert.ps1, PingAlert.cmd, PingAlert.defaults.json, README.md and LICENSE.
    Use -Defaults to bake a site-specific defaults file into the zip without
    editing the one in the repo (e.g. keep your real SMTP server in a file
    outside the repo):

        .\Make-Package.ps1 -Defaults C:\Work\mysite.defaults.json
#>
param(
    [string]$Defaults,
    [string]$Output = (Join-Path $PSScriptRoot "dist\PingAlert.zip")
)

$files = "PingAlert.ps1", "PingAlert.cmd", "README.md", "LICENSE"
$defaultsSource = if ($Defaults) { $Defaults } else { Join-Path $PSScriptRoot "PingAlert.defaults.json" }
if (-not (Test-Path $defaultsSource)) { throw "Defaults file not found: $defaultsSource" }
try { Get-Content $defaultsSource -Raw | ConvertFrom-Json | Out-Null } catch { throw "Defaults file is not valid JSON: $($_.Exception.Message)" }

$stage = Join-Path ([IO.Path]::GetTempPath()) ("PingAlert_" + [guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $stage | Out-Null
try {
    foreach ($f in $files) { Copy-Item (Join-Path $PSScriptRoot $f) $stage }
    Copy-Item $defaultsSource (Join-Path $stage "PingAlert.defaults.json")

    New-Item -ItemType Directory -Path (Split-Path $Output) -Force | Out-Null
    if (Test-Path $Output) { Remove-Item $Output -Force }
    Compress-Archive -Path (Join-Path $stage "*") -DestinationPath $Output
    Write-Host "Created $Output"
} finally {
    Remove-Item $stage -Recurse -Force -ErrorAction SilentlyContinue
}
