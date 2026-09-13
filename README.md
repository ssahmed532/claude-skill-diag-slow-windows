# diag-slow-windows

A [Claude Code](https://claude.com/claude-code) skill that decides whether a Windows 11 machine is actually slow and, if so, why.

It runs a read-only PowerShell diagnostic and then interprets the output against a table of healthy ranges, a list of known event-log traps, and a set of ranked remediations. The result is a verdict first, then the causes that matter, each with a copy-pasteable fix.

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

The script makes no changes. Elevation is optional; without it, SMART counters, BitLocker, thermal zones and the boot-duration log are skipped and the script says so.

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
| `interpret.md` | Healthy-range table, thresholds, event-log traps, remediation commands, and how to run an elevated fix |

## Running the script on its own

```powershell
pwsh -NoProfile -File .\diagnose.ps1
pwsh -NoProfile -File .\diagnose.ps1 -CheckUpdates
```

## License

MIT, see [LICENSE](LICENSE).
