<#
.SYNOPSIS
    PowerShell bootloader‑unlocker with:
      • Fastboot discovery (script folder → CWD → PATH)
      • IMEI‑named log file placed beside the script
      • Watchdog that restarts the routine if a fastboot call hangs
      • Pattern generation using the original DSL (9, A, a, X, x, H, h, ?)

.REQUIREMENTS
    • Android SDK Platform‑Tools (fastboot.exe)
    • PowerShell 5.1+ (works in Windows PowerShell and PowerShell 7)
#>

# --------------------------------------------------
# 1️⃣  Configuration (editable)
# --------------------------------------------------
$Command          = "auto"                     # auto | flashing-unlock | flashing-unlock-code | oem-unlock | oem-unlock-code
$Patterns         = @("9{6}", "A{4}9{2}", "X{20}")   # mask list – most‑likely first
$MaxPerPattern    = 1000                       # candidates per mask
$HangTimeout      = 30                         # seconds before a fastboot call is considered hung
$MaxRestarts      = 3                          # how many times to retry the whole routine
$ScriptFolder     = Split-Path -Parent $MyInvocation.MyCommand.Definition

# --------------------------------------------------
# 2️⃣  Locate fastboot (script folder → CWD → PATH)
# --------------------------------------------------
function Get-FastbootPath {
    # 1) Beside this script – highest priority; avoids PATH ambiguity entirely.
    $scriptLocal = Join-Path $ScriptFolder "fastboot.exe"
    if (Test-Path $scriptLocal) {
        $resolved = Resolve-Path $scriptLocal -ErrorAction SilentlyContinue
        if ($resolved) { return $resolved.Path }
    }

    # 2) Current working directory – user may have launched from platform-tools folder.
    $cwdLocal = Join-Path (Get-Location).Path "fastboot.exe"
    if (Test-Path $cwdLocal) {
        $resolved = Resolve-Path $cwdLocal -ErrorAction SilentlyContinue
        if ($resolved) { return $resolved.Path }
    }

    # 3) Fall back to PATH.
    $cmd = Get-Command fastboot.exe -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }

    throw "fastboot.exe not found. Place it beside unlock.ps1, in the current folder, or add it to PATH."
}
$Fastboot = Get-FastbootPath

# --------------------------------------------------
# 3️⃣  Fastboot wrapper with hang detection
# --------------------------------------------------
# FIX: Moved above Get-DeviceImei so it is defined before its first invocation.
# FIX: Use GUID-named temp files in $env:TEMP to avoid collisions and permission
#      issues with fixed "stdout.tmp"/"stderr.tmp" in the working directory.
#      Cleanup now also runs in the timeout (hang) path.
# FIX: Use Write-Host (not Write-Log) for the hang warning here because Write-Log
#      depends on $LogFile which is not yet set at the time Get-DeviceImei runs.
function Invoke-Fastboot {
    param([string[]]$Arguments)

    $tmpOut = Join-Path $env:TEMP ("fastboot_stdout_{0}.tmp" -f [guid]::NewGuid())
    $tmpErr = Join-Path $env:TEMP ("fastboot_stderr_{0}.tmp" -f [guid]::NewGuid())

    $proc = Start-Process -FilePath $Fastboot `
                           -ArgumentList $Arguments `
                           -WorkingDirectory (Split-Path -Parent $Fastboot) `
                           -NoNewWindow `
                           -RedirectStandardOutput $tmpOut `
                           -RedirectStandardError  $tmpErr `
                           -PassThru

    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    while (-not $proc.HasExited) {
        if ($sw.Elapsed.TotalSeconds -gt $HangTimeout) {
            Write-Host ("⚠️ Fastboot call '{0}' hung (> {1} s). Killing." -f ($Arguments -join ' '), $HangTimeout)
            $proc | Stop-Process -Force -ErrorAction SilentlyContinue
            Remove-Item $tmpOut,$tmpErr -ErrorAction SilentlyContinue
            return "HANG"
        }
        Start-Sleep -Milliseconds 200
    }
    $out = if (Test-Path $tmpOut) { Get-Content $tmpOut -Raw } else { "" }
    $err = if (Test-Path $tmpErr) { Get-Content $tmpErr -Raw } else { "" }
    Remove-Item $tmpOut,$tmpErr -ErrorAction SilentlyContinue
    return $out + $err
}

# --------------------------------------------------
# 4️⃣  IMEI‑named log file in the script folder
# --------------------------------------------------
# Invoke-Fastboot is now defined above, so this call succeeds at script load time.
function Get-DeviceImei {
    $out = Invoke-Fastboot @("getvar","all")
    # FIX: Split on CRLF or LF to handle both Windows and Unix output.
    foreach ($line in ($out -split '\r?\n')) {
        if ($line -match "imei\s*:\s*(\S+)") { return $Matches[1] }
    }
    return $null
}
$Imei   = Get-DeviceImei
if (-not $Imei) { $Imei = "bootloader_unlocker" }   # fallback name
$LogFile = Join-Path $ScriptFolder "$Imei.log"

function Write-Log {
    param([string]$msg)
    $stamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $entry = "$stamp $msg"
    $entry | Tee-Object -FilePath $LogFile -Append | Out-Host
}

# --------------------------------------------------
# 5️⃣  Device detection & profile auto‑detect
# --------------------------------------------------
function Get-Device {
    Write-Host "DEBUG fastboot path: $Fastboot"
    $out = Invoke-Fastboot @("devices")
    Write-Host ("DEBUG fastboot devices raw: " + ($out -replace "`r","\\r" -replace "`n","\\n"))
    # FIX: Trim each line and match serial + "fastboot" token to handle spacing/tab variations.
    foreach ($line in ($out -split '\r?\n')) {
        $trimmed = $line.Trim()
        if ($trimmed -match '^([A-Za-z0-9:_-]+)\s+fastboot') { return $Matches[1] }
    }
    return $null
}
function Detect-Profile {
    if ($Command -ne "auto") { return $Command }

    return "flashing-unlock"
}

# --------------------------------------------------
# 6️⃣  Pattern expansion (DSL → random candidates)
# --------------------------------------------------
function Expand-Pattern {
    param(
        [Parameter(Mandatory)][string]$Pattern,
        [Parameter(Mandatory)][int]$Count
    )

    # ----- ONE‑TIME MAP – CASE‑SENSITIVE DICTIONARY -----
    # PowerShell hash literals are case-insensitive, so 'A' and 'a' would
    # collide.  Use an Ordinal-keyed Dictionary to keep all eight distinct tokens.
    $charMap = New-Object 'System.Collections.Generic.Dictionary[string,string]' ([System.StringComparer]::Ordinal)
    $charMap.Add('9', '[0-9]')        # numeric
    $charMap.Add('A', '[A-Z]')        # uppercase letters
    $charMap.Add('a', '[a-z]')        # lowercase letters
    $charMap.Add('X', '[A-Z0-9]')     # uppercase alphanumeric
    $charMap.Add('x', '[A-Za-z0-9]')  # mixed‑case alphanumeric
    $charMap.Add('H', '[0-9A-F]')     # hex upper
    $charMap.Add('h', '[0-9a-f]')     # hex lower
    $charMap.Add('?', '[A-Za-z0-9]')  # wildcard (same as mixed alphanumeric)

    # Translate DSL tokens into a regex‑like pattern
    $regex = $Pattern
    foreach ($k in $charMap.Keys) {
        $regex = $regex -replace $k, $charMap[$k]
    }

    $samples = @()
    $rng = [System.Random]::new()
    while ($samples.Count -lt $Count) {
        # Expand repeats like {6}
        $candidate = ($regex -replace '\{(\d+)\}',
            { $c = [int]$Matches[1]; $Matches[0] * $c }) -replace '\[.+?\]',
            {
                $cls = $Matches[0].Trim('[',']')
                $cls[$rng.Next(0,$cls.Length)]
            }
        $samples += $candidate
    }
    return $samples
}

# --------------------------------------------------
# 7️⃣  Core unlock routine (runs once)
# --------------------------------------------------
function Run-Unlock {
    $fastbootFailurePattern = "(FAILED|error|waiting|HANG)"
    $unsupportedCommandPattern = "((unknown|invalid|unrecognized) command|not found|usage:)"

    $device = Get-Device
    if (-not $device) {
        Write-Log "❌ No fastboot device detected – connect the phone in bootloader mode."
        return $false
    }
    Write-Log "🔎 Device found: $device"

    $profile = Detect-Profile
    Write-Log "⚙️ Using profile: $profile"

    switch ($profile) {
        "flashing-unlock"{
            $out = Invoke-Fastboot @("flashing","unlock")
            Write-Log $out
            if ($out -match $unsupportedCommandPattern) {
                Write-Log "ℹ️ 'fastboot flashing unlock' is unsupported; retrying with 'fastboot oem unlock'."
                $out = Invoke-Fastboot @("oem","unlock")
                Write-Log $out
                if ($out -match $unsupportedCommandPattern) {
                    return $false
                }
            }
            return $out -notmatch $fastbootFailurePattern
        }
        "oem-unlock"{
            $out = Invoke-Fastboot @("oem","unlock")
            Write-Log $out
            return $out -notmatch $fastbootFailurePattern
        }
        "flashing-unlock-code"{
            foreach($pat in $Patterns){
                $cands = Expand-Pattern -Pattern $pat -Count $MaxPerPattern
                foreach($code in $cands){
                    $out = Invoke-Fastboot @("flashing","unlock",$code)
                    Write-Log "Trying $code → $out"
                    if($out -notmatch $fastbootFailurePattern){
                        Write-Log "✅ SUCCESS – unlock code: $code"
                        return $true
                    }
                }
            }
            return $false
        }
        "oem-unlock-code"{
            foreach($pat in $Patterns){
                $cands = Expand-Pattern -Pattern $pat -Count $MaxPerPattern
                foreach($code in $cands){
                    $out = Invoke-Fastboot @("oem","unlock",$code)
                    Write-Log "Trying $code → $out"
                    if($out -notmatch $fastbootFailurePattern){
                        Write-Log "✅ SUCCESS – unlock code: $code"
                        return $true
                    }
                }
            }
            return $false
        }
        default{
            Write-Log "❓ Unsupported profile: $profile"
            return $false
        }
    }
}

# --------------------------------------------------
# 8️⃣  Watchdog – restart on failure/hang
# --------------------------------------------------
$attempt = 0
while ($attempt -lt $MaxRestarts) {
    $attempt++
    Write-Log "`n=== Attempt $attempt of $MaxRestarts ==="
    $ok = Run-Unlock
    if ($ok) {
        Write-Log "🎉 Unlock procedure finished successfully."
        break
    }
    else {
        Write-Log "⚠️ Unlock failed or hung – restarting after short pause."
        Start-Sleep -Seconds 5
    }
}
if (-not $ok) {
    Write-Log "❌ All $MaxRestarts attempts exhausted – manual intervention required."
}
