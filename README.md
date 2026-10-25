# diag-slow-windows

A [Claude Code](https://claude.com/claude-code) skill that decides whether a Windows 11 machine is actually slow and, if so, why.

It runs a read-only PowerShell diagnostic and then interprets the output against a table of healthy ranges, a list of known event-log traps, and a set of ranked remediations. The result is a verdict first, then the causes that matter, each with a copy-pasteable fix.

Each run publishes the result as a new Claude artifact titled "<make model> Performance and Health Report", for example "Lenovo ThinkPad E15 Gen 2 Performance and Health Report". Every report uses the same template. It shows the exact Windows edition, version and build at the time of the run, the verdict, the healthy-range table, charts of the evidence, the ranked findings with their fixes, and the recommended order of work.

## What the script checks

- CPU clock vs nominal, power source, power mode slider, OEM power-limit drivers
- Live load over a 10 s sample: CPU, disk, memory, DPC and interrupt time, top consumers
- Background load: Electron apps, WebView2 hosts, cloud sync clients, VPN filters, non-Microsoft services
- Virtualization-based security and hypervisor presence
- RAM channel configuration, disk health, TRIM, free space, cold-cache read speed
- Boot types (cold vs fast startup), boot milestones, Service Control Manager 7009 and 7026 analysis with a noise-vs-real-wait verdict
- Startup entries and their Task Manager approval state, per-app launch cost at logon
- Shell extensions, devices with problems, biometric sensors and whether anyone is enrolled
- Security software, DNS and ping latency, UI effects, Windows Update history, temp folders

The script makes no changes.

## The UAC prompt

Before the diagnostic starts, Claude tells you that a Windows **User Account Control (UAC) prompt** is about to appear, asking to run PowerShell as administrator. The script stays read-only either way. Approving the prompt adds the checks that Windows only allows an elevated process to make:

| Elevated check | What it adds to the report |
|---|---|
| Disk SMART and wear counters | Drive temperature, wear percentage, read and write error totals, and power-on hours for each physical disk |
| BitLocker status | Whether each volume is encrypted, and with which method |
| ACPI thermal zones | Temperatures from the firmware's thermal zones, on machines that report them to Windows |
| Boot-duration history | Total, main-path and post-boot seconds for recent boots (Diagnostics-Performance event 100), so a boot-time trend can be charted |
| System-wide scheduled tasks | Third-party tasks registered for the whole machine (OEM updaters, browser updaters) that a standard user cannot list |

If you deny the prompt, or leave it unanswered for 2 minutes, the diagnostic runs as your standard user instead. The report then says that the elevated checks were skipped. Every other check still runs. Windows cannot withdraw a UAC prompt, so after a timeout it stays on screen. Click No; approving it late runs nothing. To skip the prompt from the start, ask for a run with no elevation (`/diag-slow-windows no elevation`). If Claude Code is already running elevated, no prompt appears.

## Install

```powershell
git clone https://github.com/ssahmed532/claude-skill-diag-slow-windows "$env:USERPROFILE\.claude\skills\diag-slow-windows"
```

Then in Claude Code:

```
/diag-slow-windows
/diag-slow-windows slow boot
/diag-slow-windows is it slow at all
```

Requires PowerShell 7 (`pwsh`).

## Files

| File | Purpose |
|---|---|
| `SKILL.md` | The skill definition: steps, reporting rules, argument handling |
| `diagnose.ps1` | The read-only diagnostic script |
| `run-diagnostics.ps1` | Launcher: asks for elevation through UAC, waits up to 2 minutes, and falls back to a standard run |
| `interpret.md` | Healthy-range table, thresholds, event-log traps, remediation commands, and how to run an elevated fix |
| `report-template.html` | The report artifact template, the same for every run |
| `build-report.ps1` | Fills the template with one run's report data and sets the title |
| `report-sample.json` | Example report data showing every field the template reads |

## Running the script on its own

```powershell
pwsh -NoProfile -File .\diagnose.ps1
pwsh -NoProfile -File .\diagnose.ps1 -CheckUpdates
pwsh -NoProfile -File .\run-diagnostics.ps1 -OutDir $env:TEMP -CheckUpdates    # with the UAC prompt
```

## Versioning

The skill follows [Semantic Versioning](https://semver.org). The current version is in the `metadata.version` field of `SKILL.md`, and each release is tagged `vX.Y.Z`.

- **Major**: a change that breaks existing use: a `diagnose.ps1` parameter removed or renamed, an incompatible change to the metrics JSON (which also bumps its `schema`), a renamed skill, or the script making changes to the machine.
- **Minor**: a backward-compatible addition: a new check, parameter, metric or interpretation section.
- **Patch**: a fix that adds nothing: a measurement or threshold corrected, a misleading reading fixed, a documentation correction.

## License

MIT, see [LICENSE](LICENSE).
