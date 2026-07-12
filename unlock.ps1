<#
.SYNOPSIS
    PowerShell bootloader‑unlocker with:
      • Fastboot discovery (PATH → script folder)
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
# 2️⃣  Locate fastboot (PATH first, then script folder)
# --------------------------------------------------
function Get-FastbootPath {
    $cmd = Get-Command fastboot.exe -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }

    $local = Join-Path $ScriptFolder "fastboot.exe"
    if (Test-Path $local) { return $local }

    throw "fastboot.exe not found – add it to PATH or place it beside this script."
}
$Fastboot = Get-FastbootPath

# --------------------------------------------------
# 3️⃣  IMEI‑named log file in the script folder
# --------------------------------------------------
function Get-DeviceImei {
    $out = Invoke-Fastboot "getvar all"
    foreach ($line in $out -split "`n") {
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
# 4️⃣  Fastboot wrapper with hang detection
# --------------------------------------------------
function Invoke-Fastboot {
    param([string]$args)

    $proc = Start-Process -FilePath $Fastboot `
                           -ArgumentList $args `
                           -NoNewWindow -RedirectStandardOutput "stdout.tmp" `
                           -RedirectStandardError  "stderr.tmp" `
                           -PassThru

    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    while (-not $proc.HasExited) {
        if ($sw.Elapsed.TotalSeconds -gt $HangTimeout) {
            Write-Log "⚠️ Fastboot call '$args' hung (> $HangTimeout s). Killing."
            $proc | Stop-Process -Force
            return "HANG"
        }
        Start-Sleep -Milliseconds 200
    }
    $out = Get-Content "stdout.tmp" -Raw
    $err = Get-Content "stderr.tmp" -Raw
    Remove-Item "stdout.tmp","stderr.tmp" -ErrorAction SilentlyContinue
    return $out + $err
}

# --------------------------------------------------
# 5️⃣  Device detection & profile auto‑detect
# --------------------------------------------------
function Get-Device {
    $out = Invoke-Fastboot "devices"
    if ($out -match "^([a-zA-Z0-9:_-]+)\s+fastboot") { return $Matches[1] }
    return $null
}
function Detect-Profile {
    if ($Command -ne "auto") { return $Command }

    $candidates = @("flashing unlock","oem unlock")
    foreach ($c in $candidates) {
        $out = Invoke-Fastboot $c
        if ($out -notmatch "(FAILED|error|waiting|HANG)") {
            return $c -replace "\s.*$"
        }
    }
    throw "Unable to autodetect a supported unlock command."
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
            $out = Invoke-Fastboot "flashing unlock"
            Write-Log $out
            return $out -notmatch "(FAILED|error|waiting|HANG)"
        }
        "oem-unlock"{
            $out = Invoke-Fastboot "oem unlock"
            Write-Log $out
            return $out -notmatch "(FAILED|error|waiting|HANG)"
        }
        "flashing-unlock-code"{
            foreach($pat in $Patterns){
                $cands = Expand-Pattern -Pattern $pat -Count $MaxPerPattern
                foreach($code in $cands){
                    $out = Invoke-Fastboot "flashing unlock $code"
                    Write-Log "Trying $code → $out"
                    if($out -notmatch "(FAILED|error|waiting|HANG)"){
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
                    $out = Invoke-Fastboot "oem unlock $code"
                    Write-Log "Trying $code → $out"
                    if($out -notmatch "(FAILED|error|waiting|HANG)"){
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
