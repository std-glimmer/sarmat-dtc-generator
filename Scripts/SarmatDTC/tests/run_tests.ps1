# Runs SarmatDTC offline tests with DCS's own Lua interpreter (bin\luae.exe, Lua 5.1).
# usage: powershell -ExecutionPolicy Bypass -File Scripts\SarmatDTC\tests\run_tests.ps1 [-DcsDir <DCS install>] [-OutDir <dir>] [-UpdateExpected]
# DCS install: -DcsDir, else env DCS_DIR, else the path the DCS installer stores in the registry.
param(
    [string]$DcsDir = "",
    [string]$OutDir = "",
    [switch]$UpdateExpected       # record tests\fixtures\expected\*.lua after an intended output change
)
$env:SDTC_UPDATE_EXPECTED = if ($UpdateExpected) { "1" } else { "" }
$ErrorActionPreference = "Stop"
if (-not $DcsDir) { $DcsDir = $env:DCS_DIR }
if (-not $DcsDir) {
    foreach ($key in "HKCU:\Software\Eagle Dynamics\DCS World OpenBeta", "HKCU:\Software\Eagle Dynamics\DCS World") {
        $p = (Get-ItemProperty $key -ErrorAction SilentlyContinue).Path
        if ($p) { $DcsDir = $p; break }
    }
}
$scriptDir = Split-Path -Parent $PSScriptRoot          # ...\Scripts\SarmatDTC
$luae = Join-Path $DcsDir "bin\luae.exe"
if (-not $DcsDir -or -not (Test-Path $luae)) { throw "luae.exe not found in '$DcsDir' (pass -DcsDir or set DCS_DIR)" }
$failed = 0

# luae resolves Scripts\JSON.lua relative to the DCS install, like the game does
Push-Location $DcsDir
try {
    Write-Host "== core"
    $coreArgs = @("$PSScriptRoot\test_core.lua", $DcsDir, $scriptDir)
    if ($OutDir) { New-Item -ItemType Directory -Force $OutDir | Out-Null; $coreArgs += $OutDir }
    & $luae @coreArgs
    if ($LASTEXITCODE -ne 0) { $failed++ }

    Write-Host "== hook"
    # fake Saved Games folder on a short path (os.execute command length limit)
    $sim = Join-Path $env:TEMP ("sdtc" + (Get-Random -Maximum 99999))
    New-Item -ItemType Directory -Force "$sim\Scripts\SarmatDTC\aircraft", "$sim\srv" | Out-Null
    Get-ChildItem $scriptDir -File | Where-Object Name -ne "config.user.lua" | Copy-Item -Destination "$sim\Scripts\SarmatDTC\"
    Get-ChildItem "$scriptDir\aircraft" -File | Copy-Item -Destination "$sim\Scripts\SarmatDTC\aircraft\"
    Copy-Item "$PSScriptRoot\fixtures\*.json" "$sim\srv\"
    $base = "file:///" + (($sim -replace '\\', '/') -replace ' ', '%20') + "/srv/"
    & $luae "$PSScriptRoot\test_hook.lua" $sim $base
    if ($LASTEXITCODE -ne 0) { $failed++ }
    Remove-Item -LiteralPath $sim -Recurse -Force
}
finally {
    Pop-Location
}

if ($failed) { Write-Host "FAILED: $failed suite(s)"; exit 1 }
Write-Host "ALL TESTS PASSED"
