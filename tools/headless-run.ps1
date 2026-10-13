# Run Factorio without a window, on a copy of a save, and collect what the
# companion mod writes.
#
#   headless-run.ps1 -Save Vulkan-Start.zip -Out out [-Blueprint line.txt]
#
# What it does, in order:
#   1. refuses to start if Factorio is already running;
#   2. builds a throwaway folder (config.ini, server-settings.json, a copy of the
#      save, a copy of ONLY the enabled mods, the settings file) -- the game
#      is told to use that folder for everything it writes;
#   3. starts `factorio --start-server` on the copy, bound to 127.0.0.1;
#   4. waits until the world is up, types `/forge-export` (and `/forge-verify`
#      when a blueprint is given) into the server's console, and waits for the
#      result files;
#   5. copies them to -Out, asks the server to quit, and kills it if it does not;
#   6. checks that the real save, mod list and mod settings did not change.
#
# Nothing is written into the game's install folder or its real data folder, and
# nothing is downloaded or installed. The commands go in through the server's
# standard input, not through RCON, so no password exists and the only network
# port is a random one on the loopback address.

[CmdletBinding()]
param(
    # The save to run on. A bare name is looked up in the data folder's saves/.
    [Parameter(Mandatory = $true)] [string] $Save,
    # Where the result files are copied to.
    [Parameter(Mandatory = $true)] [string] $Out,
    # A file holding one blueprint string; when given, /forge-verify is run on it.
    [string] $Blueprint,
    # The game's real data folder (saves, mods, mod-list.json live there).
    [string] $DataDir = (Join-Path $env:APPDATA "Factorio"),
    # factorio.exe; found in the usual Steam places when not given.
    [string] $Factorio,
    # Use this build of the companion mod instead of the one in the mods folder.
    [string] $ModZip,
    [int] $TimeoutSec = 300,
    # Leave the throwaway folder in place (for looking at the game's own log).
    [switch] $KeepTemp
)

$ErrorActionPreference = "Stop"
$ModName = "factorio-forge-companion"

function Find-Factorio {
    if ($Factorio) { return $Factorio }
    $roots = @(${env:ProgramFiles(x86)}, $env:ProgramFiles, "D:\Program Files (x86)", "C:\Program Files (x86)") |
        Where-Object { $_ } | Select-Object -Unique
    foreach ($root in $roots) {
        $candidate = Join-Path $root "Steam\steamapps\common\Factorio\bin\x64\factorio.exe"
        if (Test-Path $candidate) { return $candidate }
    }
    throw "factorio.exe not found; pass -Factorio <path>."
}

function Get-Fingerprint([string] $data) {
    # What must come out of the run exactly as it went in: the save files, the
    # mod list, the mod settings, and the shape of the mods folder.
    $lines = @()
    $paths = @("mods\mod-list.json", "mods\mod-settings.dat")
    foreach ($p in $paths) {
        $full = Join-Path $data $p
        if (Test-Path $full) { $lines += "$p " + (Get-FileHash $full -Algorithm SHA256).Hash }
    }
    foreach ($f in Get-ChildItem (Join-Path $data "saves") -File) {
        $lines += "saves\$($f.Name) $($f.Length) " + (Get-FileHash $f.FullName -Algorithm SHA256).Hash
    }
    foreach ($f in Get-ChildItem (Join-Path $data "mods") -File) {
        $lines += "mods\$($f.Name) $($f.Length) $($f.LastWriteTimeUtc.Ticks)"
    }
    return ($lines | Sort-Object) -join "`n"
}

function Wait-ForFile([string] $path, [datetime] $deadline) {
    # Present, non-empty and not growing any more.
    $last = -1
    while ((Get-Date) -lt $deadline) {
        if (Test-Path $path) {
            $size = (Get-Item $path).Length
            if ($size -gt 0 -and $size -eq $last) { return $true }
            $last = $size
        }
        Start-Sleep -Milliseconds 700
    }
    return $false
}

# A minimal client for the game's RCON (the Source RCON wire format): length,
# request id, type, body, two zero bytes. Type 3 logs in, type 2 runs a command.
$script:rcon = $null

function Send-Rcon([int] $type, [string] $body) {
    $payload = (New-Object Text.UTF8Encoding($false)).GetBytes($body)
    $id = 7
    $length = 10 + $payload.Length
    $buffer = New-Object byte[] (4 + $length)
    [BitConverter]::GetBytes([int]$length).CopyTo($buffer, 0)
    [BitConverter]::GetBytes([int]$id).CopyTo($buffer, 4)
    [BitConverter]::GetBytes([int]$type).CopyTo($buffer, 8)
    $payload.CopyTo($buffer, 12)
    $stream = $script:rcon.GetStream()
    $stream.Write($buffer, 0, $buffer.Length)
    $stream.Flush()
}

function Read-Exactly([IO.Stream] $stream, [int] $count) {
    $buffer = New-Object byte[] $count
    $got = 0
    while ($got -lt $count) {
        $n = $stream.Read($buffer, $got, $count - $got)
        if ($n -le 0) { throw "RCON connection closed" }
        $got += $n
    }
    return $buffer
}

function Read-Rcon {
    $stream = $script:rcon.GetStream()
    $head = Read-Exactly $stream 4
    $length = [BitConverter]::ToInt32($head, 0)
    $rest = Read-Exactly $stream $length
    return [pscustomobject]@{
        Id   = [BitConverter]::ToInt32($rest, 0)
        Type = [BitConverter]::ToInt32($rest, 4)
        Body = [Text.Encoding]::UTF8.GetString($rest, 8, $length - 10)
    }
}

function Connect-Rcon([int] $port, [string] $password, [datetime] $deadline) {
    while ($true) {
        try {
            $client = New-Object Net.Sockets.TcpClient
            $client.Connect("127.0.0.1", $port)
            break
        }
        catch {
            if ((Get-Date) -gt $deadline) { throw "RCON never accepted a connection" }
            Start-Sleep -Milliseconds 500
        }
    }
    $client.ReceiveTimeout = 120000
    $script:rcon = $client
    Send-Rcon 3 $password
    $reply = Read-Rcon
    # Some servers answer a login with an empty packet first, then the verdict.
    if ($reply.Type -ne 2 -or $reply.Id -eq -1) { $reply = if ($reply.Id -eq -1) { $reply } else { Read-Rcon } }
    if ($reply.Id -eq -1) { throw "RCON login refused" }
}

# Run a console command. The answer to it, if any, comes back as text.
function Invoke-Console([string] $line) {
    Send-Rcon 2 $line
    return (Read-Rcon).Body
}

if (Get-Process factorio -ErrorAction SilentlyContinue) {
    Write-Error "Factorio is already running; not starting anything. Close it and try again."
    exit 2
}

$exe = Find-Factorio
if (-not (Test-Path $exe)) { throw "factorio.exe not found at $exe" }

if (-not (Test-Path $Save)) { $Save = Join-Path (Join-Path $DataDir "saves") $Save }
if (-not (Test-Path $Save)) { throw "Save not found: $Save" }

$realMods = Join-Path $DataDir "mods"
$before = Get-Fingerprint $DataDir

$work = Join-Path ([IO.Path]::GetTempPath()) ("forge-headless-" + [guid]::NewGuid().ToString("N").Substring(0, 8))
$proc = $null
$ok = $false
$timer = [Diagnostics.Stopwatch]::StartNew()

try {
    New-Item -ItemType Directory -Force -Path $work, "$work\mods", "$work\saves", $Out | Out-Null

    # Only the enabled mods are copied: the whole folder can be gigabytes of
    # graphics packs this run never loads.
    $list = Get-Content (Join-Path $realMods "mod-list.json") -Raw -Encoding UTF8 | ConvertFrom-Json
    $enabled = @($list.mods | Where-Object { $_.enabled } | ForEach-Object { $_.name })
    $copied = 0
    foreach ($file in Get-ChildItem $realMods -File -Filter *.zip) {
        if ($file.Name -match '^(.+?)_\d+\.\d+\.\d+\.zip$' -and $enabled -contains $Matches[1]) {
            if ($ModZip -and $Matches[1] -eq $ModName) { continue }
            Copy-Item $file.FullName "$work\mods\" ; $copied++
        }
    }
    # Unpacked mods (folders) are rare; copy the enabled ones the same way.
    foreach ($dir in Get-ChildItem $realMods -Directory) {
        $name = $dir.Name -replace '_\d+\.\d+\.\d+$', ''
        if ($enabled -contains $name) { Copy-Item $dir.FullName "$work\mods\$($dir.Name)" -Recurse; $copied++ }
    }
    if ($ModZip) { Copy-Item $ModZip "$work\mods\" ; $copied++ }
    Copy-Item (Join-Path $realMods "mod-list.json") "$work\mods\"
    $settingsFile = Join-Path $realMods "mod-settings.dat"
    if (Test-Path $settingsFile) { Copy-Item $settingsFile "$work\mods\" }

    $saveCopy = Join-Path "$work\saves" "run.zip"
    Copy-Item $Save $saveCopy

    $port = Get-Random -Minimum 20000 -Maximum 40000
    $rconPort = Get-Random -Minimum 40001 -Maximum 60000
    # A password for this run only: never printed, never stored anywhere but
    # the command line of the one process that needs it.
    $rng = New-Object Security.Cryptography.RNGCryptoServiceProvider
    $raw = New-Object byte[] 24
    $rng.GetBytes($raw)
    $password = [Convert]::ToBase64String($raw) -replace '[^A-Za-z0-9]', 'x'
    $fwd = $work -replace '\\', '/'
    # read-data is the install's own data folder; write-data is the throwaway one.
    Set-Content -Path "$work\config.ini" -Encoding ASCII -Value @(
        "[path]", "read-data=__PATH__system-read-data__", "write-data=$fwd", "[general]", "locale=auto")
    # Nobody should be able to find this server, and it must not pause the game
    # while nobody is connected -- a paused game does not run commands.
    # The game insists on every key being present, so start from the example it
    # ships with (read only) and change what matters.
    $example = Join-Path (Split-Path (Split-Path (Split-Path $exe))) "data\server-settings.example.json"
    $settings = Get-Content $example -Raw -Encoding UTF8 | ConvertFrom-Json
    $settings.name = "forge-headless"
    $settings.visibility.public = $false
    $settings.visibility.lan = $false
    $settings.require_user_verification = $false
    $settings.auto_pause = $false
    $settings.autosave_interval = 0
    $settings.max_players = 1
    $settings | ConvertTo-Json -Depth 10 | Set-Content -Path "$work\server-settings.json" -Encoding ASCII

    $log = "$work\factorio-current.log"
    $arguments = "--config `"$work\config.ini`" --mod-directory `"$work\mods`" " +
        "--start-server `"$saveCopy`" --server-settings `"$work\server-settings.json`" " +
        "--bind 127.0.0.1 --port $port --rcon-bind 127.0.0.1:$rconPort --rcon-password $password"
    # The game's console output goes to files, not pipes: its own log has all of
    # it, and a pipe nobody reads is a way for a server to hang.
    $proc = Start-Process -FilePath $exe -ArgumentList $arguments -WindowStyle Hidden -PassThru `
        -RedirectStandardOutput "$work\stdout.txt" -RedirectStandardError "$work\stderr.txt"
    $null = $proc.Handle   # keeps the exit code readable after the process is gone
    Write-Host "started factorio pid $($proc.Id), $copied mods, game port 127.0.0.1:$port, rcon 127.0.0.1:$rconPort, temp $work"

    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    $up = $false
    while ((Get-Date) -lt $deadline -and -not $proc.HasExited) {
        if ((Test-Path $log) -and (Select-String -Path $log -Pattern 'to\(InGame\)' -Quiet)) { $up = $true; break }
        Start-Sleep -Seconds 1
    }
    if (-not $up) { throw "The world did not come up (exit: $($proc.HasExited)). Log: $log" }
    Write-Host ("world is up after {0:N1}s" -f $timer.Elapsed.TotalSeconds)
    Connect-Rcon $rconPort $password $deadline

    $outDir = "$work\script-output\factorio-forge"
    $wanted = @()

    $answer = Invoke-Console "/forge-export"; Write-Host "export answer: [$answer]"
    if (-not (Wait-ForFile "$outDir\environment.json" $deadline)) { throw "environment.json did not appear. See log tail." }
    $wanted += "environment.json"
    Write-Host ("export written after {0:N1}s" -f $timer.Elapsed.TotalSeconds)

    if ($Blueprint) {
        $text = ((Get-Content $Blueprint -Raw -Encoding UTF8) -replace '\s', '')
        $answer = Invoke-Console "/forge-verify $text"; Write-Host "verify answer: [$answer]"
        if (-not (Wait-ForFile "$outDir\verify.json" $deadline)) { throw "verify.json did not appear. See log tail." }
        $wanted += "verify.json"
        Write-Host ("verify written after {0:N1}s" -f $timer.Elapsed.TotalSeconds)
    }

    foreach ($name in $wanted) { Copy-Item "$outDir\$name" (Join-Path $Out $name) -Force }
    $ok = $true
}
catch {
    Write-Host "FAILED: $($_.Exception.Message)"
    if (Test-Path "$work\factorio-current.log") {
        Write-Host "---- log tail ----"
        Get-Content "$work\factorio-current.log" -Tail 25 | ForEach-Object { Write-Host $_ }
    }
}
finally {
    if ($proc -and -not $proc.HasExited) {
        try { Send-Rcon 2 "/quit" } catch {}
        # Say goodbye on the RCON line, then let go of it.
        if ($script:rcon) { try { $script:rcon.Close() } catch {} }
        # `/quit` makes the server save and close its game session (the log says
        # "Quitting: remote-quit" and then state Closed). On the Windows Steam
        # build the process then stays alive, idle, and never says Goodbye; so
        # once the session is closed and a few seconds have passed, this run's
        # own process -- by pid, never by name -- is ended.
        $quitting = [Diagnostics.Stopwatch]::StartNew()
        $closed = $false
        while (-not $proc.HasExited -and $quitting.Elapsed.TotalSeconds -lt 40) {
            if (-not $closed -and (Test-Path $log) -and (Select-String -Path $log -Pattern 'to\(Closed\)' -Quiet)) {
                $closed = $true; $closedAt = $quitting.Elapsed.TotalSeconds
            }
            if ($closed -and ($quitting.Elapsed.TotalSeconds - $closedAt) -gt 5) { break }
            Start-Sleep -Milliseconds 500
        }
        if ($proc.HasExited) { Write-Host ("server quit by itself in {0:N1}s" -f $quitting.Elapsed.TotalSeconds) }
        else {
            Write-Host ("game session closed: {0}; ending the idle process {1}" -f $closed, $proc.Id)
            try { $proc.Kill() } catch {}
            $proc.WaitForExit(10000) | Out-Null
        }
    }
    if ($script:rcon) { try { $script:rcon.Close() } catch {} }
    if ($proc) { Write-Host "server exit code: $($proc.ExitCode)" }
    if (Test-Path "$work\factorio-current.log") { Copy-Item "$work\factorio-current.log" (Join-Path $Out "headless-factorio.log") -Force }
    Start-Sleep -Milliseconds 500
    if ($KeepTemp) { Write-Host "kept: $work" }
    else { Remove-Item $work -Recurse -Force -ErrorAction SilentlyContinue }
    $left = if ($proc) { Get-Process -Id $proc.Id -ErrorAction SilentlyContinue }
    if ($left) { Write-Host "WARNING: a factorio process is still running"; $left | Stop-Process -Force }
}

$after = Get-Fingerprint $DataDir
if ($before -eq $after) { Write-Host "real saves, mod list and mod settings unchanged" }
else { Write-Host "WARNING: the real data folder changed during the run"; $ok = $false }
Write-Host ("total {0:N1}s" -f $timer.Elapsed.TotalSeconds)
if (-not $ok) { exit 1 }
