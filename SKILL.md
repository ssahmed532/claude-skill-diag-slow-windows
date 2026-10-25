---
name: diag-slow-windows
description: Custom, bespoke Claude Skill to diagnose a slow Windows 11 installation. Decides whether the machine is actually slow and, if so, why. Runs a read-only PowerShell diagnostic (power limits, CPU clocks, boot types and boot timeline, Service Control Manager 7009 and 7026 analysis, background app load, VBS, RAM channels, disk health and cold-cache read speed, startup entries, shell extensions, drivers and biometrics, event log) and produces a verdict plus a ranked list of causes with exact remediation commands. Use whenever the system feels slow, boots slowly, or the UI lags.
disable-model-invocation: true
allowed-tools: PowerShell Bash Read
---

Decide whether this Windows 11 machine is slow and why. Analyse only; make no changes unless the user asks afterwards.

## Step 1: run the diagnostic

Run the bundled script and capture its full output. It is read-only and takes about 45 seconds. Elevation is optional; if the current shell is not elevated, the script says which sections it skipped (SMART counters, BitLocker, thermal zones, boot-duration log). Add `-CheckUpdates` to also search Windows Update for pending items (about 30 s more).

```powershell
pwsh -NoProfile -File "$env:USERPROFILE\.claude\skills\diag-slow-windows\diagnose.ps1"
```

Redirect the output to a file in the scratchpad and Read it in sections; it is long. Do not re-implement the checks ad hoc; if the script needs a new check, add it to the script so the next run has it too. If the machine booted more than 10 minutes ago, say the cold-cache read figure measures RAM cache, not the disk.

Every run also writes `%TEMP%\win-diag-metrics_<yyyy-MM-dd_HHmmss>.json` holding the measured KPIs, and prints a delta table against the newest earlier file there, so regressions show up run over run. `-JsonOut <path>` moves the file, `-NoJson` suppresses it. Interpret that table with the "METRICS BASELINE" section of `interpret.md`: the CPU, DNS and GPU figures are noisy 10-second samples, and a WORSE flag counts only when the two runs were taken in comparable states (check `uptime_min`, `power_source`, `top_cpu`).

## Step 2: interpret

Read `interpret.md` in this skill folder. It holds the healthy-range table, the thresholds, the traps (events that look alarming but are not), and the remediation commands for each finding. Judge each finding against those thresholds rather than against instinct.

Start with the verdict: does the machine pass the healthy-range table at idle? If yes, say so and treat everything after as housekeeping and "possible causes of intermittent slowness", not as an explanation for a slow machine.

Then work through causes in this order, because the earlier ones dominate the "feel" of the machine:

1. CPU clock vs nominal, power source, power mode slider, OEM power-limit drivers.
2. Permanent background load: Electron apps, WebView2 hosts, cloud sync clients, VPN filters, vendor helpers, widgets. Weigh these against the core count.
3. Hypervisor and Memory Integrity overhead, single-channel RAM, iGPU pressure with multiple monitors.
4. Boot: cold-boot count vs fast-startup count, the milestone timeline, then 7009 timeouts only where the script marks them REAL WAIT, then 7026 boot-start driver leftovers.
5. Transient load that happens to be running now (Office updates, indexer rebuild, Defender scan, Edge updater). Say it is transient.
6. Disk health, free space, paging, UI effects, crashing OEM helpers.

## Step 3: report

Lead with the verdict and the healthy-range table. Then the single largest cause and the one test that proves it (for example, plug in and re-check clock speed). Then the remaining causes ranked by impact, each with the evidence figure and the fix. Close with what was checked and is fine, and what could not be checked without elevation, so the user knows what to stop worrying about.

Rules for the report:

- Every fix is a copy-pasteable command or an exact Settings path. Say which ones need an elevated shell.
- A 7009 logged less than 45 s after the boot event is log noise; never describe it as a 45-second boot delay. The script prints the T+ figure; quote it.
- Distinguish "not running, cleanup only" from "running and costing you". Stale Task Manager startup entries are common.
- Flag security trade-offs (Memory Integrity, Defender, VPN protection) as optional and last.
- Name what cannot be fixed (core count, one-slot RAM) so the user does not chase it.
- Do not run any remediation. Offer to apply the safe ones only after the user has read the report.

## Step 4: if the user then asks for a fix

Follow the "Running something elevated" section of `interpret.md`: inspect the target with an elevated read-only script first, then apply the change in a second elevated script that prints BEFORE and AFTER, then verify. Prefer reversible actions (disable a device, set a service to Manual) over deletions when both solve the symptom. Say when a reboot is needed and offer to re-check the log after it.

## Arguments

Optional free text describing the symptom (for example "slow boot", "Explorer lags", "fans loud", "is it slow at all"). Use it to weight the interpretation, not to skip sections of the script.
