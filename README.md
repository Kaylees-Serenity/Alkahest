# ALKAHEST

**The universal solvent.** Sibling to [Panacea](../panacea). Panacea is the general tune-up;
ALKAHEST does one thing: it unsticks a Windows Update stack that will not move.

One file, one paste, no installs, no downloads, no reboots.

```
DIAGNOSE  ->  QUENCH  ->  DISSOLVE  ->  RECONSTITUTE  ->  PROGNOSIS
 read it     stop it     rename it     put it back      tell the truth
```

## Running it

Copy the **entire** contents of `alkahest_paste.ps1` — from `$alkahest = @'` through the
final `[ScriptBlock]::Create($alkahest).Invoke()` — and paste it into an elevated
ScreenConnect backstage or frontstage PowerShell prompt. It arrives as one indivisible
object, so the console cannot nibble it line by line and detonate a fragment early.

A setup panel opens first. `ENTER` starts with the defaults; number keys toggle. During any
long step, `S` skips that step and moves on.

| Option | Default | What it does |
|---|---|---|
| Dry run | off | Narrates every action, changes nothing |
| Step timeout | infinite | Slow boxes are the normal case, so nothing is cut by default |
| Servicing repair | on | DISM RestoreHealth + SFC, only if the image actually looks sick |
| Component cleanup | off | `StartComponentCleanup`, never `/ResetBase` |
| Clear WU policy | **off** | Backs up then removes WSUS/GPO keys. Requires typing `CLEAR` |
| Queue locked work | off | If a cache is locked, schedule the rename for next boot |

`$global:AlkahestExit` carries the verdict — `0` clear or dissolved, `1` partial, `2` needs a
human — without killing the host session. A JSON summary lands in
`C:\ProgramData\Alkahest\` alongside the transcript, for RMM ingest.

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
individually, and then report **BLOCKED** rather than forcing anything. A blocked step never
kills the run.

## What it will not do

- **Delete.** Caches are renamed to `.old.<timestamp>`, so every step is reversible.
- **Reboot.** It says so in orange when a restart is the actual fix, and stops there.
- **Touch a staged CBS transaction.** `pending.xml`, `SessionsPending.xml` and the
  PackagesPending key are reported, never cleared. Clearing those by hand is how a machine
  gets a half-installed component store.
- **Clear WSUS/Intune policy silently.** MSP clients point at WSUS on purpose. Policy is
  reported by default; removal is opt-in, backed up to `.reg` first, and refuses to proceed
  if the backup fails.
- **Claim the machine is up to date.** It requests a detection pass and reports that it
  *asked*. Under SYSTEM the COM search can no-op silently, and a "current" verdict from here
  would be a lie.

## Notes for the next person in this file

- `Invoke-Guarded` reads the child process's stdout synchronously, character by character. It
  deliberately does **not** use `Register-ObjectEvent`: that pattern leaks event subscriptions
  into the host runspace whenever anything between register and unregister throws, which is a
  bug Panacea already paid for. The char-level read is also what makes DISM's carriage-return
  progress bar render live.
- Tradeoff of that choice: stderr is drained only after the process exits, so a child that
  floods stderr could in principle fill its pipe. DISM and SFC do not.
- Adding features here is how this turns into the Swiss army knife it is not supposed to be.
  Disk cleanup, startup analysis, driver work and SMART all live elsewhere — Panacea and Augur
  already own them.
