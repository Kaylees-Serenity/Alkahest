$alkahest = @'
#requires -version 5.1
<#
    ℞ ALKAHEST — the universal solvent
    Sibling to Panacea. Dissolves stuck / pending Windows Updates.
    Native-only · fails-closed · single-paste · nothing deleted · never reboots
    Run from ScreenConnect backstage (SYSTEM) or frontstage admin prompt.

    Panda Adaptive Defense note: no regsvr32, no bitsadmin, no wusa, no sc.exe,
    no -EncodedCommand. Those are the LOLBins Panda blocks. See DISSOLVE.
#>

# ═══════════════════════════════════════════════════════════════
#  CONFIG BLOCK  —  every behavior decision lives here, up top
# ═══════════════════════════════════════════════════════════════
$Alkahest = [ordered]@{
    Version         = '1.1'
    NoColor         = $false       # force ASCII/no-VT skin
    MinFreeGB       = 10           # updates stall below this; symptom, not a stop
    LogRoot         = "$env:ProgramData\Alkahest\Updates"
    DryRun          = $false       # rehearsal mode: report what WOULD happen, mutate nothing
    ShowSetup       = $true        # show the interactive configure panel before DIAGNOSE
    ServicingRepair = $true        # DISM RestoreHealth + SFC when the store looks sick
    RunWinSxS       = $false       # DISM StartComponentCleanup (never /ResetBase)
    ClearPolicy     = $false       # OFF. clients run WSUS/Intune on purpose. arms with CLEAR
    ScheduleLocked  = $false       # if a cache is locked, queue the rename for next boot
    # long-running operation ceilings (seconds) — 0 = infinite (default; rely on Windows).
    # slow boxes are the norm; the S-key still gives instant bail on any long op.
    DismCheckTimeoutSec   = 0
    DismRestoreTimeoutSec = 0
    SfcTimeoutSec         = 0
    WinSxSTimeoutSec      = 0
    PkgScanTimeoutSec     = 0
}

# ═══════════════════════════════════════════════════════════════
#  COLOR ENGINE  —  VT-sniff, truecolor, ASCII fallback
# ═══════════════════════════════════════════════════════════════
$script:VT = $false
if (-not $Alkahest.NoColor) {
    try {
        if ($PSVersionTable.PSVersion.Major -ge 7) { $script:VT = $true }
        elseif ($Host.UI.SupportsVirtualTerminal) { $script:VT = $true }
    } catch { $script:VT = $false }
}
$e = [char]27
function Paint {
    param([string]$Text,[int[]]$Fg,[int[]]$Bg)
    if (-not $script:VT) { return $Text }
    $seq = ''
    if ($Fg) { $seq += "$e[38;2;$($Fg[0]);$($Fg[1]);$($Fg[2])m" }
    if ($Bg) { $seq += "$e[48;2;$($Bg[0]);$($Bg[1]);$($Bg[2])m" }
    "$seq$Text$e[0m"
}
# shared apothecary palette — identical values to Panacea
$Clr = @{
    Orange = @(255,140,0)   # Rx warning
    Green  = @(80,200,120)  # clear / healthy
    Cyan   = @(90,190,220)  # dissolving / fixed
    Grey   = @(120,120,120) # dim frame / skipped
    Red    = @(220,50,50)   # failed
    Black  = @(0,0,0)
}
if ($script:VT) {
    $G = @{ Ok='[✓]'; Work='[»]'; Warn='[!]'; Fail='[✗]'; Skip='[~]'; Rx='℞'; Staff='⚕'; Bell='⚠' }
} else {
    $G = @{ Ok='[OK]'; Work='[>>]'; Warn='[!]'; Fail='[XX]'; Skip='[~]'; Rx='Rx'; Staff='+'; Bell='!!' }
}

# ═══════════════════════════════════════════════════════════════
#  RESULT LEDGER  —  every tier writes here; PROGNOSIS reads it
# ═══════════════════════════════════════════════════════════════
try { $ctxName = [Security.Principal.WindowsIdentity]::GetCurrent().Name } catch { $ctxName = 'unknown' }
$script:Ledger = [ordered]@{
    Host         = $env:COMPUTERNAME
    Session      = -join ((48..57)+(97..102) | Get-Random -Count 6 | ForEach-Object {[char]$_})
    Started      = Get-Date
    Context      = $ctxName
    OSBuild      = ''
    UptimeDays   = 0
    UptimeText   = ''
    FreeGB       = 0.0
    PandaPresent = $false
    PendingBefore = New-Object System.Collections.Generic.List[string]
    PendingAfter  = New-Object System.Collections.Generic.List[string]
    Warnings     = New-Object System.Collections.Generic.List[string]
    Symptoms     = New-Object System.Collections.Generic.List[string]
    Proceed      = $true
}

function Rule($label) {
    $line = ('─' * 62)
    if (-not $script:VT) { $line = ('-' * 62) }
    Write-Host ''
    $suffix = if ($Alkahest.DryRun) { ' [DRY RUN]' } else { '' }
    Write-Host (Paint "── $label$suffix $line" -Fg $Clr.Cyan)
}
function Status {
    param([string]$Glyph,[string]$Label,[string]$Value,[int[]]$Color=$Clr.Grey)
    $g = Paint $Glyph -Fg $Color
    $dots = '.' * [Math]::Max(3, 20 - $Label.Length)
    Write-Host "   $g $Label $dots $Value"
}
# grey indented prose, printed where the finding was made rather than hoarded
# for the end. keeps the label short and loud, the way Panacea's is.
function Note {
    param([string[]]$Lines)
    foreach ($l in $Lines) { Write-Host (Paint "       $l" -Fg $Clr.Grey) }
}

# ═══════════════════════════════════════════════════════════════
#  BANNER  —  big wordmark into the Rx label frame
# ═══════════════════════════════════════════════════════════════
function Show-Banner {
    $wm = @(
        ' █████╗ ██╗    ██╗  ██╗ █████╗ ██╗  ██╗███████╗███████╗████████╗',
        '██╔══██╗██║    ██║ ██╔╝██╔══██╗██║  ██║██╔════╝██╔════╝╚══██╔══╝',
        '███████║██║    █████╔╝ ███████║███████║█████╗  ███████╗   ██║   ',
        '██╔══██║██║    ██╔═██╗ ██╔══██║██╔══██║██╔══╝  ╚════██║   ██║   ',
        '██║  ██║██████╗██║  ██╗██║  ██║██║  ██║███████╗███████║   ██║   ',
        '╚═╝  ╚═╝╚═════╝╚═╝  ╚═╝╚═╝  ╚═╝╚═╝  ╚═╝╚══════╝╚══════╝   ╚═╝   '
    )
    $bar = '═' * 62; $mid = '─' * 62
    if (-not $script:VT) { $bar = '=' * 62; $mid = '-' * 62 }
    Write-Host (Paint "╔$bar╗" -Fg $Clr.Cyan)
    foreach ($ln in $wm) { Write-Host (Paint $ln -Fg $Clr.Green) }
    Write-Host ''
    Write-Host (Paint "   $($G.Rx)  THE UNIVERSAL SOLVENT  ·  apothecary systems  ·  v$($Alkahest.Version)" -Fg $Clr.Cyan)
    Write-Host (Paint "╟$mid╢" -Fg $Clr.Grey)
    $d = Get-Date -Format 'yyyy-MM-dd HH:mm'
    $inf = if ($script:VT) { [char]0x221E } else { 'unlimited' }
    Write-Host (Paint "  RX # $($script:Ledger.Session.ToUpper())" -Fg $Clr.Grey) -NoNewline
    Write-Host (Paint "            DATE: $d    REFILLS: $inf" -Fg $Clr.Grey)
    Write-Host (Paint "  PATIENT: $($script:Ledger.Host)" -Fg $Clr.Grey)
    Write-Host (Paint "  PRESCRIBER: $($script:Ledger.Context)" -Fg $Clr.Grey)
    Write-Host (Paint "  DX: $($script:Ledger.OSBuild)" -Fg $Clr.Grey)
    Write-Host (Paint "╚$bar╝" -Fg $Clr.Cyan)
}

# ═══════════════════════════════════════════════════════════════
#  SETUP  —  interactive configure panel before the solvent runs.
#             non-interactive contexts (SYSTEM/backstage) skip it.
# ═══════════════════════════════════════════════════════════════
$script:AlkahestAbort = $false
function Show-Setup {
    if (-not $Alkahest.ShowSetup) { return }
    $interactive = $false
    try { $interactive = -not [Console]::IsInputRedirected } catch { $interactive = $false }
    if (-not $interactive) { return }

    $inf = if ($script:VT) { [char]0x221E } else { 'unlimited' }
    while ($true) {
        $bar = '─' * 62
        if (-not $script:VT) { $bar = '-' * 62 }
        Write-Host ''
        Write-Host (Paint "── DISPENSARY SETUP $bar" -Fg $Clr.Cyan)
        Write-Host (Paint "   configure before the solvent runs · each line shows what will happen" -Fg $Clr.Grey)
        Write-Host ''

        if ($Alkahest.DryRun) {
            $dryV = 'ON '; $dryHint = 'will only pretend — no changes made'
        } else {
            $dryV = 'OFF'; $dryHint = 'will make real changes when run'
        }
        if ($Alkahest.ServicingRepair) {
            $svcV = 'ON '; $svcHint = 'will repair the component store if it looks sick'
        } else {
            $svcV = 'OFF'; $svcHint = 'will skip DISM RestoreHealth and SFC'
        }
        if ($Alkahest.RunWinSxS) {
            $wsxV = 'ON '; $wsxHint = 'will trim Windows component store'
        } else {
            $wsxV = 'OFF'; $wsxHint = 'will skip component store cleanup'
        }
        if ($Alkahest.DismRestoreTimeoutSec -eq 0) {
            $toV = "$inf   "; $toHint = 'no time limit — best for slow PCs'
        } else {
            $mins = [Math]::Round($Alkahest.DismRestoreTimeoutSec/60)
            $toV = "{0,-4}m" -f $mins
            $toHint = "kills stuck operations after $mins min"
        }
        if ($Alkahest.ClearPolicy) {
            $polV = 'ON '; $polHint = 'will back up then REMOVE the GPO update keys'
        } else {
            $polV = 'OFF'; $polHint = 'will report update policy and leave it alone'
        }
        if ($Alkahest.ScheduleLocked) {
            $lckV = 'ON '; $lckHint = 'will queue a locked cache rename for next boot'
        } else {
            $lckV = 'OFF'; $lckHint = 'will report a locked cache and move on'
        }

        Write-Host (Paint "   [1] DryRun ............ $dryV   $dryHint" -Fg $Clr.Grey)
        Write-Host (Paint "   [2] Servicing repair .. $svcV   $svcHint" -Fg $Clr.Grey)
        Write-Host (Paint "   [3] WinSxS cleanup .... $wsxV   $wsxHint" -Fg $Clr.Grey)
        Write-Host (Paint "   [4] Timeouts .......... $toV  $toHint" -Fg $Clr.Grey)
        Write-Host (Paint "   [5] Clear WU policy ... $polV   $polHint" -Fg $Clr.Grey)
        Write-Host (Paint "   [6] Queue locked work . $lckV   $lckHint" -Fg $Clr.Grey)
        Write-Host ''
        Write-Host (Paint "   [Enter] proceed  ·  [Q] quit  ·  S skips any long step once running" -Fg $Clr.Cyan)
        Write-Host (Paint "    > " -Fg $Clr.Cyan) -NoNewline
        $c = [Console]::ReadLine()
        if ($null -eq $c) { return }
        $c = $c.Trim()

        if ($c -eq '') { return }
        elseif ($c -match '^[Qq]') {
            Write-Host ''
            Write-Host (Paint "   dispensary closed  ·  aborted at setup — nothing touched" -Fg $Clr.Grey)
            $script:AlkahestAbort = $true
            return
        }
        elseif ($c -eq '1') { $Alkahest.DryRun          = -not $Alkahest.DryRun }
        elseif ($c -eq '2') { $Alkahest.ServicingRepair = -not $Alkahest.ServicingRepair }
        elseif ($c -eq '3') { $Alkahest.RunWinSxS       = -not $Alkahest.RunWinSxS }
        elseif ($c -eq '6') { $Alkahest.ScheduleLocked  = -not $Alkahest.ScheduleLocked }
        elseif ($c -eq '4') {
            if ($Alkahest.DismRestoreTimeoutSec -eq 0) {
                $Alkahest.DismCheckTimeoutSec   = 300
                $Alkahest.DismRestoreTimeoutSec = 1800
                $Alkahest.SfcTimeoutSec         = 1800
                $Alkahest.WinSxSTimeoutSec      = 1800
                $Alkahest.PkgScanTimeoutSec     = 600
            } elseif ($Alkahest.DismRestoreTimeoutSec -le 1800) {
                $Alkahest.DismCheckTimeoutSec   = 600
                $Alkahest.DismRestoreTimeoutSec = 3600
                $Alkahest.SfcTimeoutSec         = 3600
                $Alkahest.WinSxSTimeoutSec      = 3600
                $Alkahest.PkgScanTimeoutSec     = 900
            } else {
                $Alkahest.DismCheckTimeoutSec   = 0
                $Alkahest.DismRestoreTimeoutSec = 0
                $Alkahest.SfcTimeoutSec         = 0
                $Alkahest.WinSxSTimeoutSec      = 0
                $Alkahest.PkgScanTimeoutSec     = 0
            }
        }
        elseif ($c -eq '5') {
            if (-not $Alkahest.ClearPolicy) {
                Write-Host ''
                Write-Host (Paint "   This client may point at WSUS on purpose." -Fg $Clr.Orange)
                Write-Host (Paint "   AD GPO rewrites this key on its own cycle. MDM is NOT documented to" -Fg $Clr.Orange)
                Write-Host (Paint "   re-push a value deleted locally, so assume the .reg backup is the" -Fg $Clr.Orange)
                Write-Host (Paint "   only way back. Intune Update rings live elsewhere and are untouched." -Fg $Clr.Orange)
                Write-Host (Paint "   type CLEAR to arm it > " -Fg $Clr.Orange) -NoNewline
                $y = [Console]::ReadLine()
                if ($y -and $y.Trim() -ceq 'CLEAR') { $Alkahest.ClearPolicy = $true }
            } else { $Alkahest.ClearPolicy = $false }
        }
    }
}

# ═══════════════════════════════════════════════════════════════
#  GUARDED RUNNER  —  same contract as Panacea's, same skin.
#  Register-ObjectEvent with try/finally unregister, so no orphan
#  subscriptions outlive the scriptblock and pollute the host.
# ═══════════════════════════════════════════════════════════════
function Invoke-Guarded {
    param(
        [string]$File,
        [string]$Arguments,
        [int]$TimeoutSec = 0,
        [string]$Label = '',
        [switch]$ShowNative   # let stdout flow to console (native DISM/SFC progress bar)
    )
    $canSkip = $false
    try { $canSkip = -not [Console]::IsInputRedirected } catch { $canSkip = $false }

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $File
    $psi.Arguments = $Arguments
    $psi.UseShellExecute = $false
    if ($ShowNative) {
        $psi.RedirectStandardOutput = $false
        $psi.RedirectStandardError  = $true
        $psi.CreateNoWindow = $false
    } else {
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError  = $true
        $psi.CreateNoWindow = $true
    }
    $p = New-Object System.Diagnostics.Process
    $p.StartInfo = $psi
    $sbOut = New-Object System.Text.StringBuilder
    $sbErr = New-Object System.Text.StringBuilder

    $outEvt = $null
    if (-not $ShowNative) {
        $outEvt = Register-ObjectEvent -InputObject $p -EventName OutputDataReceived -Action {
            if ($EventArgs.Data) { [void]$Event.MessageData.AppendLine($EventArgs.Data) }
        } -MessageData $sbOut
    }
    $errEvt = Register-ObjectEvent -InputObject $p -EventName ErrorDataReceived -Action {
        if ($EventArgs.Data) { [void]$Event.MessageData.AppendLine($EventArgs.Data) }
    } -MessageData $sbErr

    if ($ShowNative -and $canSkip) {
        Write-Host (Paint "      (press S at any time to skip)" -Fg $Clr.Grey)
    }

    $code = -1; $skipped = $false; $timedOut = $false
    try {
        [void]$p.Start()
        if (-not $ShowNative) { $p.BeginOutputReadLine() }
        $p.BeginErrorReadLine()

        if ($script:VT) { $frames = @([char]0x280B,[char]0x2819,[char]0x2839,[char]0x2838,[char]0x283C,[char]0x2834,[char]0x2826,[char]0x2827,[char]0x2807,[char]0x280F) }
        else            { $frames = @('|','/','-','\') }

        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        $frameIdx = 0

        while (-not $p.HasExited) {
            if ($TimeoutSec -gt 0 -and $sw.Elapsed.TotalSeconds -ge $TimeoutSec) { $timedOut = $true; try { $p.Kill() } catch {}; break }
            if ($canSkip) {
                try {
                    if ([Console]::KeyAvailable) {
                        $k = [Console]::ReadKey($true)
                        if ($k.KeyChar -eq 's' -or $k.KeyChar -eq 'S') {
                            $skipped = $true
                            try { $p.Kill() } catch {}
                            break
                        }
                    }
                } catch {}
            }
            if (-not $ShowNative) {
                $elapsed = "{0:mm\:ss}" -f $sw.Elapsed
                $spin = $frames[$frameIdx % $frames.Count]
                $hint = if ($canSkip) { 'press S to skip' } else { 'running' }
                $lbl  = if ($Label) { $Label } else { 'working' }
                $line = "      $spin  $lbl  ·  $elapsed elapsed  ·  $hint"
                try { [Console]::Write("`r" + $line.PadRight(70)) } catch {}
                $frameIdx++
            }
            Start-Sleep -Milliseconds 250
        }
        if (-not $ShowNative) {
            try { [Console]::Write("`r" + (' ' * 72) + "`r") } catch {}
        } else {
            Write-Host ''
        }

        Start-Sleep -Milliseconds 200
        $code = if ($skipped -or $timedOut) { -1 } else { try { $p.ExitCode } catch { -1 } }
    }
    finally {
        if (-not $ShowNative -and $outEvt) {
            Unregister-Event -SourceIdentifier $outEvt.Name -ErrorAction SilentlyContinue
            Remove-Job -Job $outEvt -Force -ErrorAction SilentlyContinue
        }
        if ($errEvt) {
            Unregister-Event -SourceIdentifier $errEvt.Name -ErrorAction SilentlyContinue
            Remove-Job -Job $errEvt -Force -ErrorAction SilentlyContinue
        }
        try { if (-not $p.HasExited) { $p.Kill() } } catch {}
        try { $p.Dispose() } catch {}
    }

    [pscustomobject]@{
        ExitCode = $code
        TimedOut = $timedOut
        Skipped  = $skipped
        StdOut   = $sbOut.ToString()
        StdErr   = $sbErr.ToString()
    }
}

# ═══════════════════════════════════════════════════════════════
#  SMALL HELPERS
# ═══════════════════════════════════════════════════════════════
function Get-RegValue($Path,$Name) {
    try { (Get-ItemProperty -Path $Path -Name $Name -ErrorAction Stop).$Name } catch { $null }
}
function Get-DirSizeGB($path) {
    try {
        if (-not (Test-Path -LiteralPath $path)) { return 0 }
        $m = Get-ChildItem -LiteralPath $path -Recurse -Force -File -ErrorAction SilentlyContinue |
             Measure-Object -Property Length -Sum
        if ($null -eq $m -or $null -eq $m.Sum) { return 0 }
        [Math]::Round($m.Sum/1GB,2)
    } catch { 0 }
}

$script:SvcSpec = @(
    @{ Name='wuauserv';         Nice='windows update';   Want='Manual'    },
    @{ Name='bits';             Nice='BITS';             Want='Manual'    },
    @{ Name='cryptsvc';         Nice='cryptographic';    Want='Automatic' },
    @{ Name='msiserver';        Nice='windows installer';Want='Manual'    },
    @{ Name='UsoSvc';           Nice='orchestrator';     Want='Manual'    },
    @{ Name='DoSvc';            Nice='delivery opt';     Want='Manual'    },
    @{ Name='TrustedInstaller'; Nice='windows modules';  Want='Manual'    }
)
$script:SvcState = @{}

function Stop-UpdateService($Name,$Nice) {
    try { $s = Get-Service -Name $Name -ErrorAction Stop }
    catch { Status $G.Skip $Nice 'not present on this build' $Clr.Grey; return }
    if ($s.Status -eq 'Stopped') { Status $G.Ok $Nice 'already stopped' $Clr.Green; return }
    if ($Alkahest.DryRun)        { Status $G.Skip $Nice 'would stop' $Clr.Grey; return }
    for ($i = 1; $i -le 3; $i++) {
        try {
            Stop-Service -Name $Name -Force -ErrorAction Stop
            Start-Sleep -Milliseconds 700
            if ((Get-Service $Name).Status -eq 'Stopped') { Status $G.Work $Nice 'stopped' $Clr.Cyan; return }
        } catch { Start-Sleep -Seconds ($i * 2) }
    }
    Status $G.Warn $Nice 'would not stop' $Clr.Orange
    Note @(
        'three attempts refused. on a Panda box this is usually the endpoint agent',
        'holding the service or its files open mid-scan. not fatal — the cache',
        'rename below will report locked and the servicing repair still runs.'
    )
    $script:Ledger.Symptoms.Add("$Name would not stop")
}

function Rename-Stale($Path,$Nice) {
    if (-not (Test-Path -LiteralPath $Path)) { Status $G.Skip $Nice 'not present' $Clr.Grey; return $false }
    $leaf = (Split-Path $Path -Leaf) + '.old.' + (Get-Date -Format 'yyyyMMdd_HHmmss')
    if ($Alkahest.DryRun) { Status $G.Skip $Nice "would rename → $leaf" $Clr.Grey; return $false }
    for ($i = 1; $i -le 4; $i++) {
        try {
            Rename-Item -LiteralPath $Path -NewName $leaf -ErrorAction Stop
            Status $G.Work $Nice "renamed → $leaf" $Clr.Cyan
            return $true
        } catch { Start-Sleep -Seconds ($i * 2) }
    }
    Status $G.Warn $Nice 'locked — not renamed, nothing deleted' $Clr.Orange
    return $false
}

# ═══════════════════════════════════════════════════════════════
#  DIAGNOSE  —  read the blockage before touching it
# ═══════════════════════════════════════════════════════════════

# OS build first so the banner DX line is populated before we print it
try {
    $os  = Get-CimInstance Win32_OperatingSystem -ErrorAction Stop
    $cv  = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -ErrorAction SilentlyContinue
    $disp = if ($cv.DisplayVersion) { $cv.DisplayVersion } else { $cv.ReleaseId }
    $script:Ledger.OSBuild = "$($os.Caption.Replace('Microsoft ','')) $disp (build $($cv.CurrentBuildNumber).$($cv.UBR))"
    $script:Ledger.UptimeDays = [Math]::Round(((Get-Date) - $os.LastBootUpTime).TotalDays,1)
    $script:Ledger.UptimeText = "$($script:Ledger.UptimeDays) days"
} catch { $script:Ledger.OSBuild = 'Windows (build detection failed)' }

Show-Banner
Show-Setup
if ($script:AlkahestAbort) { $global:AlkahestExit = 0; return }

$script:LogFile = $null
try {
    if (-not (Test-Path $Alkahest.LogRoot)) { New-Item -ItemType Directory -Path $Alkahest.LogRoot -Force | Out-Null }
    $script:LogFile = Join-Path $Alkahest.LogRoot ("alkahest_{0}_{1}.log" -f $env:COMPUTERNAME, (Get-Date -Format 'yyyyMMdd_HHmmss'))
    Start-Transcript -Path $script:LogFile -Append -ErrorAction SilentlyContinue | Out-Null
} catch { $script:LogFile = $null }

Rule 'DIAGNOSE'

# 1 — elevation / context
try {
    $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
    ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
} catch { $isAdmin = $false }
$isSystem = $script:Ledger.Context -eq 'NT AUTHORITY\SYSTEM'
if ($isSystem)    { Status $G.Ok 'elevation' 'SYSTEM' $Clr.Green }
elseif ($isAdmin) { Status $G.Ok 'elevation' 'Administrator' $Clr.Green }
else {
    Status $G.Fail 'elevation' 'NOT elevated — cannot proceed' $Clr.Red
    $script:Ledger.Proceed = $false
    $script:Ledger.Symptoms.Add('not run as admin/SYSTEM')
}

# 2 — uptime. a staged transaction often just needs the restart.
if ($script:Ledger.UptimeDays -gt 14) {
    Status $G.Warn 'uptime' "$($script:Ledger.UptimeText) — a staged servicing op may only need the reboot" $Clr.Orange
} elseif ($script:Ledger.UptimeText) {
    Status $G.Ok 'uptime' $script:Ledger.UptimeText $Clr.Green
}

# 3 — disk headroom
try {
    $vol = Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='$($env:SystemDrive)'" -ErrorAction Stop
    $script:Ledger.FreeGB = [Math]::Round($vol.FreeSpace/1GB,1)
    if ($script:Ledger.FreeGB -ge 20) {
        Status $G.Ok 'disk headroom' "$($script:Ledger.FreeGB) GB free" $Clr.Green
    } elseif ($script:Ledger.FreeGB -ge $Alkahest.MinFreeGB) {
        Status $G.Warn 'disk headroom' "$($script:Ledger.FreeGB) GB — tight for a feature update" $Clr.Orange
    } else {
        Status $G.Fail 'disk headroom' "$($script:Ledger.FreeGB) GB — below the $($Alkahest.MinFreeGB)GB floor" $Clr.Red
        $script:Ledger.Symptoms.Add("low disk: $($script:Ledger.FreeGB) GB free")
        $script:Ledger.Warnings.Add('low disk — updates will keep failing until space is reclaimed; that is Panacea PURGE work')
    }
} catch { Status $G.Skip 'disk headroom' 'unreadable' $Clr.Grey }

# 4 — endpoint protection. name it, because it changes what will work.
$pandaHits = @()
foreach ($sn in @('PandaAetherAgent','PSUAService','NanoServiceMain','PandaSecurityService','PandaAgent')) {
    try { if (Get-Service -Name $sn -ErrorAction Stop) { $pandaHits += $sn } } catch {}
}
if (Test-Path 'HKLM:\SOFTWARE\Panda Security') { $pandaHits += 'registry' }
if (Test-Path 'HKLM:\SOFTWARE\WOW6432Node\Panda Security') { $pandaHits += 'registry(x86)' }
if ($pandaHits.Count -gt 0) {
    $script:Ledger.PandaPresent = $true
    Status $G.Warn 'endpoint protection' ("Panda present — " + ($pandaHits -join ', ')) $Clr.Orange
    Note @(
        'the usual "reset windows update" recipe re-registers a dozen DLLs with',
        'regsvr32 and drives BITS with bitsadmin. Panda blocks or quarantines both,',
        'so ALKAHEST uses neither. if a hand-run of that recipe is how this box got',
        'here, the aborted half of it is likely part of the blockage.'
    )
} else {
    Status $G.Ok 'endpoint protection' 'no Panda signature found' $Clr.Green
}

# 5 — service posture
foreach ($svc in $script:SvcSpec) {
    try {
        $s = Get-Service -Name $svc.Name -ErrorAction Stop
        $wmi = Get-CimInstance Win32_Service -Filter "Name='$($svc.Name)'" -ErrorAction SilentlyContinue
        $start = if ($wmi) { $wmi.StartMode } else { 'unknown' }
        $script:SvcState[$svc.Name] = [pscustomobject]@{ Status = $s.Status; StartMode = $start }
        if ($start -eq 'Disabled') {
            Status $G.Fail $svc.Nice "DISABLED ($($s.Status)) — this alone stops updates" $Clr.Red
            $script:Ledger.Symptoms.Add("$($svc.Name) disabled")
        } else {
            Status $G.Ok $svc.Nice "$($s.Status) / $start" $Clr.Green
        }
    } catch { Status $G.Skip $svc.Nice 'not present on this build' $Clr.Grey }
}
try {
    $medic = Get-Service -Name 'WaaSMedicSvc' -ErrorAction Stop
    Status $G.Warn 'update medic' "$($medic.Status) — reverts manual WU changes by design" $Clr.Orange
} catch {}

# 6 — pending servicing. read-only. never cleared by hand.
$pendKeys = @(
    @{ P='HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending'; N='CBS RebootPending' },
    @{ P='HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\PackagesPending'; N='CBS PackagesPending' },
    @{ P='HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired'; N='WU RebootRequired' }
)
foreach ($k in $pendKeys) { if (Test-Path $k.P) { $script:Ledger.PendingBefore.Add($k.N) } }
if (Get-RegValue 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager' 'PendingFileRenameOperations') {
    $script:Ledger.PendingBefore.Add('PendingFileRenameOperations')
}
foreach ($x in @('pending.xml','reboot.xml','SessionsPending.xml')) {
    if (Test-Path -LiteralPath (Join-Path $env:windir "WinSxS\$x")) { $script:Ledger.PendingBefore.Add("WinSxS\$x") }
}
if ($script:Ledger.PendingBefore.Count -gt 0) {
    Status $G.Warn 'pending servicing' (($script:Ledger.PendingBefore) -join ', ') $Clr.Orange
    Note @(
        'read-only finding — ALKAHEST does not touch these. a staged CBS transaction',
        'completes on the next restart; clearing it by hand is how a machine ends up',
        'with a half-installed component store.'
    )
} else {
    Status $G.Ok 'pending servicing' 'nothing staged' $Clr.Green
}

# 7 — cache footprint
$script:SdPath  = Join-Path $env:windir 'SoftwareDistribution'
$script:CatPath = Join-Path $env:windir 'System32\catroot2'
$sdGB = Get-DirSizeGB $script:SdPath
$oldest = $null
try {
    $f = Get-ChildItem -LiteralPath (Join-Path $script:SdPath 'Download') -Recurse -Force -File -ErrorAction SilentlyContinue |
         Sort-Object LastWriteTime | Select-Object -First 1
    if ($f) { $oldest = [Math]::Round(((Get-Date) - $f.LastWriteTime).TotalDays,1) }
} catch {}
$sdNote = "$sdGB GB"
if ($null -ne $oldest) { $sdNote += " · oldest staged payload $oldest days old" }
if ($null -ne $oldest -and $oldest -gt 7) { Status $G.Warn 'softwaredistribution' $sdNote $Clr.Orange }
else { Status $G.Ok 'softwaredistribution' $sdNote $Clr.Green }

# 8 — BITS queue
$script:BitsCount = 0
if (Get-Command Get-BitsTransfer -ErrorAction SilentlyContinue) {
    try {
        $jobs = @(Get-BitsTransfer -AllUsers -ErrorAction Stop)
        $script:BitsCount = $jobs.Count
        $stuck = @($jobs | Where-Object { $_.JobState -in @('Error','TransientError','Suspended') })
        if ($stuck.Count -gt 0)    { Status $G.Warn 'BITS queue' "$($jobs.Count) jobs · $($stuck.Count) errored" $Clr.Orange }
        elseif ($jobs.Count -gt 0) { Status $G.Ok 'BITS queue' "$($jobs.Count) jobs · none errored" $Clr.Green }
        else                       { Status $G.Ok 'BITS queue' 'empty' $Clr.Green }
    } catch { Status $G.Skip 'BITS queue' 'unreadable (BITS may be stopped)' $Clr.Grey }
} else { Status $G.Skip 'BITS queue' 'cmdlets unavailable' $Clr.Grey }

# 9 — update policy. report, never assume it is wrong.
$polPath = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate'
$script:Policy = @{}
if (Test-Path $polPath) {
    foreach ($n in @('WUServer','WUStatusServer','TargetGroup','DoNotConnectToWindowsUpdateInternetLocations','DisableWindowsUpdateAccess','SetPolicyDrivenUpdateSourceForFeatureUpdates')) {
        $v = Get-RegValue $polPath $n
        if ($null -ne $v) { $script:Policy[$n] = $v }
    }
    $au = Get-RegValue "$polPath\AU" 'UseWUServer'
    if ($null -ne $au) { $script:Policy['UseWUServer'] = $au }
}
if ($script:Policy.Count -gt 0) {
    Status $G.Warn 'group policy (WU)' (($script:Policy.Keys | Sort-Object) -join ', ') $Clr.Orange
    $wsus = $script:Policy['WUServer']
    if ($wsus) {
        $reach = 'not tested'
        try {
            $u = [uri]$wsus
            $port = if ($u.Port -gt 0) { $u.Port } else { if ($u.Scheme -eq 'https') { 443 } else { 80 } }
            $t = Test-NetConnection -ComputerName $u.Host -Port $port -InformationLevel Quiet -WarningAction SilentlyContinue
            $reach = if ($t) { 'reachable' } else { 'UNREACHABLE' }
        } catch { $reach = 'could not test' }
        if ($reach -eq 'UNREACHABLE') {
            Status $G.Fail 'WSUS endpoint' "$wsus — UNREACHABLE" $Clr.Red
            Note @(
                'pointed at a WSUS server it cannot reach. that is exactly the symptom',
                'being chased, and no amount of cache clearing fixes it. confirm with',
                'whoever owns this tenant patching before changing anything.'
            )
            $script:Ledger.Symptoms.Add('WSUS unreachable')
            $script:Ledger.Warnings.Add("WSUS UNREACHABLE — $wsus; the fix is on the server or the network path, not this endpoint")
        } else {
            Status $G.Ok 'WSUS endpoint' "$wsus — $reach" $Clr.Green
        }
    }
} else {
    Status $G.Ok 'group policy (WU)' 'no WSUS/GPO update keys set' $Clr.Green
}

# 10 — MDM policy. Intune rings do NOT live in the key above; without this read,
#      a ring-managed box reports "no policy" and lies to the tech.
$mdmPath = 'HKLM:\SOFTWARE\Microsoft\PolicyManager\default\Update'
$script:MdmPolicy = @()
if (Test-Path $mdmPath) {
    try { $script:MdmPolicy = @(Get-ChildItem -Path $mdmPath -ErrorAction Stop | Select-Object -ExpandProperty PSChildName) } catch {}
}
if ($script:MdmPolicy.Count -gt 0) {
    Status $G.Warn 'MDM policy (Intune)' "$($script:MdmPolicy.Count) settings under PolicyManager" $Clr.Orange
    Note @(
        (($script:MdmPolicy | Sort-Object | Select-Object -First 10) -join ', '),
        'read from PolicyManager\default\Update. neither ALKAHEST nor the clear-policy',
        'option touches this key. deferrals, pauses and a pinned target release set here',
        'hold updates back and look exactly like a stuck stack — check the assigned ring.'
    )
} else {
    Status $G.Ok 'MDM policy (Intune)' 'no PolicyManager update settings' $Clr.Green
}

# 11 — orchestrator tasks
$script:BadTasks = @()
if (Get-Command Get-ScheduledTask -ErrorAction SilentlyContinue) {
    try {
        $tasks = @(Get-ScheduledTask -TaskPath '\Microsoft\Windows\UpdateOrchestrator\*' -ErrorAction Stop)
        $script:BadTasks = @($tasks | Where-Object { $_.State -eq 'Disabled' })
        if ($script:BadTasks.Count -gt 0) { Status $G.Warn 'orchestrator tasks' "$($script:BadTasks.Count) of $($tasks.Count) disabled" $Clr.Orange }
        else { Status $G.Ok 'orchestrator tasks' "$($tasks.Count) present · none disabled" $Clr.Green }
    } catch { Status $G.Skip 'orchestrator tasks' 'unreadable' $Clr.Grey }
}

# 12 — what the client actually logged
$script:WuErrCount = 0
$knownCodes = @{
    '0x80070020' = 'file in use — another process (often AV) holds a staged file'
    '0x80073712' = 'component store corruption — RestoreHealth is the fix'
    '0x800f0922' = 'reserved partition too small, or cannot reach the update endpoint'
    '0x80240034' = 'download failed — BITS or the source endpoint'
    '0x8024402c' = 'cannot reach the configured update source (WSUS/proxy)'
    '0x80244022' = 'update source returned HTTP 503'
    '0x80070005' = 'access denied — permissions or endpoint protection blocked it'
    '0x800705b4' = 'operation timed out'
    '0x80248007' = 'datastore missing or corrupt — the cache rename is the fix'
}
try {
    $ev = Get-WinEvent -FilterHashtable @{ LogName='Microsoft-Windows-WindowsUpdateClient/Operational'; Level=2 } -MaxEvents 15 -ErrorAction Stop
    $script:WuErrCount = @($ev).Count
    $codes = @()
    foreach ($x in $ev) {
        $m = [regex]::Match($x.Message,'0x[0-9A-Fa-f]{8}')
        if ($m.Success) { $codes += $m.Value.ToLower() }
    }
    $codes = @($codes | Select-Object -Unique)
    if ($script:WuErrCount -gt 0) {
        Status $G.Warn 'recent WU errors' "$($script:WuErrCount) in the operational log" $Clr.Orange
        $lines = @()
        foreach ($c in $codes) {
            if ($knownCodes.ContainsKey($c)) { $lines += "$c  $($knownCodes[$c])" } else { $lines += "$c  (not in the local table)" }
        }
        if ($lines.Count -gt 0) { Note $lines }
    } else {
        Status $G.Ok 'recent WU errors' 'none in the operational log' $Clr.Green
    }
} catch { Status $G.Skip 'recent WU errors' 'log unreadable' $Clr.Grey }

# 13 — component store health (read-only)
$script:ImageSick = $false
$chk = Invoke-Guarded -File 'DISM.exe' -Arguments '/Online /Cleanup-Image /CheckHealth' -Label 'checking component store' -TimeoutSec $Alkahest.DismCheckTimeoutSec
if ($chk.Skipped)      { Status $G.Skip 'component store' 'skipped by operator' $Clr.Grey }
elseif ($chk.TimedOut) { Status $G.Warn 'component store' 'timed out' $Clr.Orange }
elseif ($chk.StdOut -match 'No component store corruption') { Status $G.Ok 'component store' 'no corruption detected' $Clr.Green }
elseif ($chk.StdOut -match 'repairable') {
    $script:ImageSick = $true
    Status $G.Warn 'component store' 'repairable corruption detected' $Clr.Orange
    $script:Ledger.Symptoms.Add('component store corruption')
} else { Status $G.Warn 'component store' "DISM exit $($chk.ExitCode) — inconclusive" $Clr.Orange }

# 14 — packages parked mid-transaction
$script:StuckPkgs = @()
$pkg = Invoke-Guarded -File 'DISM.exe' -Arguments '/Online /Get-Packages /Format:Table' -Label 'sweeping package state' -TimeoutSec $Alkahest.PkgScanTimeoutSec
if (-not $pkg.Skipped -and $pkg.StdOut) {
    foreach ($l in ($pkg.StdOut -split "`n")) {
        if ($l -match 'Install Pending|Uninstall Pending|Superseded Pending') { $script:StuckPkgs += $l.Trim() }
    }
}
if ($script:StuckPkgs.Count -gt 0) {
    Status $G.Warn 'stuck packages' "$($script:StuckPkgs.Count) in a pending state" $Clr.Orange
    Note @(
        'a package in Install Pending is waiting on a restart to finish its',
        'transaction. that is a reboot, not a reset. still pending after a clean',
        'restart means the component store is the problem.'
    )
    $script:Ledger.Symptoms.Add("$($script:StuckPkgs.Count) packages pending")
} elseif (-not $pkg.Skipped) {
    Status $G.Ok 'stuck packages' 'none pending' $Clr.Green
}

if (-not $script:Ledger.Proceed) {
    Rule 'HALTED'
    Status $G.Fail 'alkahest' 'run this from an elevated prompt — nothing was touched' $Clr.Red
    try { Stop-Transcript -ErrorAction SilentlyContinue | Out-Null } catch {}
    $global:AlkahestExit = 2
    return
}

# ═══════════════════════════════════════════════════════════════
#  QUENCH  —  halt the update stack before dissolving anything
# ═══════════════════════════════════════════════════════════════
Rule 'QUENCH'
foreach ($n in @('UsoSvc','DoSvc','wuauserv','bits','cryptsvc','msiserver')) {
    $nice = ($script:SvcSpec | Where-Object { $_.Name -eq $n }).Nice
    if (-not $nice) { $nice = $n }
    Stop-UpdateService $n $nice
}

# ═══════════════════════════════════════════════════════════════
#  DISSOLVE  —  rename the poisoned caches. nothing is deleted.
# ═══════════════════════════════════════════════════════════════
Rule 'DISSOLVE'

# in-box BITS cmdlets, deliberately not bitsadmin.exe
if (Get-Command Remove-BitsTransfer -ErrorAction SilentlyContinue) {
    try {
        $jobs = @(Get-BitsTransfer -AllUsers -ErrorAction Stop)
        if ($jobs.Count -eq 0)    { Status $G.Ok 'BITS queue' 'already empty' $Clr.Green }
        elseif ($Alkahest.DryRun) { Status $G.Skip 'BITS queue' "would cancel $($jobs.Count) jobs" $Clr.Grey }
        else {
            $jobs | Remove-BitsTransfer -ErrorAction SilentlyContinue
            Status $G.Work 'BITS queue' "cancelled $($jobs.Count) jobs" $Clr.Cyan
        }
    } catch { Status $G.Warn 'BITS queue' 'could not enumerate transfers' $Clr.Orange }
} else { Status $G.Skip 'BITS queue' 'cmdlets unavailable' $Clr.Grey }

$sdRenamed = Rename-Stale $script:SdPath 'softwaredistribution'
if (-not $sdRenamed -and (Test-Path -LiteralPath $script:SdPath) -and -not $Alkahest.DryRun) {
    foreach ($child in @('Download','DataStore')) {
        $null = Rename-Stale (Join-Path $script:SdPath $child) "  fallback $child"
    }
    if ($Alkahest.ScheduleLocked) {
        try {
            $key = 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager'
            $cur = @(Get-RegValue $key 'PendingFileRenameOperations')
            $src = '\??\' + $script:SdPath
            $dst = '!\??\' + $script:SdPath + '.old.' + (Get-Date -Format 'yyyyMMdd_HHmmss')
            Set-ItemProperty -Path $key -Name 'PendingFileRenameOperations' -Value ($cur + @($src,$dst)) -Type MultiString -ErrorAction Stop
            Status $G.Work 'queued for next boot' 'rename scheduled via PendingFileRenameOperations' $Clr.Cyan
            $script:Ledger.Warnings.Add('A RENAME IS QUEUED FOR NEXT BOOT — it only happens if the machine is actually restarted')
        } catch { Status $G.Fail 'queued for next boot' 'could not write the pending-rename key' $Clr.Red }
    }
}

$null = Rename-Stale $script:CatPath 'catroot2'

if (Get-Command Delete-DeliveryOptimizationCache -ErrorAction SilentlyContinue) {
    if ($Alkahest.DryRun) { Status $G.Skip 'delivery optimization' 'would purge cache' $Clr.Grey }
    else {
        try {
            Delete-DeliveryOptimizationCache -Force -ErrorAction Stop
            Status $G.Work 'delivery optimization' 'cache purged' $Clr.Cyan
        } catch { Status $G.Warn 'delivery optimization' 'refused (service state or policy)' $Clr.Orange }
    }
} else { Status $G.Skip 'delivery optimization' 'cmdlet not on this build' $Clr.Grey }

# the deliberate omissions, stated out loud rather than silently skipped
Status $G.Skip 'regsvr32 re-register' 'not attempted by design — Panda blocks it' $Clr.Grey
Status $G.Skip 'bitsadmin/wusa/sc' 'not attempted by design — EDR-flagged LOLBins' $Clr.Grey
Status $G.Ok  'sacred' 'user files + recycle bin — untouched, always' $Clr.Green

# ═══════════════════════════════════════════════════════════════
#  RECONSTITUTE  —  put the machinery back the way Windows expects
# ═══════════════════════════════════════════════════════════════
Rule 'RECONSTITUTE'
$repairResult = 'not run'      # not run | repaired | failed | skipped
$sfcResult    = 'not run'

foreach ($svc in $script:SvcSpec) {
    $st = $script:SvcState[$svc.Name]
    if (-not $st) { continue }
    if ($st.StartMode -eq 'Disabled' -or ($st.StartMode -eq 'Auto' -and $svc.Want -eq 'Manual')) {
        if ($Alkahest.DryRun) { Status $G.Skip "$($svc.Nice) start" "would set $($svc.Want)" $Clr.Grey; continue }
        try {
            Set-Service -Name $svc.Name -StartupType $svc.Want -ErrorAction Stop
            Status $G.Work "$($svc.Nice) start" "$($st.StartMode) → $($svc.Want)" $Clr.Cyan
        } catch { Status $G.Warn "$($svc.Nice) start" "could not set $($svc.Want)" $Clr.Orange }
    } else {
        Status $G.Ok "$($svc.Nice) start" $st.StartMode $Clr.Green
    }
}

foreach ($t in $script:BadTasks) {
    if ($Alkahest.DryRun) { Status $G.Skip "task $($t.TaskName)" 'would enable' $Clr.Grey; continue }
    try {
        Enable-ScheduledTask -TaskName $t.TaskName -TaskPath $t.TaskPath -ErrorAction Stop | Out-Null
        Status $G.Work "task $($t.TaskName)" 'enabled' $Clr.Cyan
    } catch { Status $G.Warn "task $($t.TaskName)" 'refused — held by policy or Update Medic' $Clr.Orange }
}

if ($Alkahest.ClearPolicy -and $script:Policy.Count -gt 0) {
    $backup = Join-Path $Alkahest.LogRoot ("wu_policy_{0}_{1}.reg" -f $env:COMPUTERNAME, (Get-Date -Format 'yyyyMMdd_HHmmss'))
    if ($Alkahest.DryRun) { Status $G.Skip 'group policy (WU)' "would back up to $backup then remove" $Clr.Grey }
    else {
        $exp = Invoke-Guarded -File 'reg.exe' -Arguments "export `"HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate`" `"$backup`" /y" -Label 'exporting policy backup' -TimeoutSec 120
        if ($exp.ExitCode -eq 0) {
            try {
                Remove-Item -Path $polPath -Recurse -Force -ErrorAction Stop
                Status $G.Work 'group policy (WU)' "removed · backup at $backup" $Clr.Cyan
                Note @(
                    'do not assume this reapplies on its own.',
                    'AD GPO  — yes, own cycle (90 min default) or gpupdate /force.',
                    'Intune rings — different key, never touched here.',
                    'Intune ADMX — lands in this key, and MDM is not documented to re-push',
                    '  a locally deleted value. re-save or re-assign the profile to force it.',
                    'restore path is the .reg above. device check-in is ~8h, floor 6.5h.'
                )
                $script:Ledger.Warnings.Add("WU GROUP POLICY REMOVED — restore from $backup if that was wrong")
            } catch { Status $G.Fail 'group policy (WU)' 'export succeeded but removal was refused' $Clr.Red }
        } else { Status $G.Fail 'group policy (WU)' 'backup export failed — nothing was removed' $Clr.Red }
    }
}

if ($Alkahest.ServicingRepair -and ($script:ImageSick -or $script:StuckPkgs.Count -gt 0 -or $script:WuErrCount -gt 0)) {
    $r = Invoke-Guarded -File 'DISM.exe' -Arguments '/Online /Cleanup-Image /RestoreHealth' -Label 'DISM RestoreHealth' -TimeoutSec $Alkahest.DismRestoreTimeoutSec -ShowNative
    if ($r.Skipped)      { $repairResult = 'skipped'; Status $G.Skip 'DISM restorehealth' 'skipped by operator' $Clr.Grey }
    elseif ($r.ExitCode -eq 0) { $repairResult = 'repaired'; Status $G.Work 'DISM restorehealth' 'completed' $Clr.Cyan }
    else {
        $repairResult = 'failed'
        Status $G.Fail 'DISM restorehealth' "exit $($r.ExitCode)" $Clr.Red
        $script:Ledger.Warnings.Add('RESTOREHEALTH FAILED — with no reachable source DISM has nowhere to pull payloads; an install.wim of the same build passed with /Source is the offline path')
    }
    if ($repairResult -ne 'skipped') {
        # -ShowNative means stdout is NOT redirected, so the verdict cannot come from
        # StdOut. Read the CBS.log delta instead — same technique as Panacea's MEND.
        $sfcArgs = if ($Alkahest.DryRun) { '/verifyonly' } else { '/scannow' }
        Status $G.Work 'sfc' 'verifying system files — SFC output follows' $Clr.Cyan
        Write-Host ''
        $cbsPath = "$env:SystemRoot\Logs\CBS\CBS.log"
        $cbsBefore = if (Test-Path $cbsPath) { (Get-Item $cbsPath).Length } else { 0 }

        $s = Invoke-Guarded -File "$env:SystemRoot\System32\sfc.exe" -Arguments $sfcArgs -Label 'sfc' -TimeoutSec $Alkahest.SfcTimeoutSec -ShowNative

        if ($s.Skipped) { $sfcResult = 'skipped'; Status $G.Skip 'sfc' 'skipped by operator' $Clr.Grey }
        elseif ($s.TimedOut) { $sfcResult = 'timed out'; Status $G.Fail 'sfc' 'timed out' $Clr.Red }
        else {
            $cbsNew = ''
            try {
                if (Test-Path $cbsPath) {
                    $fs = [IO.File]::Open($cbsPath,'Open','Read','ReadWrite')
                    [void]$fs.Seek($cbsBefore,'Begin')
                    $rdr = New-Object IO.StreamReader($fs)
                    $cbsNew = $rdr.ReadToEnd()
                    $rdr.Close(); $fs.Close()
                }
            } catch {}
            if ($cbsNew -match 'Cannot repair member file' -or $cbsNew -match '\[SR\].+cannot repair') {
                $sfcResult = 'unfixable'
                Status $G.Fail 'sfc' 'found damage it could NOT fix' $Clr.Red
                $script:Ledger.Symptoms.Add('SFC found unfixable corruption')
                $script:Ledger.Warnings.Add('SFC FOUND UNFIXABLE DAMAGE — investigate before reimage')
            } elseif ($cbsNew -match '\[SR\] Repairing \d+ components' -and $cbsNew -notmatch 'Repairing 0 components') {
                $sfcResult = 'repaired'
                Status $G.Work 'sfc' 'violations found and repaired' $Clr.Cyan
            } elseif ($cbsNew -match '\[SR\] Verify complete' -or $s.ExitCode -eq 0) {
                $sfcResult = 'clean'
                Status $G.Ok 'sfc' 'no integrity violations' $Clr.Green
            } else {
                $sfcResult = "exit $($s.ExitCode)"
                Status $G.Warn 'sfc' "finished (exit $($s.ExitCode)) — verdict unclear, see CBS.log" $Clr.Orange
            }
        }
    }
} else {
    Status $G.Skip 'servicing repair' 'store looked clean, or disabled in setup' $Clr.Grey
}

if ($Alkahest.RunWinSxS) {
    $wsx = Invoke-Guarded -File 'DISM.exe' -Arguments '/Online /Cleanup-Image /StartComponentCleanup' -Label 'component cleanup' -TimeoutSec $Alkahest.WinSxSTimeoutSec -ShowNative
    if ($wsx.Skipped)          { Status $G.Skip 'winsxs cleanup' 'skipped by operator' $Clr.Grey }
    elseif ($wsx.ExitCode -eq 0) { Status $G.Work 'winsxs cleanup' 'superseded payloads reclaimed' $Clr.Cyan }
    elseif ($wsx.ExitCode -eq 5) { Status $G.Ok 'winsxs cleanup' 'already trimmed — nothing to clean' $Clr.Green }
    else { Status $G.Warn 'winsxs cleanup' "exit $($wsx.ExitCode)" $Clr.Orange }
} else {
    Status $G.Skip 'winsxs cleanup' 'disabled in config' $Clr.Grey
}

# ═══════════════════════════════════════════════════════════════
#  PROGNOSIS  —  restart the stack, ask for a scan, then the label:
#                plain roll-up, conditional orange sticker.
# ═══════════════════════════════════════════════════════════════
Rule 'PROGNOSIS'

foreach ($n in @('cryptsvc','bits','wuauserv','UsoSvc','DoSvc')) {
    if (-not $script:SvcState.ContainsKey($n)) { continue }
    if ($Alkahest.DryRun) { Status $G.Skip "start $n" 'would start' $Clr.Grey; continue }
    try {
        Start-Service -Name $n -ErrorAction Stop
        Status $G.Work "start $n" 'running' $Clr.Cyan
    } catch {
        $s = Get-Service -Name $n -ErrorAction SilentlyContinue
        if ($s -and $s.StartType -eq 'Manual') { Status $G.Ok "start $n" 'trigger-start, runs on demand' $Clr.Green }
        else { Status $G.Warn "start $n" 'did not start' $Clr.Orange }
    }
}

# ask for a detection pass. report that it was ASKED FOR, never that the box is
# current — under SYSTEM the COM search can no-op silently and "current" would lie.
$scanAsked = $false
if (-not $Alkahest.DryRun) {
    try {
        $au = New-Object -ComObject Microsoft.Update.AutoUpdate
        $au.DetectNow()
        $scanAsked = $true
        Status $G.Work 'detection pass' 'requested via Microsoft.Update.AutoUpdate' $Clr.Cyan
    } catch {
        $uso = Join-Path $env:windir 'System32\UsoClient.exe'
        if (Test-Path -LiteralPath $uso) {
            $u = Invoke-Guarded -File $uso -Arguments 'StartScan' -Label 'orchestrator scan' -TimeoutSec 120
            if ($u.ExitCode -eq 0) { $scanAsked = $true; Status $G.Work 'detection pass' 'requested via UsoClient' $Clr.Cyan }
            else { Status $G.Warn 'detection pass' 'scan request returned an error' $Clr.Orange }
        } else { Status $G.Warn 'detection pass' 'no way to request a scan on this build' $Clr.Orange }
    }
    if ($scanAsked) {
        $script:Ledger.Warnings.Add('SCAN REQUESTED, NOT VERIFIED — watch Settings > Windows Update on the frontstage session before calling this fixed')
    }
}

foreach ($k in $pendKeys) { if (Test-Path $k.P) { $script:Ledger.PendingAfter.Add($k.N) } }
if (Get-RegValue 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager' 'PendingFileRenameOperations') {
    $script:Ledger.PendingAfter.Add('PendingFileRenameOperations')
}

$rebootNeeded = ($script:Ledger.PendingAfter.Count -gt 0) -or ($script:StuckPkgs.Count -gt 0) -or
                ($repairResult -eq 'repaired') -or ($sfcResult -eq 'repaired')

# overall status tag — same three-state language as Panacea's label
if ($repairResult -eq 'failed' -or $sfcResult -eq 'unfixable' -or ($script:Ledger.Symptoms.Count -gt 0 -and $repairResult -eq 'failed')) {
    $tag = "$($G.Bell) ATTENTION"; $tagColor = $Clr.Orange
} elseif ($sdRenamed -or $repairResult -eq 'repaired' -or $sfcResult -eq 'repaired' -or $script:BitsCount -gt 0) {
    $tag = "$($G.Staff) DISSOLVED"; $tagColor = $Clr.Cyan
} else {
    $tag = "$($G.Ok.Trim('[]')) CLEAR"; $tagColor = $Clr.Green
    if ($script:VT) { $tag = "$($G.Staff) CLEAR" }
}
if ($Alkahest.DryRun) { $tag = "$($G.Skip) DRY RUN"; $tagColor = $Clr.Grey }

$bar = '═' * 62; $mid = '─' * 62
if (-not $script:VT) { $bar = '=' * 62; $mid = '-' * 62 }
Write-Host ''
Write-Host (Paint "╔$bar╗" -Fg $tagColor)
$title = "  $($G.Rx)  PROGNOSIS"
$pad = 62 - $title.Length - $tag.Length - 2
if ($pad -lt 1) { $pad = 1 }
Write-Host (Paint $title -Fg $tagColor) -NoNewline
Write-Host (Paint ((' ' * $pad) + $tag + '  ') -Fg $tagColor)
Write-Host (Paint "╟$mid╢" -Fg $Clr.Grey)

# --- plain roll-up (flavor in labels, plain nouns in values) -----
function Roll($label,$value) {
    $dots = '.' * [Math]::Max(3, 16 - $label.Length)
    Write-Host (Paint "  $label $dots $value" -Fg $Clr.Grey)
}
if ($sdRenamed) { Roll 'caches' 'softwaredistribution + catroot2 renamed' }
else            { Roll 'caches' 'not renamed — locked or already clean' }
switch ($repairResult) {
    'repaired' { Roll 'store repair' 'completed (DISM)' }
    'failed'   { Roll 'store repair' 'FAILED — see log' }
    'skipped'  { Roll 'store repair' 'SKIPPED by operator' }
    default    { Roll 'store repair' 'not needed' }
}
Roll 'sfc' $sfcResult
if ($script:BitsCount -gt 0) { Roll 'bits queue' "$($script:BitsCount) jobs cleared" } else { Roll 'bits queue' 'empty' }
if ($script:MdmPolicy.Count -gt 0) { Roll 'policy' "MDM ring active ($($script:MdmPolicy.Count) settings)" }
elseif ($script:Policy.Count -gt 0) { Roll 'policy' 'group policy present' }
else { Roll 'policy' 'none set' }
if ($scanAsked) { Roll 'scan' 'requested — NOT verified' } else { Roll 'scan' 'not requested' }
if ($script:Ledger.UptimeText) { Roll 'uptime' $script:Ledger.UptimeText }
Roll 'free space' "$($script:Ledger.FreeGB) GB"

# --- auxiliary warning strip — CONDITIONAL. absence = relief. ----
$auxWarnings = @()
if ($rebootNeeded) {
    $why = @()
    if ($script:StuckPkgs.Count -gt 0) { $why += "$($script:StuckPkgs.Count) pending packages" }
    if ($script:Ledger.PendingAfter.Count -gt 0 -and $script:StuckPkgs.Count -eq 0) { $why += 'staged servicing' }
    if ($repairResult -eq 'repaired' -or $sfcResult -eq 'repaired') { $why += 'repairs' }
    $auxWarnings += "RESTART REQUIRED — " + ($why -join ' + ') + " will not complete until the machine is rebooted"
}
foreach ($w in $script:Ledger.Warnings) { $auxWarnings += $w.ToUpper() }

if ($auxWarnings.Count -gt 0) {
    Write-Host (Paint "╟$mid╢" -Fg $Clr.Grey)
    if ($script:VT) {
        Write-Host (Paint ("  {0}{0} AUXILIARY WARNINGS {0}{0}" -f [char]0x2593) -Fg $Clr.Orange)
    } else {
        Write-Host "  ## AUXILIARY WARNINGS ##"
    }
    foreach ($w in $auxWarnings) {
        if ($script:VT) {
            Write-Host (Paint "  $($G.Bell) $w " -Fg $Clr.Black -Bg $Clr.Orange)
        } else {
            Write-Host "  !! $w !!"
        }
    }
} else {
    Write-Host (Paint "╟$mid╢" -Fg $Clr.Grey)
    Write-Host (Paint "  dispensed by ALKAHEST · keep out of reach of end users" -Fg $Clr.Grey)
}
Write-Host (Paint "╚$bar╝" -Fg $tagColor)

# --- machine-readable summary for RMM ingest ---------------------
$script:Ledger.Ended = Get-Date
$summary = [ordered]@{
    host           = $script:Ledger.Host
    session        = $script:Ledger.Session
    os             = $script:Ledger.OSBuild
    started        = $script:Ledger.Started.ToString('s')
    ended          = $script:Ledger.Ended.ToString('s')
    dry_run        = [bool]$Alkahest.DryRun
    uptime_days    = $script:Ledger.UptimeDays
    free_gb        = $script:Ledger.FreeGB
    panda_present  = [bool]$script:Ledger.PandaPresent
    caches_renamed = [bool]$sdRenamed
    bits_cleared   = $script:BitsCount
    store_repair   = $repairResult
    sfc            = $sfcResult
    gpo_policy     = @($script:Policy.Keys)
    mdm_policy     = @($script:MdmPolicy)
    stuck_packages = $script:StuckPkgs.Count
    wu_errors      = $script:WuErrCount
    scan_requested = [bool]$scanAsked
    pending_before = @($script:Ledger.PendingBefore)
    pending_after  = @($script:Ledger.PendingAfter)
    reboot_req     = [bool]$rebootNeeded
    symptoms       = @($script:Ledger.Symptoms)
    status         = ($tag -replace '[^A-Za-z]','')
}
try {
    if ($script:LogFile) {
        $jsonPath = [IO.Path]::ChangeExtension($script:LogFile,'json')
        ($summary | ConvertTo-Json -Depth 4) | Out-File -FilePath $jsonPath -Encoding UTF8
    }
} catch {}

# exit code contract: 0 clear, 1 reboot-needed, 2 needs-attention
# stored in $global:AlkahestExit so RMM can read it; NO exit call so backstage stays alive
try { Stop-Transcript -ErrorAction SilentlyContinue | Out-Null } catch {}
if ($repairResult -eq 'failed' -or $sfcResult -eq 'unfixable') { $global:AlkahestExit = 2 }
elseif ($rebootNeeded) { $global:AlkahestExit = 1 }
else { $global:AlkahestExit = 0 }
$exitVal = $global:AlkahestExit
$logPath = $script:LogFile
Write-Host ''
Write-Host (Paint "   dispensary closed  ·  `$AlkahestExit = $exitVal  ·  log: $logPath" -Fg $Clr.Grey)
'@

[ScriptBlock]::Create($alkahest).Invoke()
