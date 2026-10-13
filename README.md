# ALKAHEST

**The universal solvent.** Sibling to [Panacea](../panacea). Panacea is the general tune-up;
ALKAHEST does one thing: it unsticks a Windows Update stack that will not move.

One file, one paste, no installs, no tools fetched, no reboots. The only thing it downloads is
the Windows Update payloads the box was already stuck on, to prove the reset worked.

```
DIAGNOSE  ->  QUENCH  ->  DISSOLVE  ->  RECONSTITUTE  ->  PROGNOSIS
 read it     stop it     rename it     put it back      tell the truth
```

## Same chrome as Panacea

They are meant to look and behave like the same instrument. Shared, byte-for-byte where it
matters:

- **Palette** — the same `$Clr` table (orange `255,140,0`, green `80,200,120`,
  cyan `90,190,220`, grey `120,120,120`, red `220,50,50`).
- **VT sniff and ASCII skin** — `$Host.UI.SupportsVirtualTerminal`, with the same `$G` glyph
  map degrading `[✓] ℞ ⚕ ⚠` to `[OK] Rx + !!` when the console can't do truecolor.
- **`Rule` / `Status` / `Roll`** — identical signatures, identical dot-leader widths, the same
  `[DRY RUN]` suffix on every tier header.
- **`Invoke-Guarded`** — Panacea's, adopted whole: `Register-ObjectEvent` with a `try/finally`
  unregister so no subscription outlives the scriptblock, braille spinner, `-ShowNative` for
  DISM/SFC's own progress bar, S-key skip, `0` meaning infinite.
- **Rx label** — same 62-wide box, same `RX # / DATE / REFILLS ∞ / PATIENT / PRESCRIBER / DX`
  header, same conditional orange **AUXILIARY WARNINGS** sticker, same
  `keep out of reach of end users` footer.
- **Exit contract** — `$global:AlkahestExit` (0 clear, 1 reboot-needed, 2 attention), no `exit`
  call, same `dispensary closed · ... · log:` epitaph, JSON summary written beside the
  transcript for RMM ingest.
- **SFC verdict** — read from the CBS.log delta, not stdout, because `-ShowNative` doesn't
  redirect stdout. Same technique as Panacea's MEND tier, same English-string caveat.

Tier verbs differ on purpose: Panacea mends and doses, ALKAHEST quenches and dissolves.

## Running it

Copy the **entire** contents of `alkahest_paste.ps1` — from `$alkahest = @'` through the
final `[ScriptBlock]::Create($alkahest).Invoke()` — and paste it into an elevated
ScreenConnect backstage or frontstage PowerShell prompt. It arrives as one indivisible
object, so the console cannot nibble it line by line and detonate a fragment early.

The DISPENSARY SETUP panel opens first on an interactive console and is skipped under
SYSTEM. `Enter` proceeds, `Q` quits touching nothing, number keys toggle. Once a long step is
running, `S` skips it.

| # | Option | Default | What it does |
|---|---|---|---|
| 1 | DryRun | off | Narrates every action, changes nothing |
| 2 | Servicing repair | on | DISM RestoreHealth + SFC, only if the store looks sick |
| 3 | WinSxS cleanup | off | `StartComponentCleanup`, never `/ResetBase` |
| 4 | Timeouts | ∞ | Cycles ∞ → 30m → 60m. Slow boxes are the normal case |
| 5 | Clear WU policy | **off** | Backs up then removes GPO-path WSUS keys. Requires typing `CLEAR` |
| 6 | Queue locked work | off | If a cache is locked, schedule the rename for next boot |
| 7 | Force download | on | After the reset, downloads pending updates (never installs) and reads back each one |

## Forced download

A scan request only asks Windows to look. On a box that was stuck at "downloading", that
proves nothing, so PROGNOSIS goes one step further: it searches, downloads every pending
quality and servicing update (drivers and feature upgrades stay fenced off), and reads the
verdict for each update on its own instead of trusting the batch result.

- **Downloaded:** the reset worked. The roll-up says how many, and Panacea installs them.
- **Some failed:** each one is named with its HRESULT on the orange sticker. Look the code up
  before resetting again; a second reset rarely fixes what the first didn't.
- **Still stuck after two hours:** the cache was never the cause. The problem is past this
  endpoint (network path, proxy, WSUS, Delivery Optimization) and the label says so.
  `WuDownloadTimeoutSec` sets the ceiling, and `S` gives up sooner on an interactive console.

The download runs on a worker thread because WUA's `Download()` call blocks until Windows
Update gives up, which a wedged stack never does. The async `BeginDownload` would avoid that,
but it needs a compiled COM callback, which means `Add-Type` and `csc.exe`, the same kind of
EDR-flagged LOLBin this script avoids everywhere else. If the ceiling hits, the worker is
abandoned mid-call and never goes on to anything else. Panacea carries the identical
`Invoke-WuPipeline`, so change both or neither.

## Panda Adaptive Defense

This was written for an estate that runs Panda, which is why it does not look like the
"reset Windows Update" recipe everyone pastes off a forum.

**Not used, on purpose, and reported as such in the output:**

- `regsvr32` re-registration of the WU DLLs — the single most-blocked step in the old recipe
- `bitsadmin.exe`, `wusa.exe`, `sc.exe config`, `net stop` — LOLBins that light up EDR
- `-EncodedCommand`, download cradles, base64 — never
- deleting anything at all

**Used instead:** `Stop-Service` / `Set-Service`, `Get-BitsTransfer` / `Remove-BitsTransfer`,
`Delete-DeliveryOptimizationCache`, `Enable-ScheduledTask`, `Rename-Item`, and the two
Microsoft-signed binaries nobody argues with, `DISM.exe` and `sfc.exe`.

Panda also holds file handles inside `SoftwareDistribution` while it scans staged payloads,
so renames retry four times with backoff, fall back to renaming `Download` and `DataStore`
individually, and then report locked rather than forcing anything. A blocked step never kills
the run.

## Update policy: GPO vs Intune

The "Clear WU policy" option touches exactly one key,
`HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate`. It is worth knowing what that
does and does not reach before arming it.

| Source | Writes where | Comes back on its own? |
|---|---|---|
| Active Directory GPO | `SOFTWARE\Policies\...\WindowsUpdate` | **Yes.** Own cycle, 90 min by default, or `gpupdate /force` |
| Intune Update rings | `SOFTWARE\Microsoft\PolicyManager\...\Update` | Not applicable — this option never touches that key |
| Intune ADMX / Administrative Templates | `SOFTWARE\Policies\...\WindowsUpdate` | **Do not assume it.** See below |

Microsoft documents the two registry paths as separate
([Configure Windows Update client policies](https://learn.microsoft.com/windows/deployment/update/waas-configure-wufb#summary-mdm-and-group-policy-settings-for-windows-10,-version-1703-and-later)),
and nothing in the docs promises that MDM re-pushes a value that was deleted locally while the
policy itself is unchanged. A routine device sync may simply see the policy as already applied.
The reliable restore is the `.reg` backup, or editing and re-saving the profile in Intune to
force a change-based push.

Check-in cadence, for setting expectations on a call: maintenance sync roughly every 8 hours,
and no more than one every 6.5 hours
([policy refresh intervals](https://learn.microsoft.com/intune/device-configuration/troubleshoot-device-profiles#policy-refresh-intervals)).
Faster: **Settings > Accounts > Access work or school > Info > Sync**, or the Sync action in
the Intune admin center.

DIAGNOSE reads the PolicyManager path too and reports it, because a ring-managed box with an
empty GPO key would otherwise be reported as having no update policy at all. Deferrals, pauses
and a pinned target release version look exactly like a stuck update stack.

## What it will not do

- **Delete.** Caches are renamed to `.old.<timestamp>`, so every step is reversible.
- **Reboot.** It says so on the orange sticker when a restart is the actual fix, and stops there.
- **Touch a staged CBS transaction.** `pending.xml`, `SessionsPending.xml` and the
  PackagesPending key are reported, never cleared. Clearing those by hand is how a machine
  gets a half-installed component store.
- **Clear WSUS/Intune policy silently.** Policy is reported by default; removal is opt-in,
  backed up to `.reg` first, and refuses to proceed if the backup fails.
- **Claim the machine is up to date.** It requests a detection pass and reports that it
  *asked*. Under SYSTEM the COM search can no-op silently, and a "current" verdict from here
  would be a lie. A forced download that finds nothing reports "nothing offered", not "current".
- **Install updates.** It downloads them and stops. Installing is Panacea's job.

## Notes for the next person in this file

- Presentation is deliberately a copy of Panacea's. If you change the palette, the glyph map,
  `Rule`/`Status`/`Roll`, or the label frame here, change it there too or the pair stops
  reading as one instrument.
- DISM and SFC verdict parsing matches English strings. On a localized install those differ;
  parse `Image Health State:` out of `%WINDIR%\Logs\DISM\dism.log` instead, which stays
  English. Same caveat Panacea carries.
- Adding features here is how this turns into the Swiss army knife it is not supposed to be.
  Disk cleanup, startup analysis, driver work and SMART all live elsewhere — Panacea and Augur
  already own them.
