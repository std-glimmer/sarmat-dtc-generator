# Runs SarmatDTC offline tests with DCS's own Lua interpreter (bin\luae.exe, Lua 5.1).
# usage: powershell -ExecutionPolicy Bypass -File Scripts\SarmatDTC\tests\run_tests.ps1 [-DcsDir <DCS install>] [-OutDir <dir>]
param(
    [string]$DcsDir = "G:\Program Files\Eagle Dynamics\DCS World OpenBeta",
    [string]$OutDir = ""
)
$ErrorActionPreference = "Stop"
$scriptDir = Split-Path -Parent $PSScriptRoot          # ...\Scripts\SarmatDTC
$luae = Join-Path $DcsDir "bin\luae.exe"
if (-not (Test-Path $luae)) { throw "luae.exe not found: $luae (pass -DcsDir)" }
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
    New-Item -ItemType Directory -Force "$sim\Scripts\SarmatDTC", "$sim\srv" | Out-Null
    Get-ChildItem $scriptDir -File | Copy-Item -Destination "$sim\Scripts\SarmatDTC\"
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
