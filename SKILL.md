---
name: diag-slow-windows
description: Custom, bespoke Claude Skill to diagnose a slow Windows 11 installation. Decides whether the machine is actually slow and, if so, why. Runs a read-only PowerShell diagnostic (power limits, CPU clocks, boot types and boot timeline, Service Control Manager 7009 and 7026 analysis, background app load, VBS, RAM channels, disk health and cold-cache read speed, startup entries, shell extensions, drivers and biometrics, event log), elevated through a UAC prompt when the user approves it, and publishes a "<make model> Performance and Health Report" artifact with the verdict, the evidence, a ranked list of causes and exact remediation commands. Use whenever the system feels slow, boots slowly, or the UI lags.
disable-model-invocation: true
allowed-tools: PowerShell Bash Read Write Artifact
metadata:
  version: 1.2.0
---

Decide whether this Windows 11 machine is slow and why, then publish the findings as a report artifact. Analyse only; make no changes unless the user asks afterwards.

## Step 1: tell the user about the UAC prompt, then run the diagnostic

Before running anything, tell the user in your reply, as its own short paragraph, that:

- a Windows UAC prompt is about to appear, asking to run PowerShell as administrator;
- approving it lets the read-only diagnostic also collect what only an elevated run can see: disk SMART and wear counters (temperature, wear, read/write errors, power-on hours), BitLocker status, ACPI thermal-zone temperatures, the boot-duration history (total, main path and post-boot time for recent boots), and system-wide scheduled tasks;
- the script makes no changes either way;
- if they deny the prompt, or leave it unanswered for 2 minutes, the diagnostic continues without those checks.

Then, in the same response, run the launcher. It tries the elevated run, falls back to a standard run when the prompt is denied or times out, and writes the output to the scratchpad. Set the tool timeout to 600000 ms: the UAC wait, the run itself (about 45 s) and `-CheckUpdates` (about 30 s more) all count against it.

```powershell
pwsh -NoProfile -File "$env:USERPROFILE\.claude\skills\diag-slow-windows\run-diagnostics.ps1" -OutDir "<scratchpad>" -CheckUpdates
```

It prints two lines: `elevation: <outcome>` (approved, denied, timed out, already elevated, skipped) and `report: <path>`. Keep the outcome for the report. If it is anything but approved or already elevated, say in one line that the elevated checks were skipped and why, and carry on: the rest of the diagnostic is complete. Do not retry the prompt. On a timeout the prompt stays on screen, because Windows cannot withdraw it: tell the user to click No. Approving it late does nothing, because the launcher has already cancelled that elevated run. Pass `-NoElevate` instead when the user has said not to elevate (outcome `skipped`, no prompt). Omit `-CheckUpdates` when the user wants a quick run.

Read the report file in sections; it is long. Do not re-implement the checks ad hoc; if the script needs a new check, add it to the script so the next run has it too. If the machine booted more than 10 minutes ago, say the cold-cache read figure measures RAM cache, not the disk.

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

## Step 3: publish the report artifact

Every completed run publishes a new artifact. The page comes from `report-template.html` in this skill folder, which is the same template on every run. Do not hand-write or restyle the page; supply only the data.

1. Write the run's report data as JSON to `<scratchpad>\report-data_<yyyy-MM-dd_HHmmss>.json`. `report-sample.json` in this folder shows every field the template reads. Fill them from this run only:
   - `device`: the `Device:` line of the diagnostic output (for example `Lenovo ThinkPad E15 Gen 2`). The build script turns it into the title `<device> Performance and Health Report`; do not set a title yourself.
   - `windows`: the edition, version and build number from the `OS:` line, as at the end of this run (for example `Windows 11 Pro 25H2 (OS build 26200.9711)`).
   - `scanned`: the timestamp on the first line of the output. `elevation`: the launcher's outcome, verbatim. `skill_version`: `metadata.version` above. `baseline`: the metrics file name.
   - `verdict`, `tiles`, `checks` (the full healthy-range table), `charts` (`bars`, `stacked` or `table`), `findings` (ranked, each with its evidence figure and its `fix`), `plan` (the order of fixes), `fine`, `fixed` (what the hardware sets) and `unmeasured` (including the elevated checks when they were skipped).
   - Text fields accept `**bold**` and `` `code` `` only.
2. Build the page. The file name carries the run's timestamp, so each run gets a new file and therefore a new artifact URL:

   ```powershell
   pwsh -NoProfile -File "$env:USERPROFILE\.claude\skills\diag-slow-windows\build-report.ps1" -Data "<scratchpad>\report-data_<stamp>.json" -Out "<scratchpad>\diag-report_<stamp>.html"
   ```

3. Publish that `.html` file with the Artifact tool: a new artifact, `icon` `chart`, and a one-sentence `description` naming the device and the verdict. Never pass the `url` of an earlier report.

Keep personal data out of the page: no user names, host names, SIDs, user-profile paths, serial numbers or personal file and folder names. Describe them by kind instead ("three TV-season folders, 123 GB"). The diagnostic output contains all of these.

## Step 4: reply in the conversation

Keep the reply short; the artifact holds the detail. Give the verdict in one or two sentences, the largest cause and the test that proves it, the top three fixes, whether the elevated checks ran, and the artifact link. Then offer to apply the safe fixes.

Rules for the report (both the artifact and the reply):

- Every fix is a copy-pasteable command or an exact Settings path. Say which ones need an elevated shell.
- A 7009 logged less than 45 s after the boot event is log noise; never describe it as a 45-second boot delay. The script prints the T+ figure; quote it.
- Distinguish "not running, cleanup only" from "running and costing you". Stale Task Manager startup entries are common.
- Flag security trade-offs (Memory Integrity, Defender, VPN protection) as optional and last.
- Name what cannot be fixed (core count, one-slot RAM) so the user does not chase it.
- Order the findings: the single largest cause first with the one test that proves it (for example, plug in and re-check clock speed), then the rest by impact. Close with what was checked and is fine, and what could not be checked, so the user knows what to stop worrying about.
- Do not run any remediation. Offer to apply the safe ones only after the user has read the report.

## Step 5: if the user then asks for a fix

Follow the "Running something elevated" section of `interpret.md`: inspect the target with an elevated read-only script first, then apply the change in a second elevated script that prints BEFORE and AFTER, then verify. Prefer reversible actions (disable a device, set a service to Manual) over deletions when both solve the symptom. Say when a reboot is needed and offer to re-check the log after it.

## Arguments

Optional free text describing the symptom (for example "slow boot", "Explorer lags", "fans loud", "is it slow at all"). Use it to weight the interpretation, not to skip sections of the script. "No elevation" or "no admin" means run with `-NoElevate`; "quick" means omit `-CheckUpdates`.
