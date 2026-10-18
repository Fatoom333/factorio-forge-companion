# Run Factorio without a window, on a copy of a save, and collect what the
# companion mod writes.
#
#   headless-run.ps1 -Save my-save.zip -Out out [-Blueprint line.txt] [-Measure spec.json]
#
# What it does, in order:
#   1. refuses to start if Factorio is already running;
#   2. builds a throwaway folder (config.ini, server-settings.json, a copy of the
#      save, a copy of ONLY the mods the save was made with, a mod-list.json
#      written for them, the settings file) -- the game is told to use that
#      folder for everything it writes;
#   3. starts `factorio --start-server` on the copy, bound to 127.0.0.1;
#   4. waits until the world is up, sends `/forge-export` (and `/forge-verify`
#      when a blueprint is given, `/forge-measure` when a spec is given) over RCON,
#      and waits for the result files;
#   5. copies them to -Out, asks the server to quit, and kills it if it does not;
#   6. checks that the real save, mod list and mod settings did not change.
#
# The mod set is the SAVE's own, read from the save file by factorio-forge (so a
# mod another project enabled in the player's mod-list.json does not leak in):
# each mod at the version the save names when that file is in the mods folder,
# else the newest one there, and the run says which. -UseModList takes the
# player's mod-list.json instead. The companion mod is always added, at the
# -ModZip build or else the newest installed one (never the save's version).
#
# -Measure builds a blueprint on an empty surface and measures what it makes;
# see the README ("/forge-measure") for the spec and the result.
#
# Nothing is written into the game's install folder or its real data folder, and
# nothing is downloaded or installed. The commands go in over RCON on
# 127.0.0.1. The password is made fresh for each run, is never printed and sits
# only on the server's command line (Factorio reads RCON settings nowhere else for
# --start-server), so a local process of the same user could read it meanwhile. Two ports
# are open on the loopback address (the game's and RCON's, both random) and only
# while the run lasts.
#
# Exit codes: 0 done, 1 failed, 2 Factorio was already running (nothing started).
# The companion mod must be 0.7.1 or newer (earlier ones stop a server on a
# command typed at the console); pass -ModZip with a fresh build otherwise.

[CmdletBinding()]
param(
    # The save to run on. A bare name is looked up in the data folder's saves/.
    [Parameter(Mandatory = $true)] [string] $Save,
    # Where the result files are copied to.
    [Parameter(Mandatory = $true)] [string] $Out,
    # A file holding one blueprint string; when given, /forge-verify is run on it.
    [string] $Blueprint,
    # A measuring spec (JSON, see README); when given, /forge-measure is run on it
    # and measure.json is copied to -Out. The spec may carry "speed" (game speed).
    [string] $Measure,
    # Take the mods from the player's mod-list.json instead of from the save.
    [switch] $UseModList,
    # A python that can import factorio_forge (reads the save's mod list);
    # default: $env:FACTORIO_FORGE_PYTHON, else python / py.
    [string] $ForgePython,
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
    $roots = @(${env:ProgramFiles(x86)}, $env:ProgramFiles)
    # Steam may live on another drive; it records where.
    try {
        $steam = (Get-ItemProperty "HKCU:\Software\Valve\Steam" -ErrorAction Stop).SteamPath
        if ($steam) { $roots += (Split-Path ($steam -replace '/', '\')) }
    } catch {}
    $roots = $roots | Where-Object { $_ } | Select-Object -Unique
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

function Wait-ForFile([string] $path, [datetime] $deadline, $process, [string] $log) {
    # Present, non-empty and not growing any more. Gives up at once when the
    # server has gone or its session has failed or closed: nothing will come.
    $last = -1
    while ((Get-Date) -lt $deadline) {
        if ($process.HasExited) { return $false }
        if ((Test-Path $log) -and (Select-String -Path $log -Pattern 'to\((Closed|Failed)\)' -Quiet)) { return $false }
        if (Test-Path $path) {
            $size = (Get-Item $path).Length
            if ($size -gt 0 -and $size -eq $last) { return $true }
            $last = $size
        }
        Start-Sleep -Milliseconds 700
    }
    return $false
}

function Get-ModVersion([string] $fileName) {
    if ($fileName -match '_(\d+)\.(\d+)\.(\d+)(\.zip)?$') { return [version]"$($Matches[1]).$($Matches[2]).$($Matches[3])" }
    return $null
}

# The mods the save was made with, asked of factorio-forge, which reads them
# from the save's own header.
function Get-SaveMods([string] $savePath, [string] $scratch) {
    $ErrorActionPreference = "Continue"   # a python that fails must not stop the run before the next is tried
    $candidates = @()
    if ($ForgePython) { $candidates += $ForgePython }
    if ($env:FACTORIO_FORGE_PYTHON) { $candidates += $env:FACTORIO_FORGE_PYTHON }
    $candidates += @("python", "py")
    $script = Join-Path $scratch "save-mods.py"
    $body = @(
        "import json, sys",
        "from pathlib import Path",
        "from factorio_forge.save import read_save_info",
        "info = read_save_info(Path(sys.argv[1]))",
        "print(json.dumps({'game': info.game_version_string, 'mods': [[m.name, m.version_string] for m in info.mods]}))"
    ) -join "`n"
    [IO.File]::WriteAllText($script, $body, (New-Object Text.UTF8Encoding($false)))
    $tried = @()
    foreach ($python in $candidates) {
        if (-not (Get-Command $python -ErrorAction SilentlyContinue)) { $tried += "$python (not found)"; continue }
        $env:PYTHONIOENCODING = "utf-8"
        $text = & $python $script $savePath 2>$null
        if ($LASTEXITCODE -eq 0 -and $text) { return ($text | Select-Object -Last 1 | ConvertFrom-Json) }
        $tried += "$python (cannot read the save or import factorio_forge)"
    }
    throw ("Could not read the save's mod list through factorio-forge; tried: " + ($tried -join "; ") +
        ". Pass -ForgePython <python with factorio_forge installed> or -UseModList.")
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
    Write-Host "Factorio is already running; not starting anything. Close it and try again."
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

    # Only the mods this run loads are copied: the whole folder can be gigabytes
    # of graphics packs it never touches.
    $builtIn = Join-Path (Split-Path (Split-Path (Split-Path $exe))) "data"
    $listEntries = @()
    $modsNeeded = @()    # (name, version or $null) of mods that come from the mods folder
    if ($UseModList) {
        $list = Get-Content (Join-Path $realMods "mod-list.json") -Raw -Encoding UTF8 | ConvertFrom-Json
        $listEntries = @($list.mods | ForEach-Object { [pscustomobject]@{ name = $_.name; enabled = [bool]$_.enabled } })
        # Built-in mods (base, space-age, ...) have no file in the mods folder.
        $modsNeeded = @($list.mods | Where-Object { $_.enabled -and -not (Test-Path (Join-Path $builtIn "$($_.name)\info.json")) } |
            ForEach-Object { [pscustomobject]@{ name = $_.name; version = $null } })
        Write-Host "mod set: the player's mod-list.json ($($modsNeeded.Count) enabled)"
    }
    else {
        $saveMods = Get-SaveMods $Save $work
        foreach ($m in $saveMods.mods) {
            $name = $m[0]
            $isBuiltIn = (Test-Path (Join-Path $builtIn "$name\info.json"))
            $listEntries += [pscustomobject]@{ name = $name; enabled = $true }
            if (-not $isBuiltIn) { $modsNeeded += [pscustomobject]@{ name = $name; version = [version]$m[1] } }
        }
        # Built-in mods (base, space-age, ...) the save does not use are switched off,
        # or the game would turn them on by itself.
        $saveNames = @($saveMods.mods | ForEach-Object { $_[0] })
        foreach ($dir in Get-ChildItem $builtIn -Directory) {
            if ($dir.Name -ne "core" -and (Test-Path (Join-Path $dir.FullName "info.json")) -and $saveNames -notcontains $dir.Name) {
                $listEntries += [pscustomobject]@{ name = $dir.Name; enabled = $false }
            }
        }
        Write-Host "mod set: the save's own ($($saveMods.mods.Count) mods, game $($saveMods.game))"
    }
    if (-not ($modsNeeded | Where-Object { $_.name -eq $ModName })) {
        $modsNeeded += [pscustomobject]@{ name = $ModName; version = $null }
        if (-not ($listEntries | Where-Object { $_.name -eq $ModName })) { $listEntries += [pscustomobject]@{ name = $ModName; enabled = $true } }
    }

    $copied = 0
    $usedLines = @()
    foreach ($want in $modsNeeded) {
        $name = $want.name
        if ($ModZip -and $name -eq $ModName) { continue }
        # Candidates in the mods folder: name_x.y.z.zip or an unpacked name_x.y.z folder.
        $found = @(Get-ChildItem $realMods | Where-Object {
            ($_.PSIsContainer -and $_.Name -match "^$([regex]::Escape($name))_\d+\.\d+\.\d+$") -or
            (-not $_.PSIsContainer -and $_.Name -match "^$([regex]::Escape($name))_\d+\.\d+\.\d+\.zip$") })
        if (-not $found) {
            # The player's list names mods that are not installed; the old behaviour skipped them.
            if ($UseModList) { $usedLines += "$name (listed, but not in the mods folder: skipped)"; continue }
            throw "Mod '$name' is not in the mods folder ($realMods)."
        }
        $exact = $null
        # The companion only exports and measures; its version is never taken from the save.
        if ($want.version -and $name -ne $ModName) { $exact = $found | Where-Object { (Get-ModVersion $_.Name) -eq $want.version } | Select-Object -First 1 }
        if ($exact) { $pick = $exact; $usedLines += "$name $($want.version)" }
        else {
            $pick = $found | Sort-Object { Get-ModVersion $_.Name } -Descending | Select-Object -First 1
            $got = Get-ModVersion $pick.Name
            $usedLines += if ($name -eq $ModName -and $want.version) { "$name $got (newest installed; the save names $($want.version), which is not used for the companion)" } elseif ($want.version) { "$name $got (the save names $($want.version), which is not in the mods folder)" } else { "$name $got (newest in the mods folder)" }
        }
        if ($pick.PSIsContainer) { Copy-Item $pick.FullName "$work\mods\$($pick.Name)" -Recurse } else { Copy-Item $pick.FullName "$work\mods\" }
        $copied++
    }
    if ($ModZip) {
        Copy-Item $ModZip "$work\mods\"; $copied++
        $usedLines += "$ModName (from -ModZip $(Split-Path $ModZip -Leaf))"
    }
    foreach ($line in $usedLines) { Write-Host "  mod: $line" }
    [IO.File]::WriteAllText((Join-Path $Out "mods-used.txt"), ($usedLines -join "`n") + "`n", (New-Object Text.UTF8Encoding($false)))

    $versions = @(Get-ChildItem "$work\mods" -Filter "${ModName}_*" | ForEach-Object { Get-ModVersion $_.Name } | Where-Object { $_ })
    if (-not $versions) { throw "The companion mod ($ModName) was not found; pass -ModZip." }
    $version = ($versions | Sort-Object -Descending)[0]
    if ($version -lt [version]"0.7.1") {
        throw "The companion mod is $version; 0.7.1 or newer is needed (older ones stop a headless server on /forge-export). Pass -ModZip with a fresh build."
    }
    if ($Measure -and $version -lt [version]"0.8.0") {
        throw "The companion mod is $version; -Measure needs 0.8.0 or newer. Pass -ModZip with a fresh build."
    }
    # The mod list says exactly which of the copied mods load.
    $modList = @{ mods = @($listEntries | ForEach-Object { @{ name = $_.name; enabled = $_.enabled } }) }
    [IO.File]::WriteAllText("$work\mods\mod-list.json", ($modList | ConvertTo-Json -Depth 5), (New-Object Text.UTF8Encoding($false)))
    $settingsFile = Join-Path $realMods "mod-settings.dat"
    if (Test-Path $settingsFile) { Copy-Item $settingsFile "$work\mods\" }

    $saveCopy = Join-Path "$work\saves" "run.zip"
    Copy-Item $Save $saveCopy

    $port = Get-Random -Minimum 20000 -Maximum 40000
    $rconPort = Get-Random -Minimum 40001 -Maximum 60000
    # A password for this run only: never printed, never stored. It has to go on
    # the command line: the config.ini keys local-rcon-socket/-password are for
    # servers launched from the menu and --start-server ignores them (tried), so
    # for the ~20 s of the run a local process of the same user could read it.
    $rng = New-Object Security.Cryptography.RNGCryptoServiceProvider
    $raw = New-Object byte[] 24
    $rng.GetBytes($raw)
    $password = [Convert]::ToBase64String($raw) -replace '[^A-Za-z0-9]', 'x'
    $fwd = $work -replace '\\', '/'
    # read-data is the install's own data folder; write-data is the throwaway one.
    # UTF-8 without a BOM: the temp path may hold non-ASCII (a Windows user name).
    $utf8 = New-Object Text.UTF8Encoding($false)
    $configText = (@("[path]", "read-data=__PATH__system-read-data__", "write-data=$fwd",
        "[general]", "locale=auto") -join "`n") + "`n"
    [IO.File]::WriteAllText("$work\config.ini", $configText, $utf8)
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
    [IO.File]::WriteAllText("$work\server-settings.json", ($settings | ConvertTo-Json -Depth 10), $utf8)

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
    if (-not (Wait-ForFile "$outDir\environment.json" $deadline $proc $log)) { throw "environment.json did not appear. See log tail." }
    $wanted += "environment.json"
    Write-Host ("export written after {0:N1}s" -f $timer.Elapsed.TotalSeconds)

    if ($Blueprint) {
        $text = ((Get-Content $Blueprint -Raw -Encoding UTF8) -replace '\s', '')
        $answer = Invoke-Console "/forge-verify $text"; Write-Host "verify answer: [$answer]"
        # The command has finished when RCON answers. If it printed a reply and
        # no file is there, the reply is the reason (not a blueprint, no
        # prototypes): do not sit out the whole timeout.
        $limit = if ($answer) { (Get-Date).AddSeconds(8) } else { $deadline }
        if (-not (Wait-ForFile "$outDir\verify.json" $limit $proc $log)) {
            if ($answer) { throw "/forge-verify refused: $answer" }
            throw "verify.json did not appear. See log tail."
        }
        $wanted += "verify.json"
        Write-Host ("verify written after {0:N1}s" -f $timer.Elapsed.TotalSeconds)
    }

    $measureFailed = $false
    if ($Measure) {
        $specText = ((Get-Content $Measure -Raw -Encoding UTF8) -replace '\s*[\r\n]+\s*', ' ').Trim()
        $spec = $specText | ConvertFrom-Json
        $speed = if ($spec.speed -and $spec.speed -gt 0) { [double]$spec.speed } else { 1.0 }
        $gameSeconds = [double]$(if ($spec.warmup_s) { $spec.warmup_s } else { 60 }) + [double]$(if ($spec.measure_s) { $spec.measure_s } else { 120 })
        # The game may not keep up with the speed asked for: allow three times the
        # time it would take, and a couple of minutes to start.
        $measureDeadline = (Get-Date).AddSeconds([Math]::Max(120, 3 * $gameSeconds / $speed + 120))
        if ($measureDeadline -lt $deadline) { $measureDeadline = $deadline }
        $answer = Invoke-Console "/forge-measure $specText"; Write-Host "measure answer: [$answer]"
        if (-not (Wait-ForFile "$outDir\measure.json" $measureDeadline $proc $log)) {
            throw "measure.json did not appear. See log tail."
        }
        $wanted += "measure.json"
        Write-Host ("measure written after {0:N1}s" -f $timer.Elapsed.TotalSeconds)
        $result = Get-Content "$outDir\measure.json" -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($result.ok) {
            Write-Host ("measured: {0} of {1} entities placed" -f $result.placed, $result.expected)
        }
        else {
            Write-Host "measure FAILED: $($result.error)"
            $measureFailed = $true
        }
    }

    foreach ($name in $wanted) { Copy-Item "$outDir\$name" (Join-Path $Out $name) -Force }
    $ok = -not $measureFailed
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
        $asked = $false
        try { Send-Rcon 2 "/quit"; $asked = $true } catch {}
        # Say goodbye on the RCON line, then let go of it.
        if ($script:rcon) { try { $script:rcon.Close() } catch {} }
        # `/quit` makes the server save and close its game session (the log says
        # "Quitting: remote-quit" and then state Closed). On the Windows Steam
        # build the process then stays alive, idle, and never says Goodbye; so
        # once the session is closed and a few seconds have passed, this run's
        # own process -- by pid, never by name -- is ended.
        # If /quit never went out (RCON never connected), there is nothing to wait for.
        $quitting = [Diagnostics.Stopwatch]::StartNew()
        $closed = $false
        $patience = if ($asked) { 40 } else { 0 }
        while (-not $proc.HasExited -and $quitting.Elapsed.TotalSeconds -lt $patience) {
            if (-not $closed -and (Test-Path $log) -and (Select-String -Path $log -Pattern 'to\((Closed|Failed)\)' -Quiet)) {
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
