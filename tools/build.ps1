# Package the mod as a zip Factorio can install.
#
# Factorio expects a single folder inside the archive, named `<mod>_<version>`,
# holding info.json at its root. Getting that wrapper wrong is the usual reason
# a hand-made mod zip refuses to load, so it is built here rather than left to
# whoever is zipping.
#
# Nothing is installed. The archive lands in dist/ and goes wherever you put it.

$ErrorActionPreference = "Stop"

$source = Split-Path -Parent $PSScriptRoot
$info = Get-Content (Join-Path $source "info.json") -Raw | ConvertFrom-Json
$folder = "$($info.name)_$($info.version)"

$dist = Join-Path $source "dist"
$archive = Join-Path $dist "$folder.zip"

if (Test-Path $archive) { Remove-Item $archive -Force }
New-Item -ItemType Directory -Force -Path $dist | Out-Null

# Only what the game reads. The repository's own files -- git config, this
# script -- have no business inside a mod.
$contents = @(
    "info.json",
    "control.lua",
    "data.lua",
    "gui.lua",
    "settings.lua",
    "circuit.lua",
    "constants.lua",
    "scratch.lua",
    "LICENSE",
    "locale/en/strings.cfg",
    "locale/ru/strings.cfg"
)

# Entries are written one at a time rather than with Compress-Archive, which on
# Windows PowerShell puts backslashes in the entry names. The zip format calls
# for forward slashes, and a mod archive with the wrong separator is read as a
# single file with an odd name rather than as a folder, so the game does not
# find info.json and refuses the mod.
Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem

$stream = [System.IO.File]::Open($archive, [System.IO.FileMode]::CreateNew)
try {
    $zip = New-Object System.IO.Compression.ZipArchive(
        $stream, [System.IO.Compression.ZipArchiveMode]::Create)
    try {
        foreach ($relative in $contents) {
            $full = Join-Path $source ($relative -replace '/', [System.IO.Path]::DirectorySeparatorChar)
            if (-not (Test-Path $full)) { throw "Missing $relative" }
            $entry = $zip.CreateEntry(
                "$folder/$relative", [System.IO.Compression.CompressionLevel]::Optimal)
            $target = $entry.Open()
            try {
                $bytes = [System.IO.File]::ReadAllBytes($full)
                $target.Write($bytes, 0, $bytes.Length)
            } finally { $target.Dispose() }
        }
    } finally { $zip.Dispose() }
} finally { $stream.Dispose() }

$size = [math]::Round((Get-Item $archive).Length / 1KB, 1)
Write-Host "Built $folder.zip ($size KB)"
Write-Host "  $archive"
Write-Host ""
Write-Host "Install it by copying that file into your Factorio mods folder,"
Write-Host "then enabling the mod in the in-game mod list."
