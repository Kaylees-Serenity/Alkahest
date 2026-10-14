# ℞ ALKAHEST

**A single-paste fix for a stuck Windows Update.** When Settings has said "downloading" for three days, paste this into an elevated PowerShell prompt. It finds out why, resets the update stack, and proves the reset worked by actually pulling the stuck updates down.

The sibling to [Panacea](https://github.com/Kaylees-Serenity/panacea). Panacea is the general tune-up; ALKAHEST does one job. Native Windows tools only, nothing deleted, never reboots, and built to run under EDR without tripping it.

```
 █████╗ ██╗    ██╗  ██╗ █████╗ ██╗  ██╗███████╗███████╗████████╗
██╔══██╗██║    ██║ ██╔╝██╔══██╗██║  ██║██╔════╝██╔════╝╚══██╔══╝
███████║██║    █████╔╝ ███████║███████║█████╗  ███████╗   ██║
██╔══██║██║    ██╔═██╗ ██╔══██║██╔══██║██╔══╝  ╚════██║   ██║
██║  ██║██████╗██║  ██╗██║  ██║██║  ██║███████╗███████║   ██║
╚═╝  ╚═╝╚═════╝╚═╝  ╚═╝╚═╝  ╚═╝╚═╝  ╚═╝╚══════╝╚══════╝   ╚═╝
   ℞  THE UNIVERSAL SOLVENT  ·  apothecary systems
```

## What it does

ALKAHEST runs in five stages, named in the same apothecary style as Panacea.

| Stage | What happens |
|---|---|
| **DIAGNOSE** | Reads everything that can wedge Windows Update: elevation, uptime, disk space, update service state, the BITS queue, the SoftwareDistribution cache, the component store, staged servicing operations, stuck packages, recent update errors, disabled orchestrator tasks, Update Medic, GPO and Intune update policy, the WSUS endpoint, and which endpoint protection is running. Stops here if it isn't running as admin or SYSTEM. |
| **QUENCH** | Stops the update stack (Update Orchestrator, Delivery Optimization, Windows Update, BITS, Cryptographic Services, Windows Installer) before touching anything. |
| **DISSOLVE** | Cancels BITS jobs, renames `SoftwareDistribution` and `catroot2` out of the way, and purges the Delivery Optimization cache. Renamed, never deleted, so every step can be undone. |
| **RECONSTITUTE** | Puts service startup types back where Windows expects them, re-enables disabled update tasks, and, only if you asked, repairs the component store with DISM and SFC or clears the update policy. |
| **PROGNOSIS** | Restarts the stack, then forces a download of every pending update and checks each one. Reports **CLEAR**, **DISSOLVED** or **ATTENTION**, with anything you need to act on. |

## Proves the fix instead of hoping

Asking Windows to "check for updates" proves nothing on a box that was stuck at downloading. So after the reset, ALKAHEST downloads every pending quality and servicing update (never drivers or feature upgrades) and reads back the result for each one.

- **Downloaded:** the reset worked. Run Panacea to install them.

- **Some failed:** each one is listed with its error code. Look the code up before resetting again; a second reset rarely fixes what the first didn't.

- **Still stuck after two hours:** the cache was never the problem. It's somewhere past this machine (network path, proxy, WSUS, Delivery Optimization), and the report says so.

It downloads and stops. Installing is Panacea's job.

## Built for EDR

ALKAHEST was written for machines running Panda Adaptive Defense, which is why it doesn't look like the "reset Windows Update" recipe pasted around forums. The steps EDR blocks are skipped on purpose, and the output says so instead of failing quietly.

| Never used | Used instead |
|---|---|
| `regsvr32` re-registering update DLLs | Not needed; caches are rebuilt by Windows |
| `bitsadmin.exe` | `Get-BitsTransfer` / `Remove-BitsTransfer` |
| `net stop`, `sc.exe config` | `Stop-Service` / `Set-Service` |
| `wusa.exe` | The native Windows Update API |
| `-EncodedCommand`, base64, download cradles | Nothing. Never. |
| Deleting anything | `Rename-Item` |

EDR often holds file handles inside `SoftwareDistribution` while it scans downloaded updates. Renames retry with backoff, then fall back to renaming `Download` and `DataStore` individually, then report the folder as locked instead of forcing it. A blocked step never kills the run.

## Usage

1. Open PowerShell as Administrator, or a ScreenConnect backstage session (runs as SYSTEM).
2. Paste the entire contents of `alkahest_paste.ps1` and press Enter.

In an interactive session, a setup panel appears first:

```
── DISPENSARY SETUP
   [1] DryRun ............ OFF
   [2] Servicing repair .. ON
   [3] WinSxS cleanup .... OFF
   [4] Timeouts .......... ∞
   [5] Clear WU policy ... OFF
   [6] Queue locked work . OFF
   [7] Force download .... ON

   [Enter] proceed  ·  [Q] quit
```

Type a number to toggle that option, press Enter to run, or Q to quit without changing anything. Once a long step is running, **S** skips it. In non-interactive contexts (SYSTEM, RMM) the panel is skipped and the defaults from the config block are used.

## Configuration

All settings live in the `CONFIG BLOCK` at the top of the script.

| Setting | Default | Meaning |
|---|---|---|
| `DryRun` | `$false` | Report only, change nothing |
| `ServicingRepair` | `$true` | DISM RestoreHealth and SFC, only if the component store looks sick |
| `RunWinSxS` | `$false` | DISM component cleanup (never `/ResetBase`) |
| `ClearPolicy` | `$false` | Back up, then remove GPO Windows Update policy. Requires typing `CLEAR` |
| `ScheduleLocked` | `$false` | If a cache is locked, queue the rename for the next boot |
| `ForceDownload` | `$true` | After the reset, download pending updates and check each one |
| `MinFreeGB` | `10` | Free space below this is flagged; updates stall without room |
| `WuDownloadTimeoutSec` | `7200` | When a download counts as stuck |
| `*TimeoutSec` (DISM, SFC, package scan) | `0` | `0` means no limit; slow machines are normal |
| `NoColor` | `$false` | Force the plain ASCII display |

## Update policy: GPO vs Intune

Deferrals, pauses and a pinned target version look exactly like a stuck update stack, so DIAGNOSE reports both policy sources.

| Source | Registry location | Comes back after clearing? |
|---|---|---|
| Active Directory GPO | `SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate` | **Yes**, on the next policy refresh (90 min default, or `gpupdate /force`) |
| Intune Update rings | `SOFTWARE\Microsoft\PolicyManager\...\Update` | Never touched by ALKAHEST |
| Intune Administrative Templates | `SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate` | **Don't assume so.** A routine sync may treat the policy as already applied |

"Clear WU policy" touches only the GPO path and writes a `.reg` backup first. If the backup fails, it refuses to continue. To restore an Intune-delivered value, import the backup or re-save the profile in Intune to force a fresh push. See Microsoft's notes on [Windows Update client policies](https://learn.microsoft.com/windows/deployment/update/waas-configure-wufb) and [Intune policy refresh intervals](https://learn.microsoft.com/intune/device-configuration/troubleshoot-device-profiles#policy-refresh-intervals).

## Output for RMM

Each run writes two files to `%ProgramData%\Alkahest\Updates\`:

- `alkahest_<HOST>_<timestamp>.log`, the full transcript
- `alkahest_<HOST>_<timestamp>.json`, a machine-readable summary (EDR detected, caches renamed, BITS jobs cleared, repair results, GPO and MDM policy found, stuck packages, updates downloaded or failed, pending before and after, reboot needed, overall status)

Policy backups, when made, land in the same folder as `wu_policy_<HOST>_<timestamp>.reg`.

The result is also left in `$AlkahestExit` instead of being passed to `exit`, so a backstage session stays open afterwards:

| `$AlkahestExit` | Meaning |
|---|---|
| `0` | Clear |
| `1` | Reboot needed |
| `2` | Needs attention (repair failed, unfixable SFC damage, downloads still stuck, or not elevated) |

## Requirements

- Windows 10 or 11
- PowerShell 5.1 or later
- Administrator or SYSTEM
- **English (en-US) Windows.** DISM and SFC results are read from their English output. Other languages will run, but repair verdicts may come back as inconclusive.

## Safety

- Never deletes. Caches are renamed to `.old.<timestamp>`.
- Never reboots. The report says when a restart is the actual fix.
- Never touches a staged servicing transaction (`pending.xml`, `SessionsPending.xml`, PackagesPending). They're reported, not cleared; clearing them by hand is how a machine ends up with a half-installed component store.
- Never clears update policy unless you turn it on, type `CLEAR`, and the backup succeeds.
- Never claims a machine is up to date. A forced download that finds nothing reports "nothing offered", not "current".
- Never touches user files or the Recycle Bin.

## Credits

Designed, directed and field-tested by Kaylee. Code written with AI assistance.

## License

[MIT](LICENSE)

*Dispensed by ALKAHEST · keep out of reach of end users.*
