# Copy the mod into Factorio's mods folder.
#
# A directory junction would be tidier, since the game would then read the
# working copy directly. It does not work here: a junction pointing at another
# drive listed its entries but every file inside it failed to open, so the game
# would have found the mod and been unable to read a line of it. Copying is
# dull and works.
#
# Run again after any change; nothing else picks edits up.

$ErrorActionPreference = "Stop"

$source = Split-Path -Parent $PSScriptRoot
$name = (Get-Content (Join-Path $source "info.json") -Raw | ConvertFrom-Json).name

$modsDir = if ($env:FACTORIO_USER_DIR) {
    Join-Path $env:FACTORIO_USER_DIR "mods"
} else {
    Join-Path $env:APPDATA "Factorio\mods"
}

if (-not (Test-Path $modsDir)) {
    throw "No Factorio mods folder at $modsDir. Set FACTORIO_USER_DIR if yours is elsewhere."
}

$target = Join-Path $modsDir $name
if (Test-Path $target) {
    # Delete without following, in case a previous attempt left a junction.
    try { [System.IO.Directory]::Delete($target, $false) } catch { Remove-Item $target -Recurse -Force }
}
New-Item -ItemType Directory -Force -Path $target | Out-Null

foreach ($file in @("info.json", "control.lua", "circuit.lua")) {
    Copy-Item (Join-Path $source $file) (Join-Path $target $file) -Force
}
Copy-Item (Join-Path $source "locale") (Join-Path $target "locale") -Recurse -Force

Write-Host "Installed $name to $target"

# Make sure it is switched on, otherwise the game loads it and does nothing.
$listPath = Join-Path $modsDir "mod-list.json"
if (Test-Path $listPath) {
    $list = Get-Content $listPath -Raw | ConvertFrom-Json
    $entry = $list.mods | Where-Object { $_.name -eq $name }
    if ($entry) {
        $entry.enabled = $true
    } else {
        $list.mods += [PSCustomObject]@{ name = $name; enabled = $true }
    }
    ($list | ConvertTo-Json -Depth 5) | Set-Content $listPath -Encoding utf8
    Write-Host "Enabled in mod-list.json"
}

Write-Host "Restart Factorio, or reload the save, to pick this up."
