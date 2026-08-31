$alkahest = @'
#Requires -Version 5.1
#===============================================================================
#  ALKAHEST  -  the universal solvent
#  Sibling to Panacea. Dissolves stuck / pending Windows Updates.
#
#  Constraints (by design, do not "improve" these away):
#    * ONE copy-paste. No modules to install, no downloads, no helper scripts.
#    * PowerShell 5.1 target. In-box cmdlets only.
#    * Paste-safe: whole body is a here-string, parsed once by ScriptBlock::Create.
#    * No -EncodedCommand, no regsvr32, no bitsadmin, no wusa, no sc.exe.
#      Those are the classic LOLBins Panda Adaptive Defense flags. See DESIGN NOTE.
#    * Nothing is deleted. Caches are RENAMED. User files are untouchable.
#    * No forced reboot. Ever. It recommends, loudly, and stops there.
#    * Infinite timeouts by default. Slow boxes are the normal case.
#    * Graceful degradation: a blocked step is reported as BLOCKED, not fatal.
#    * No exit. $global:AlkahestExit carries the verdict so the host survives.
#===============================================================================

#--- CONFIG --------------------------------------------------------------------
$script:Cfg = [ordered]@{
    DryRun            = $false   # narrate every action, change nothing
    TimeoutSec        = 0        # 0 = infinite; per-operation S-key bail always live
    ServicingRepair   = $true    # DISM RestoreHealth + SFC when the image looks sick
    ComponentCleanup  = $false   # DISM StartComponentCleanup (never /ResetBase)
    ClearPolicyKeys   = $false   # OFF. Clients legitimately run WSUS/Intune policy.
    ScheduleLocked    = $false   # OFF. Queue locked renames for next boot.
    NoColor           = $false
}

$script:Name    = 'ALKAHEST'
$script:Version = '1.0'
$script:Started = Get-Date
$script:Stamp   = $script:Started.ToString('yyyyMMdd_HHmmss')
$script:Root    = Join-Path $env:ProgramData 'Alkahest'
$script:LogFile = Join-Path $script:Root ("alkahest_{0}_{1}.log" -f $env:COMPUTERNAME, $script:Stamp)
$script:Ledger      = New-Object System.Collections.ArrayList
$script:Advisories  = New-Object System.Collections.ArrayList
$script:SvcPrior    = @{}
$global:AlkahestExit = 0

#--- PRESENTATION --------------------------------------------------------------
$ESC = [char]27
function Paint {
    param([int]$R,[int]$G,[int]$B,[string]$Text)
    if ($script:Cfg.NoColor) { return $Text }
    "$ESC[38;2;$R;$G;${B}m$Text$ESC[0m"
}
function Bone  { param([string]$t) Paint 216 210 196 $t }
function Dim   { param([string]$t) Paint 107 107 120 $t }
function Amber { param([string]$t) Paint 208 138  58 $t }
function Herb  { param([string]$t) Paint  95 179 122 $t }
function Blood { param([string]$t) Paint 201  72  75 $t }
function Vitri { param([string]$t) Paint  74 166 184 $t }
function Iris  { param([string]$t) Paint 138 110 168 $t }

function Write-Tier {
    param([string]$Name,[string]$Gloss)
    $bar = '-' * [Math]::Max(4, 72 - $Name.Length - $Gloss.Length - 8)
    Write-Host ''
    Write-Host ("== " + (Iris $Name) + " " + (Dim $Gloss) + " " + (Dim $bar))
}

function Write-Step {
    param([string]$Label,[string]$Status,[string]$Detail = '')
    $glyph = switch ($Status) {
        'ok'      { Herb  '[+]' }
        'fixed'   { Vitri '[~]' }
        'warn'    { Amber '[!]' }
        'blocked' { Amber '[/]' }
        'fail'    { Blood '[x]' }
        'dry'     { Dim   '[.]' }
        'skip'    { Dim   '[-]' }
        default   { Dim   '[ ]' }
    }
    $pad = ($Label + ' ').PadRight(30, '.')
    Write-Host ("   $glyph " + (Bone $pad) + ' ' + (Dim $Detail))
    $null = $script:Ledger.Add([pscustomobject]@{
        Tier = $script:CurrentTier; Step = $Label; Status = $Status; Detail = $Detail
    })
}

function Add-Advisory {
    param([string]$Title,[string]$Body)
    $null = $script:Advisories.Add([pscustomobject]@{ Title = $Title; Body = $Body })
}

function Test-SkipKey {
    try {
        if ([Console]::KeyAvailable) {
            $k = [Console]::ReadKey($true)
            if ($k.Key -eq 'S') { return $true }
        }
    } catch { }
    return $false
}

#--- GUARDED PROCESS RUNNER ----------------------------------------------------
# Synchronous char-level read. Deliberately NOT Register-ObjectEvent: that pattern
# leaks subscriptions into the host runspace when anything between register and
# unregister throws, which bit Panacea. This blocks on Read() instead, which also
# lets DISM/SFC carriage-return progress bars render live.
function Invoke-Guarded {
    param(
        [Parameter(Mandatory=$true)][string]$FilePath,
        [string]$Arguments = '',
        [Parameter(Mandatory=$true)][string]$Label,
        [int]$TimeoutSec = -1,
        [switch]$Quiet
    )
    if ($TimeoutSec -lt 0) { $TimeoutSec = $script:Cfg.TimeoutSec }
    if ($script:Cfg.DryRun) {
        Write-Step $Label 'dry' "would run: $FilePath $Arguments"
        return [pscustomobject]@{ ExitCode = 0; Output = ''; Skipped = $true; TimedOut = $false }
    }

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName               = $FilePath
    $psi.Arguments              = $Arguments
    $psi.UseShellExecute        = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError  = $true
    $psi.CreateNoWindow         = $true

    $p  = New-Object System.Diagnostics.Process
    $p.StartInfo = $psi
    $all  = New-Object System.Text.StringBuilder
    $line = New-Object System.Text.StringBuilder
    $timedOut = $false
    $bailed   = $false

    Write-Host ("   " + (Dim "> $Label") + (Dim "   (S = skip this step)"))
    $null = $p.Start()
    $sw = [System.Diagnostics.Stopwatch]::StartNew()

    try {
        while ($true) {
            $c = $p.StandardOutput.Read()
            if ($c -lt 0) { break }
            $ch = [char]$c
            if ($ch -eq "`r" -or $ch -eq "`n") {
                $text = $line.ToString().Trim()
                $null = $line.Clear()
                if ($text.Length -gt 0) {
                    $null = $all.AppendLine($text)
                    if (-not $Quiet) { Write-Host ("     " + (Dim $text)) }
                }
            } else {
                $null = $line.Append($ch)
            }
            if (Test-SkipKey) { $bailed = $true; break }
            if ($TimeoutSec -gt 0 -and $sw.Elapsed.TotalSeconds -gt $TimeoutSec) { $timedOut = $true; break }
        }

        if ($bailed -or $timedOut) {
            try { if (-not $p.HasExited) { $p.Kill() } } catch { }
            $status = if ($bailed) { 'skip' } else { 'warn' }
            $why    = if ($bailed) { 'skipped by operator' } else { "timed out after ${TimeoutSec}s" }
            Write-Step $Label $status $why
            return [pscustomobject]@{ ExitCode = -1; Output = $all.ToString(); Skipped = $true; TimedOut = $timedOut }
        }

        $p.WaitForExit()
        $err = ''
        try { $err = $p.StandardError.ReadToEnd() } catch { }
        if ($err) { $null = $all.AppendLine($err.Trim()) }
        return [pscustomobject]@{ ExitCode = $p.ExitCode; Output = $all.ToString(); Skipped = $false; TimedOut = $false }
    }
    finally {
        try { $p.Dispose() } catch { }
    }
}

#--- SMALL HELPERS -------------------------------------------------------------
function Test-Admin {
    try {
        $id = [Security.Principal.WindowsIdentity]::GetCurrent()
        (New-Object Security.Principal.WindowsPrincipal $id).IsInRole(
            [Security.Principal.WindowsBuiltInRole]::Administrator)
    } catch { $false }
}

function Get-FreeGB {
    param([string]$Drive = $env:SystemDrive)
    try {
        $d = Get-CimInstance Win32_LogicalDisk -Filter ("DeviceID='{0}'" -f $Drive) -ErrorAction Stop
        [math]::Round($d.FreeSpace / 1GB, 1)
    } catch { -1 }
}

function Get-RegValue {
    param([string]$Path,[string]$Name)
    try { (Get-ItemProperty -Path $Path -Name $Name -ErrorAction Stop).$Name } catch { $null }
}

function Get-DirSizeGB {
    param([string]$Path)
    try {
        if (-not (Test-Path -LiteralPath $Path)) { return 0 }
        $m = Get-ChildItem -LiteralPath $Path -Recurse -Force -File -ErrorAction SilentlyContinue |
             Measure-Object -Property Length -Sum
        if ($null -eq $m -or $null -eq $m.Sum) { return 0 }
        [math]::Round($m.Sum / 1GB, 2)
    } catch { 0 }
}

$script:SvcList = @(
    @{ Name='wuauserv';     Nice='Windows Update';        Want='Manual'    },
    @{ Name='bits';         Nice='BITS';                  Want='Manual'    },
    @{ Name='cryptsvc';     Nice='Cryptographic Svc';     Want='Automatic' },
    @{ Name='msiserver';    Nice='Windows Installer';     Want='Manual'    },
    @{ Name='UsoSvc';       Nice='Update Orchestrator';   Want='Manual'    },
    @{ Name='DoSvc';        Nice='Delivery Optimization'; Want='Manual'    },
    @{ Name='TrustedInstaller'; Nice='Windows Modules';   Want='Manual'    }
)

function Stop-UpdateService {
    param([string]$ServiceName,[string]$Nice)
    try {
        $s = Get-Service -Name $ServiceName -ErrorAction Stop
    } catch {
        Write-Step $Nice 'skip' 'service not present on this build'
        return
    }
    $script:SvcPrior[$ServiceName] = $s.Status
    if ($s.Status -eq 'Stopped') { Write-Step $Nice 'ok' 'already stopped'; return }
    if ($script:Cfg.DryRun) { Write-Step $Nice 'dry' 'would stop'; return }
    for ($i = 1; $i -le 3; $i++) {
        try {
            Stop-Service -Name $ServiceName -Force -ErrorAction Stop
            Start-Sleep -Milliseconds 700
            $s.Refresh()
            if ((Get-Service $ServiceName).Status -eq 'Stopped') {
                Write-Step $Nice 'fixed' 'stopped'
                return
            }
        } catch {
            Start-Sleep -Seconds 2
        }
    }
    Write-Step $Nice 'blocked' 'would not stop - see advisories'
    Add-Advisory "$Nice would not stop" @"
Three attempts to stop $ServiceName were refused. On a Panda Adaptive Defense box
this is usually the endpoint agent holding the service or its files open mid-scan.
It is not fatal: the cache rename below will simply report BLOCKED and the
servicing repair still runs. Retrying after the box has been idle for a few
minutes, or after a reboot, generally clears it.
"@
}

function Rename-Stale {
    param([string]$Path,[string]$Nice)
    if (-not (Test-Path -LiteralPath $Path)) { Write-Step $Nice 'skip' 'not present'; return $false }
    $target = "$Path.old.$($script:Stamp)"
    if ($script:Cfg.DryRun) { Write-Step $Nice 'dry' "would rename -> $(Split-Path $target -Leaf)"; return $false }
    for ($i = 1; $i -le 4; $i++) {
        try {
            Rename-Item -LiteralPath $Path -NewName (Split-Path $target -Leaf) -ErrorAction Stop
            Write-Step $Nice 'fixed' "renamed -> $(Split-Path $target -Leaf)"
            return $true
        } catch {
            Start-Sleep -Seconds ($i * 2)
        }
    }
    Write-Step $Nice 'blocked' 'locked - not renamed, nothing deleted'
    return $false
}

#--- SETUP PANEL ---------------------------------------------------------------
function Show-Setup {
    $interactive = $true
    try { $null = [Console]::KeyAvailable } catch { $interactive = $false }

    function OnOff { param($b) if ($b) { Herb 'on ' } else { Dim 'off' } }
    function Timeout-Label { if ($script:Cfg.TimeoutSec -le 0) { 'infinite' } else { "$($script:Cfg.TimeoutSec)s" } }

    while ($true) {
        Write-Host ''
        Write-Host (Dim '   .-- PREPARATION ------------------------------------------------------.')
        Write-Host ('   ' + (Bone '[1] Dry run ............ ') + (OnOff $script:Cfg.DryRun)      + (Dim '   narrate every action, change nothing'))
        Write-Host ('   ' + (Bone '[2] Step timeout ....... ') + (Bone (Timeout-Label))         + (Dim '   how long one operation may run before it is cut'))
        Write-Host ('   ' + (Bone '[3] Servicing repair ... ') + (OnOff $script:Cfg.ServicingRepair) + (Dim '   run DISM RestoreHealth and SFC if the image is sick'))
        Write-Host ('   ' + (Bone '[4] Component cleanup .. ') + (OnOff $script:Cfg.ComponentCleanup) + (Dim '   reclaim superseded WinSxS payloads (slow, safe)'))
        Write-Host ('   ' + (Bone '[5] Clear WU policy .... ') + (OnOff $script:Cfg.ClearPolicyKeys)  + (Dim '   backs up, then removes WSUS/GPO update keys'))
        Write-Host ('   ' + (Bone '[6] Queue locked work .. ') + (OnOff $script:Cfg.ScheduleLocked)   + (Dim '   if a cache is locked, rename it on next boot instead'))
        Write-Host (Dim   "   '-- S at any point during a long step skips that step ----------------'")
        Write-Host ('   ' + (Dim 'number toggles - ') + (Herb 'ENTER') + (Dim ' begins'))
        Write-Host ''

        if (-not $interactive) {
            Write-Host ('   ' + (Dim 'no console input available - running with defaults'))
            return
        }
        $choice = Read-Host '   >'
        switch ($choice.Trim()) {
            ''  { return }
            '1' { $script:Cfg.DryRun           = -not $script:Cfg.DryRun }
            '3' { $script:Cfg.ServicingRepair  = -not $script:Cfg.ServicingRepair }
            '4' { $script:Cfg.ComponentCleanup = -not $script:Cfg.ComponentCleanup }
            '6' { $script:Cfg.ScheduleLocked   = -not $script:Cfg.ScheduleLocked }
            '2' {
                $v = Read-Host '   seconds per step (0 = infinite)'
                $n = 0
                if ([int]::TryParse($v, [ref]$n) -and $n -ge 0) { $script:Cfg.TimeoutSec = $n }
            }
            '5' {
                if (-not $script:Cfg.ClearPolicyKeys) {
                    Write-Host ('   ' + (Amber 'This client may point at WSUS on purpose. AD GPO rewrites this key on'))
                    Write-Host ('   ' + (Amber 'its own cycle; MDM is NOT documented to re-push a locally deleted value.'))
                    Write-Host ('   ' + (Amber 'Assume the .reg backup is the only way back until proven otherwise.'))
                    $y = Read-Host '   type CLEAR to arm it'
                    if ($y -eq 'CLEAR') { $script:Cfg.ClearPolicyKeys = $true }
                } else { $script:Cfg.ClearPolicyKeys = $false }
            }
        }
    }
}

#--- LABEL -------------------------------------------------------------------
function Show-Label {
    param([string]$Verdict,[int[]]$VerdictColor)
    $w = @(
        '  █████╗ ██╗     ██╗  ██╗ █████╗ ██╗  ██╗███████╗███████╗████████╗',
        ' ██╔══██╗██║     ██║ ██╔╝██╔══██╗██║  ██║██╔════╝██╔════╝╚══██╔══╝',
        ' ███████║██║     █████╔╝ ███████║███████║█████╗  ███████╗   ██║   ',
        ' ██╔══██║██║     ██╔═██╗ ██╔══██║██╔══██║██╔══╝  ╚════██║   ██║   ',
        ' ██║  ██║███████╗██║  ██╗██║  ██║██║  ██║███████╗███████║   ██║   ',
        ' ╚═╝  ╚═╝╚══════╝╚═╝  ╚═╝╚═╝  ╚═╝╚═╝  ╚═╝╚══════╝╚══════╝   ╚═╝   '
    )
    Write-Host ''
    Write-Host (Dim ('   ' + '=' * 68))
    foreach ($l in $w) { Write-Host ('  ' + (Iris $l)) }
    Write-Host ('   ' + (Bone 'Rx  THE UNIVERSAL SOLVENT') + (Dim '  .  apothecary systems  .  v') + (Dim $script:Version))
    Write-Host (Dim ('   ' + '-' * 68))
    Write-Host ('   ' + (Dim 'RX #    ') + (Bone $script:Stamp.Substring(9)) + (Dim '        DATE: ') + (Bone $script:Started.ToString('yyyy-MM-dd HH:mm')))
    Write-Host ('   ' + (Dim 'PATIENT ') + (Bone $env:COMPUTERNAME))
    Write-Host ('   ' + (Dim 'PRESCRIBER ') + (Bone "$env:USERDOMAIN\$env:USERNAME"))
    Write-Host ('   ' + (Dim 'DX      ') + (Bone $script:OsCaption) + (Dim ("  (build {0})" -f $script:OsBuild)))
    Write-Host ('   ' + (Dim 'SIG     ') + (Paint $VerdictColor[0] $VerdictColor[1] $VerdictColor[2] $Verdict))
    Write-Host (Dim ('   ' + '=' * 68))
}

#--- TIER 1: DIAGNOSE ----------------------------------------------------------
function Invoke-Diagnose {
    $script:CurrentTier = 'DIAGNOSE'
    Write-Tier 'DIAGNOSE' 'read the blockage before touching it'

    $script:IsAdmin = Test-Admin
    if ($script:IsAdmin) { Write-Step 'elevation' 'ok' 'Administrator' }
    else {
        Write-Step 'elevation' 'fail' 'not elevated - nothing can be repaired'
        return $false
    }

    try {
        $os = Get-CimInstance Win32_OperatingSystem -ErrorAction Stop
        $script:OsCaption = $os.Caption.Trim()
        $script:OsBuild   = $os.BuildNumber
        $upDays = [math]::Round(((Get-Date) - $os.LastBootUpTime).TotalDays, 1)
        Write-Step 'operating system' 'ok' "$($script:OsCaption) - build $($script:OsBuild)"
        $script:UptimeDays = $upDays
        if ($upDays -gt 14) { Write-Step 'uptime' 'warn' "$upDays days - a pending servicing op may just need the reboot" }
        else                { Write-Step 'uptime' 'ok'   "$upDays days" }
    } catch {
        $script:OsCaption = 'unknown'; $script:OsBuild = '0'; $script:UptimeDays = 0
        Write-Step 'operating system' 'warn' 'could not read Win32_OperatingSystem'
    }

    $script:FreeGB = Get-FreeGB
    if     ($script:FreeGB -lt 0)  { Write-Step 'disk headroom' 'warn' 'unreadable' }
    elseif ($script:FreeGB -lt 10) { Write-Step 'disk headroom' 'fail' "$($script:FreeGB) GB free - updates will fail below ~10 GB"
                                     Add-Advisory 'Not enough free space' "Feature and cumulative updates stage into $env:SystemDrive and routinely need 10-20 GB. At $($script:FreeGB) GB the update will keep failing no matter what is reset here. Panacea's PURGE tier is the right tool for that half of the job." }
    elseif ($script:FreeGB -lt 20) { Write-Step 'disk headroom' 'warn' "$($script:FreeGB) GB free - tight for a feature update" }
    else                           { Write-Step 'disk headroom' 'ok'   "$($script:FreeGB) GB free" }

    # --- endpoint protection: name it, because it changes what will work
    $script:Panda = $false
    $pandaHits = @()
    foreach ($sn in @('PandaAetherAgent','PSUAService','NanoServiceMain','PandaSecurityService','PandaAgent')) {
        try { if (Get-Service -Name $sn -ErrorAction Stop) { $pandaHits += $sn } } catch { }
    }
    if (Test-Path 'HKLM:\SOFTWARE\Panda Security') { $pandaHits += 'registry' }
    if (Test-Path 'HKLM:\SOFTWARE\WOW6432Node\Panda Security') { $pandaHits += 'registry(x86)' }
    if ($pandaHits.Count -gt 0) {
        $script:Panda = $true
        Write-Step 'endpoint protection' 'warn' ("Panda present ({0})" -f ($pandaHits -join ', '))
        Add-Advisory 'Panda Adaptive Defense is on this box' @"
Two things follow from that, and both are already handled:
  1. The classic "reset Windows Update" recipe re-registers a dozen DLLs with
     regsvr32 and drives BITS with bitsadmin. Panda blocks or quarantines both.
     ALKAHEST does not use either. If a hand-run of the old recipe is what got
     this machine here, the aborted half of it is likely part of the blockage.
  2. Panda holds file handles inside SoftwareDistribution while it scans staged
     payloads, so a rename can come back access-denied. Renames retry four times
     with backoff and then report BLOCKED rather than forcing anything.
"@
    } else {
        Write-Step 'endpoint protection' 'ok' 'no Panda signature found'
    }

    # --- service posture
    $script:SvcState = @{}
    foreach ($svc in $script:SvcList) {
        try {
            $s = Get-Service -Name $svc.Name -ErrorAction Stop
            $wmi = Get-CimInstance Win32_Service -Filter ("Name='{0}'" -f $svc.Name) -ErrorAction SilentlyContinue
            $start = if ($wmi) { $wmi.StartMode } else { 'unknown' }
            $script:SvcState[$svc.Name] = [pscustomobject]@{ Status = $s.Status; StartMode = $start }
            if ($start -eq 'Disabled') {
                Write-Step $svc.Nice 'fail' "DISABLED (status $($s.Status)) - this alone stops updates"
            } else {
                Write-Step $svc.Nice 'ok' "$($s.Status) / $start"
            }
        } catch {
            Write-Step $svc.Nice 'skip' 'not present on this build'
        }
    }
    try {
        $medic = Get-Service -Name 'WaaSMedicSvc' -ErrorAction Stop
        Write-Step 'Update Medic' 'warn' "$($medic.Status) - reverts manual WU changes by design"
    } catch { }

    # --- pending reboot / pending servicing
    $script:Pending = @()
    if (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending') { $script:Pending += 'CBS RebootPending' }
    if (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\PackagesPending') { $script:Pending += 'CBS PackagesPending' }
    if (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired') { $script:Pending += 'WU RebootRequired' }
    if (Get-RegValue 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager' 'PendingFileRenameOperations') { $script:Pending += 'PendingFileRenameOperations' }
    foreach ($x in @('pending.xml','reboot.xml','SessionsPending.xml')) {
        $p = Join-Path $env:windir "WinSxS\$x"
        if (Test-Path -LiteralPath $p) { $script:Pending += "WinSxS\$x" }
    }
    if ($script:Pending.Count -gt 0) {
        Write-Step 'pending servicing' 'warn' ($script:Pending -join ', ')
        Add-Advisory 'A servicing transaction is already staged' @"
$($script:Pending -join ', ')

These are read-only findings and ALKAHEST does not touch them. A staged CBS
transaction completes on the next restart; clearing it by hand is how a machine
gets a half-installed component store. If this box also shows high uptime, the
honest first move is a scheduled reboot, not a reset.
"@
    } else {
        Write-Step 'pending servicing' 'ok' 'nothing staged'
    }

    # --- cache footprint
    $script:SdPath  = Join-Path $env:windir 'SoftwareDistribution'
    $script:CatPath = Join-Path $env:windir 'System32\catroot2'
    $sdGB = Get-DirSizeGB $script:SdPath
    $dl   = Join-Path $script:SdPath 'Download'
    $oldest = $null
    try {
        $f = Get-ChildItem -LiteralPath $dl -Recurse -Force -File -ErrorAction SilentlyContinue |
             Sort-Object LastWriteTime | Select-Object -First 1
        if ($f) { $oldest = [math]::Round(((Get-Date) - $f.LastWriteTime).TotalDays, 1) }
    } catch { }
    $sdNote = "$sdGB GB"
    if ($null -ne $oldest) { $sdNote += " - oldest staged payload $oldest days old" }
    if ($null -ne $oldest -and $oldest -gt 7) { Write-Step 'SoftwareDistribution' 'warn' $sdNote }
    else { Write-Step 'SoftwareDistribution' 'ok' $sdNote }

    # --- BITS queue
    $script:BitsJobs = 0
    if (Get-Command Get-BitsTransfer -ErrorAction SilentlyContinue) {
        try {
            $jobs = @(Get-BitsTransfer -AllUsers -ErrorAction Stop)
            $script:BitsJobs = $jobs.Count
            $stuck = @($jobs | Where-Object { $_.JobState -in @('Error','TransientError','Suspended') })
            if ($stuck.Count -gt 0) { Write-Step 'BITS queue' 'warn' "$($jobs.Count) jobs, $($stuck.Count) errored/suspended" }
            elseif ($jobs.Count -gt 0) { Write-Step 'BITS queue' 'ok' "$($jobs.Count) jobs, none errored" }
            else { Write-Step 'BITS queue' 'ok' 'empty' }
        } catch { Write-Step 'BITS queue' 'warn' 'unreadable (BITS may be stopped)' }
    } else { Write-Step 'BITS queue' 'skip' 'BitsTransfer cmdlets unavailable' }

    # --- policy: report, never assume it is wrong
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
        Write-Step 'update policy' 'warn' (($script:Policy.Keys | Sort-Object) -join ', ')
        $wsus = $script:Policy['WUServer']
        if ($wsus) {
            $reach = 'not tested'
            try {
                $u = [uri]$wsus
                $port = if ($u.Port -gt 0) { $u.Port } else { if ($u.Scheme -eq 'https') { 443 } else { 80 } }
                $t = Test-NetConnection -ComputerName $u.Host -Port $port -InformationLevel Quiet -WarningAction SilentlyContinue
                $reach = if ($t) { 'reachable' } else { 'UNREACHABLE' }
            } catch { $reach = 'could not test' }
            Write-Step 'WSUS endpoint' $(if ($reach -eq 'UNREACHABLE') { 'fail' } else { 'ok' }) "$wsus - $reach"
            if ($reach -eq 'UNREACHABLE') {
                Add-Advisory 'WSUS is configured and not answering' @"
$wsus

This machine is pointed at a WSUS server it cannot reach, which produces exactly
the symptom being chased: scans that never finish and updates that never move.
No amount of cache clearing fixes it. Confirm with whoever owns that tenant's
patching before changing anything - the fix is on the server or the network path,
not on this endpoint.
"@
            }
        }
    } else {
        Write-Step 'update policy' 'ok' 'no WSUS/GPO update keys set'
    }

    # Intune Update rings do not live in the Policies key above. Read the MDM
    # path too, or a ring-managed box reports "no policy" and lies to the tech.
    $mdmPath = 'HKLM:\SOFTWARE\Microsoft\PolicyManager\default\Update'
    $script:MdmPolicy = @()
    if (Test-Path $mdmPath) {
        try {
            $script:MdmPolicy = @(Get-ChildItem -Path $mdmPath -ErrorAction Stop |
                Select-Object -ExpandProperty PSChildName)
        } catch { }
    }
    if ($script:MdmPolicy.Count -gt 0) {
        Write-Step 'MDM update policy' 'warn' ("{0} settings under PolicyManager (Intune ring or similar)" -f $script:MdmPolicy.Count)
        Add-Advisory 'This box is under MDM update policy' @"
$(($script:MdmPolicy | Sort-Object | Select-Object -First 12) -join ', ')

Read from HKLM\SOFTWARE\Microsoft\PolicyManager\default\Update. ALKAHEST does
not touch this key and the "Clear WU policy" option does not either - that option
only clears HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate.

Deferrals, pauses and a target release version set here will hold updates back and
look exactly like a stuck stack. Check the assigned ring in Intune before chasing
this any further on the endpoint.
"@
    } else {
        Write-Step 'MDM update policy' 'ok' 'no PolicyManager update settings'
    }

    # --- orchestrator tasks
    $script:BadTasks = @()
    if (Get-Command Get-ScheduledTask -ErrorAction SilentlyContinue) {
        try {
            $tasks = @(Get-ScheduledTask -TaskPath '\Microsoft\Windows\UpdateOrchestrator\*' -ErrorAction Stop)
            $script:BadTasks = @($tasks | Where-Object { $_.State -eq 'Disabled' })
            if ($script:BadTasks.Count -gt 0) { Write-Step 'orchestrator tasks' 'warn' "$($script:BadTasks.Count) of $($tasks.Count) disabled" }
            else { Write-Step 'orchestrator tasks' 'ok' "$($tasks.Count) present, none disabled" }
        } catch { Write-Step 'orchestrator tasks' 'skip' 'unreadable' }
    }

    # --- recent client errors, decoded
    $script:WuErrors = @()
    try {
        $ev = Get-WinEvent -FilterHashtable @{ LogName='Microsoft-Windows-WindowsUpdateClient/Operational'; Level=2 } -MaxEvents 15 -ErrorAction Stop
        foreach ($e in $ev) {
            $code = ''
            $m = [regex]::Match($e.Message, '0x[0-9A-Fa-f]{8}')
            if ($m.Success) { $code = $m.Value }
            $script:WuErrors += [pscustomobject]@{ Time = $e.TimeCreated; Id = $e.Id; Code = $code }
        }
    } catch { }
    if ($script:WuErrors.Count -gt 0) {
        $codes = @($script:WuErrors | Where-Object { $_.Code } | Select-Object -ExpandProperty Code -Unique)
        Write-Step 'recent WU errors' 'warn' ("{0} in log; codes: {1}" -f $script:WuErrors.Count, (($codes | Select-Object -First 4) -join ' '))
        $known = @{
            '0x80070020' = 'file in use - another process (often AV) holds a staged file'
            '0x80073712' = 'component store corruption - DISM RestoreHealth is the fix'
            '0x800f0922' = 'reserved partition too small, or cannot reach update endpoint'
            '0x80240034' = 'download failed - BITS or the source endpoint'
            '0x8024402c' = 'cannot reach the configured update source (WSUS/proxy)'
            '0x80244022' = 'update source returned HTTP 503'
            '0x80070005' = 'access denied - permissions or endpoint protection blocked it'
            '0x800705b4' = 'operation timed out'
            '0x80248007' = 'datastore missing or corrupt - the cache rename is the fix'
        }
        $lines = @()
        foreach ($c in $codes) { if ($known.ContainsKey($c.ToLower()) -or $known.ContainsKey($c)) {
            $k = if ($known.ContainsKey($c)) { $c } else { $c.ToLower() }
            $lines += "  $c  $($known[$k])" } else { $lines += "  $c  (not in local table)" } }
        if ($lines.Count -gt 0) { Add-Advisory 'What the update client actually logged' (($lines | Select-Object -Unique) -join "`n") }
    } else {
        Write-Step 'recent WU errors' 'ok' 'none in the operational log'
    }

    # --- image health (read-only)
    $script:ImageSick = $false
    $chk = Invoke-Guarded -FilePath 'DISM.exe' -Arguments '/Online /Cleanup-Image /CheckHealth' -Label 'component store check' -Quiet
    if (-not $chk.Skipped) {
        if ($chk.Output -match 'repairable') { $script:ImageSick = $true; Write-Step 'component store' 'warn' 'repairable corruption detected' }
        elseif ($chk.Output -match 'No component store corruption') { Write-Step 'component store' 'ok' 'no corruption detected' }
        else { Write-Step 'component store' 'warn' "DISM exit $($chk.ExitCode) - inconclusive" }
    }

    # --- packages stuck mid-install
    $script:StuckPkgs = @()
    $pkg = Invoke-Guarded -FilePath 'DISM.exe' -Arguments '/Online /Get-Packages /Format:Table' -Label 'package state sweep' -Quiet
    if (-not $pkg.Skipped -and $pkg.Output) {
        foreach ($l in ($pkg.Output -split "`n")) {
            if ($l -match 'Install Pending|Uninstall Pending|Superseded Pending') {
                $script:StuckPkgs += $l.Trim()
            }
        }
    }
    if ($script:StuckPkgs.Count -gt 0) {
        Write-Step 'stuck packages' 'warn' "$($script:StuckPkgs.Count) in a pending state"
        Add-Advisory 'Packages are parked in a pending state' @"
$(($script:StuckPkgs | Select-Object -First 8) -join "`n")

A package in Install Pending is waiting on a restart to finish its transaction.
That is a reboot, not a reset. If these are still pending after a clean restart,
the component store is the problem and RestoreHealth is the next move - which is
what the RECONSTITUTE tier does.
"@
    } else {
        Write-Step 'stuck packages' 'ok' 'none pending'
    }

    return $true
}

#--- TIER 2: QUENCH ------------------------------------------------------------
function Invoke-Quench {
    $script:CurrentTier = 'QUENCH'
    Write-Tier 'QUENCH' 'halt the update stack before dissolving anything'
    foreach ($n in @('UsoSvc','DoSvc','wuauserv','bits','cryptsvc','msiserver')) {
        $nice = ($script:SvcList | Where-Object { $_.Name -eq $n }).Nice
        if (-not $nice) { $nice = $n }
        Stop-UpdateService -ServiceName $n -Nice $nice
    }
}

#--- TIER 3: DISSOLVE ----------------------------------------------------------
function Invoke-Dissolve {
    $script:CurrentTier = 'DISSOLVE'
    Write-Tier 'DISSOLVE' 'rename the poisoned caches - nothing is deleted'

    # BITS queue, via the in-box cmdlets. Deliberately not bitsadmin.exe.
    if (Get-Command Remove-BitsTransfer -ErrorAction SilentlyContinue) {
        try {
            $jobs = @(Get-BitsTransfer -AllUsers -ErrorAction Stop)
            if ($jobs.Count -eq 0) { Write-Step 'BITS queue' 'ok' 'already empty' }
            elseif ($script:Cfg.DryRun) { Write-Step 'BITS queue' 'dry' "would cancel $($jobs.Count) jobs" }
            else {
                $jobs | Remove-BitsTransfer -ErrorAction SilentlyContinue
                Write-Step 'BITS queue' 'fixed' "cancelled $($jobs.Count) jobs"
            }
        } catch { Write-Step 'BITS queue' 'blocked' 'could not enumerate transfers' }
    } else { Write-Step 'BITS queue' 'skip' 'cmdlets unavailable' }

    # SoftwareDistribution: whole folder first, then the two children that matter.
    $script:SdRenamed = Rename-Stale -Path $script:SdPath -Nice 'SoftwareDistribution'
    if (-not $script:SdRenamed -and (Test-Path -LiteralPath $script:SdPath)) {
        foreach ($child in @('Download','DataStore')) {
            $p = Join-Path $script:SdPath $child
            $null = Rename-Stale -Path $p -Nice "  fallback: $child"
        }
        if ($script:Cfg.ScheduleLocked -and -not $script:Cfg.DryRun) {
            try {
                $key = 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager'
                $cur = @(Get-RegValue $key 'PendingFileRenameOperations')
                $src = '\??\' + $script:SdPath
                $dst = '!\??\' + $script:SdPath + '.old.' + $script:Stamp
                Set-ItemProperty -Path $key -Name 'PendingFileRenameOperations' -Value ($cur + @($src, $dst)) -Type MultiString -ErrorAction Stop
                Write-Step 'queued for next boot' 'fixed' 'rename scheduled via PendingFileRenameOperations'
                Add-Advisory 'A rename was queued for the next restart' 'SoftwareDistribution is locked right now and the rename was scheduled to run during the next boot, before the lock exists. The machine must actually be restarted for it to happen.'
            } catch {
                Write-Step 'queued for next boot' 'fail' 'could not write the pending-rename key'
            }
        }
    }

    # catroot2 needs cryptsvc down; it is rebuilt automatically on next scan.
    $null = Rename-Stale -Path $script:CatPath -Nice 'catroot2'

    # Delivery Optimization cache - in-box cmdlet, no shelling.
    if (Get-Command Delete-DeliveryOptimizationCache -ErrorAction SilentlyContinue) {
        if ($script:Cfg.DryRun) { Write-Step 'Delivery Optimization cache' 'dry' 'would purge' }
        else {
            try {
                Delete-DeliveryOptimizationCache -Force -ErrorAction Stop
                Write-Step 'Delivery Optimization cache' 'fixed' 'purged'
            } catch { Write-Step 'Delivery Optimization cache' 'blocked' 'refused (service state or policy)' }
        }
    } else { Write-Step 'Delivery Optimization cache' 'skip' 'cmdlet not on this build' }

    # The deliberate omissions, stated out loud rather than silently skipped.
    Write-Step 'regsvr32 DLL re-registration' 'skip' 'not attempted by design - Panda blocks it'
    Write-Step 'bitsadmin / wusa / sc.exe' 'skip' 'not attempted by design - EDR-flagged LOLBins'
}

#--- TIER 4: RECONSTITUTE ------------------------------------------------------
function Invoke-Reconstitute {
    $script:CurrentTier = 'RECONSTITUTE'
    Write-Tier 'RECONSTITUTE' 'put the machinery back the way Windows expects it'

    foreach ($svc in $script:SvcList) {
        $st = $script:SvcState[$svc.Name]
        if (-not $st) { continue }
        if ($st.StartMode -eq 'Disabled' -or ($st.StartMode -eq 'Auto' -and $svc.Want -eq 'Manual')) {
            if ($script:Cfg.DryRun) { Write-Step "$($svc.Nice) start type" 'dry' "would set $($svc.Want)"; continue }
            try {
                Set-Service -Name $svc.Name -StartupType $svc.Want -ErrorAction Stop
                Write-Step "$($svc.Nice) start type" 'fixed' "$($st.StartMode) -> $($svc.Want)"
            } catch {
                Write-Step "$($svc.Nice) start type" 'blocked' "could not set $($svc.Want)"
            }
        } else {
            Write-Step "$($svc.Nice) start type" 'ok' $st.StartMode
        }
    }

    if ($script:BadTasks -and $script:BadTasks.Count -gt 0) {
        foreach ($t in $script:BadTasks) {
            if ($script:Cfg.DryRun) { Write-Step "task $($t.TaskName)" 'dry' 'would enable'; continue }
            try {
                Enable-ScheduledTask -TaskName $t.TaskName -TaskPath $t.TaskPath -ErrorAction Stop | Out-Null
                Write-Step "task $($t.TaskName)" 'fixed' 'enabled'
            } catch {
                Write-Step "task $($t.TaskName)" 'blocked' 'refused - usually held by policy or Update Medic'
            }
        }
    }

    if ($script:Cfg.ClearPolicyKeys -and $script:Policy.Count -gt 0) {
        $polPath = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate'
        $backup  = Join-Path $script:Root ("wu_policy_{0}_{1}.reg" -f $env:COMPUTERNAME, $script:Stamp)
        if ($script:Cfg.DryRun) { Write-Step 'WU policy keys' 'dry' "would back up to $backup then remove" }
        else {
            $exp = Invoke-Guarded -FilePath 'reg.exe' -Arguments ("export `"HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate`" `"$backup`" /y") -Label 'export policy backup' -Quiet
            if ($exp.ExitCode -eq 0) {
                try {
                    Remove-Item -Path $polPath -Recurse -Force -ErrorAction Stop
                    Write-Step 'WU policy keys' 'fixed' "removed - backup at $backup"
                    Add-Advisory 'Update policy was removed' @"
A .reg backup is at $backup. Do not assume this reapplies on its own.

  Active Directory GPO  - yes. Rewrites this key on its own cycle (90 min by
                          default) or immediately on gpupdate /force.
  Intune Update rings   - not from here. Rings write to PolicyManager, a
                          different key this option never touched.
  Intune ADMX / Admin
  Templates profiles    - these DO land in this key, and Microsoft does not
                          document MDM re-pushing a value deleted locally while
                          the policy itself is unchanged. A plain device sync may
                          not bring it back. Editing and re-saving the profile, or
                          re-assigning it, forces a change-based push that will.

Device check-in is roughly every 8 hours, and no more than one maintenance sync
per 6.5 hours. Settings > Accounts > Access work or school > Info > Sync, or the
Sync action in the Intune admin center, is the fast path.
"@
                } catch { Write-Step 'WU policy keys' 'fail' 'export succeeded but removal was refused' }
            } else { Write-Step 'WU policy keys' 'fail' 'backup export failed - nothing was removed' }
        }
    }

    if ($script:Cfg.ServicingRepair -and ($script:ImageSick -or $script:StuckPkgs.Count -gt 0 -or $script:WuErrors.Count -gt 0)) {
        $r = Invoke-Guarded -FilePath 'DISM.exe' -Arguments '/Online /Cleanup-Image /RestoreHealth' -Label 'DISM RestoreHealth'
        if (-not $r.Skipped) {
            if ($r.ExitCode -eq 0) { Write-Step 'DISM RestoreHealth' 'fixed' 'completed' }
            else {
                Write-Step 'DISM RestoreHealth' 'fail' "exit $($r.ExitCode)"
                Add-Advisory 'RestoreHealth could not repair the image' 'With no WSUS source and no reachable Windows Update, DISM has nowhere to pull replacement payloads from. A matching install.wim or an ISO of the same build, passed with /Source, is the offline path.'
            }
            $s = Invoke-Guarded -FilePath 'sfc.exe' -Arguments '/scannow' -Label 'SFC scan'
            if (-not $s.Skipped) {
                if     ($s.Output -match 'did not find any integrity violations') { Write-Step 'SFC' 'ok' 'no integrity violations' }
                elseif ($s.Output -match 'successfully repaired')                 { Write-Step 'SFC' 'fixed' 'repaired protected files' }
                elseif ($s.Output -match 'unable to fix')                          { Write-Step 'SFC' 'fail' 'found damage it could not repair' }
                else { Write-Step 'SFC' 'warn' "exit $($s.ExitCode) - verdict unclear, check CBS.log" }
            }
        }
    } else {
        Write-Step 'servicing repair' 'skip' 'image looked clean, or turned off in setup'
    }

    if ($script:Cfg.ComponentCleanup) {
        $c = Invoke-Guarded -FilePath 'DISM.exe' -Arguments '/Online /Cleanup-Image /StartComponentCleanup' -Label 'component cleanup'
        if (-not $c.Skipped) {
            if ($c.ExitCode -eq 0) { Write-Step 'component cleanup' 'fixed' 'superseded payloads reclaimed' }
            else { Write-Step 'component cleanup' 'warn' "exit $($c.ExitCode)" }
        }
    }
}

#--- TIER 5: PROGNOSIS ---------------------------------------------------------
function Invoke-Prognosis {
    $script:CurrentTier = 'PROGNOSIS'
    Write-Tier 'PROGNOSIS' 'restart the stack, ask for a scan, tell the truth about it'

    foreach ($n in @('cryptsvc','bits','wuauserv','UsoSvc','DoSvc')) {
        if (-not $script:SvcState.ContainsKey($n)) { continue }
        if ($script:Cfg.DryRun) { Write-Step "start $n" 'dry' 'would start'; continue }
        try {
            Start-Service -Name $n -ErrorAction Stop
            Write-Step "start $n" 'fixed' 'running'
        } catch {
            $s = (Get-Service -Name $n -ErrorAction SilentlyContinue)
            if ($s -and $s.StartType -eq 'Manual') { Write-Step "start $n" 'ok' 'trigger-start, will run on demand' }
            else { Write-Step "start $n" 'warn' 'did not start' }
        }
    }

    # Ask for a detection pass. Report that it was ASKED FOR, never that the
    # machine is up to date - under SYSTEM the COM search can no-op silently and
    # a "current" verdict here would be a lie.
    $script:ScanAsked = $false
    if (-not $script:Cfg.DryRun) {
        try {
            $au = New-Object -ComObject Microsoft.Update.AutoUpdate
            $au.DetectNow()
            $script:ScanAsked = $true
            Write-Step 'detection pass' 'fixed' 'requested via Microsoft.Update.AutoUpdate'
        } catch {
            $uso = Join-Path $env:windir 'System32\UsoClient.exe'
            if (Test-Path -LiteralPath $uso) {
                $u = Invoke-Guarded -FilePath $uso -Arguments 'StartScan' -Label 'orchestrator scan' -Quiet -TimeoutSec 120
                if ($u.ExitCode -eq 0) { $script:ScanAsked = $true; Write-Step 'detection pass' 'fixed' 'requested via UsoClient' }
                else { Write-Step 'detection pass' 'warn' 'scan request returned an error' }
            } else { Write-Step 'detection pass' 'warn' 'no way to request a scan on this build' }
        }
        if ($script:ScanAsked) {
            Add-Advisory 'A scan was requested, not verified' 'The detection pass was handed to Windows. Whether it completes cannot be confirmed from here, especially under SYSTEM. Open Settings > Windows Update on the frontstage session and watch it move before calling this fixed.'
        }
    }

    # re-read the pending state
    $after = @()
    if (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending') { $after += 'CBS RebootPending' }
    if (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired') { $after += 'WU RebootRequired' }
    if (Get-RegValue 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager' 'PendingFileRenameOperations') { $after += 'PendingFileRenameOperations' }
    $script:PendingAfter = $after

    # ---- verdict
    $fails   = @($script:Ledger | Where-Object { $_.Status -eq 'fail' })
    $blocked = @($script:Ledger | Where-Object { $_.Status -eq 'blocked' })
    $fixed   = @($script:Ledger | Where-Object { $_.Status -eq 'fixed' })

    if ($fails.Count -gt 0)        { $verdict = 'ATTENTION - something here needs a human';  $vc = @(201,72,75);  $global:AlkahestExit = 2 }
    elseif ($blocked.Count -gt 0)  { $verdict = 'PARTIAL - steps were blocked on this box';  $vc = @(208,138,58); $global:AlkahestExit = 1 }
    elseif ($fixed.Count -gt 0)    { $verdict = 'DISSOLVED - the update stack was reset';    $vc = @(74,166,184); $global:AlkahestExit = 0 }
    else                           { $verdict = 'CLEAR - nothing was blocking updates';      $vc = @(95,179,122); $global:AlkahestExit = 0 }
    if ($script:Cfg.DryRun)        { $verdict = 'DRY RUN - nothing on this machine changed'; $vc = @(107,107,120); $global:AlkahestExit = 0 }

    Show-Label -Verdict $verdict -VerdictColor $vc

    Write-Host ''
    Write-Host ('   ' + (Bone 'SIG - what was done'))
    foreach ($e in ($script:Ledger | Where-Object { $_.Status -in @('fixed','fail','blocked') })) {
        $c = switch ($e.Status) { 'fixed' { 'Vitri' } 'fail' { 'Blood' } default { 'Amber' } }
        Write-Host ('     ' + (& $c ("{0,-9}" -f $e.Status)) + (Bone $e.Step) + (Dim ("  -  " + $e.Detail)))
    }
    if (-not ($script:Ledger | Where-Object { $_.Status -in @('fixed','fail','blocked') })) {
        Write-Host ('     ' + (Dim 'nothing needed changing'))
    }

    if ($script:Advisories.Count -gt 0) {
        Write-Host ''
        Write-Host ('   ' + (Amber 'ADVISORIES'))
        foreach ($a in $script:Advisories) {
            Write-Host ('     ' + (Amber ('* ' + $a.Title)))
            foreach ($l in ($a.Body -split "`n")) { Write-Host ('       ' + (Dim $l.TrimEnd())) }
            Write-Host ''
        }
    }

    if ($script:PendingAfter.Count -gt 0 -or $script:StuckPkgs.Count -gt 0) {
        Write-Host ''
        Write-Host (Amber '   +------------------------------------------------------------------+')
        Write-Host (Amber '   |  RESTART REQUIRED TO FINISH                                      |')
        Write-Host (Amber '   |  A servicing transaction is staged and completes only on boot.   |')
        Write-Host (Amber '   |  Nothing here forces it. Schedule it with the client.            |')
        Write-Host (Amber '   +------------------------------------------------------------------+')
    }

    # ---- RMM ingest contract
    $summary = [ordered]@{
        tool          = $script:Name
        version       = $script:Version
        host          = $env:COMPUTERNAME
        started       = $script:Started.ToString('o')
        finished      = (Get-Date).ToString('o')
        verdict       = $verdict
        exit          = $global:AlkahestExit
        dryRun        = [bool]$script:Cfg.DryRun
        pandaPresent  = [bool]$script:Panda
        freeGB        = $script:FreeGB
        uptimeDays    = $script:UptimeDays
        pendingBefore = @($script:Pending)
        pendingAfter  = @($script:PendingAfter)
        stuckPackages = @($script:StuckPkgs).Count
        policyKeys    = @($script:Policy.Keys)
        scanRequested = [bool]$script:ScanAsked
        rebootNeeded  = [bool](($script:PendingAfter.Count -gt 0) -or ($script:StuckPkgs.Count -gt 0))
        steps         = @($script:Ledger)
        advisories    = @($script:Advisories | Select-Object -ExpandProperty Title)
    }
    try {
        $jsonPath = Join-Path $script:Root ("alkahest_{0}_{1}.json" -f $env:COMPUTERNAME, $script:Stamp)
        ($summary | ConvertTo-Json -Depth 5) | Set-Content -LiteralPath $jsonPath -Encoding UTF8
        Write-Host ''
        Write-Host ('   ' + (Dim "summary: $jsonPath"))
    } catch { }
}

#--- ARRIVAL -------------------------------------------------------------------
try { $null = New-Item -ItemType Directory -Path $script:Root -Force -ErrorAction Stop } catch { }
try { Start-Transcript -Path $script:LogFile -Force | Out-Null } catch { }

$script:OsCaption = 'unknown'
$script:OsBuild   = '0'
$script:CurrentTier = 'SETUP'

Write-Host ''
Write-Host ('   ' + (Iris 'ALKAHEST') + (Dim '  -  the universal solvent  -  for update stacks that will not move'))
Write-Host ('   ' + (Dim 'nothing is deleted . nothing reboots . caches are renamed, never removed'))

Show-Setup

if (Invoke-Diagnose) {
    Invoke-Quench
    Invoke-Dissolve
    Invoke-Reconstitute
    Invoke-Prognosis
} else {
    $global:AlkahestExit = 2
    Show-Label -Verdict 'HALTED - run this from an elevated prompt' -VerdictColor @(201,72,75)
}

try { Stop-Transcript | Out-Null } catch { }
$exitVal = $global:AlkahestExit
$logPath = $script:LogFile
Write-Host ''
Write-Host (Dim ("   dispensary closed  .  `$AlkahestExit = $exitVal  .  log: $logPath"))
Write-Host (Dim  '   keep out of reach of end users')
Write-Host ''
'@

[ScriptBlock]::Create($alkahest).Invoke()
