# Interpreting diagnose.ps1 output

Thresholds and remediations, organised by script section. Elevated shell is marked (admin).

## First decide whether the machine is slow at all

Users often ask "is it slow?" rather than "why is it slow?". Answer that first with a verdict and a table of the measured figures against healthy ranges. A machine that passes all of these is not slow at idle; any remaining perceived slowness is intermittent and needs the script re-run while it is happening.

| Measurement (idle, a few minutes after a cold boot) | Healthy |
|---|---|
| `% Processor Time` | under 20% (pwsh running the script accounts for a few points) |
| `% Processor Performance` | over 100% means turbo is working; under 80% under load means clamped |
| `Processor Queue Length` | under 2 |
| RAM used | under 80%, pagefile usage 0%, `Pages/sec` under 50 |
| `PhysicalDisk % Idle Time` | over 90% |
| `Avg. Disk sec/Read` / `sec/Write` | under 0.010 on NVMe, under 0.020 on SATA SSD |
| Cold-cache sequential read | over 1000 MB/s NVMe, over 400 MB/s SATA SSD, 100 to 150 MB/s HDD |
| Boot milestones | logon tasks begin under 30 s, last startup app under 90 s |
| WinSAT scores | 8 or above on every line (max 9.9) |
| DNS resolve / ping | under 100 ms / under 30 ms |
| Reliability index | trending upward; below 5 means frequent crashes |

Say plainly which of these passed. Then list the causes that are still worth fixing, ranked.

## POWER and LIVE LOAD: is the CPU being held back?

The most common cause of a machine that "feels" slow while nothing looks broken.

| Signal | Threshold | Meaning |
|---|---|---|
| `% of Maximum Frequency` average | below 70% while `% Processor Time` is above 40% | Power-limited, not idle |
| `% of Maximum Frequency` 70 to 85% at idle | normal | Idle downclocking, not throttling |
| `Processor Frequency` average vs baseMHz | below base clock under load | Firmware or power plan is clamping |
| Power source | BATTERY | Thin laptops clamp PL1 hard on battery |
| Power mode slider | Balanced or Best power efficiency | Slider drives OEM thermal profile on Lenovo, Dell, HP |
| PROCTHROTTLEMAX | below 100 | Someone capped the max processor state |
| PERFBOOSTMODE | AC=0 or DC=0 | Turbo disabled; "not overridden" or 2 is normal. It is a hidden setting, so `powercfg /q` prints nothing for it; the script reads the registry override instead |
| `% Privileged Time` | above 25% | Heavy kernel time: drivers, hypervisor, AV filters |
| `% Interrupt Time` + `% DPC Time` | above 5% combined | Driver problem, usually network, audio or storage |

Fix: plug in, or set the slider to Best performance. Works on both AC and DC:

```powershell
powercfg /overlaysetactive overlay_scheme_max
```

Undo with `powercfg /overlaysetactive overlay_scheme_balanced`.

Trap: Kernel-Processor-Power event Id 55 is an informational capability dump logged once per core per boot. It is not throttling. Real firmware throttling is Id 37.

## EVENT LOG: Service Control Manager 7009 timeouts

The script prints each 7009 with `T+` seconds since the preceding Kernel-Boot 27 event, and a verdict.

- **`T+` under 45 s = noise.** SCM logs "a timeout was reached (45000 milliseconds)" the instant a launched service process exits without ever connecting to the control dispatcher. The 45000 is the configured limit, not elapsed time. Nothing waited; boot was not delayed. Do not report these as a 45-second boot delay. This was exactly the SynaHlp and Intel TPM Provisioning case on a 2021 Lenovo ThinkPad: both fired at T+13 to T+16 s on every cold boot while the desktop arrived at T+18 s.
- **`T+` 45 s or more = a real wait.** Dependents of that service were blocked. Fix it.
- 7009 prints the service **display name**. Look services up by `DisplayName`, not `Name`; the script does this. `Get-Service *foo*` matches Name only and will miss it.
- **NOT REGISTERED** means no service by that display name exists. A driver or helper creates it on the fly, starts it, and it dies. Search for the origin in the logs, not in service config: Biometrics/Operational 1600 one second later means the fingerprint driver (Synaptics "SynaHlp"); Kernel-PnP 219 means a UMDF driver; vendor logs otherwise. Strings searches of the driver DLLs may find nothing because the name is built at runtime.

Remediations, in order of preference:

1. Registered, binary missing: orphan from an uninstalled driver. Delete (admin): `sc.exe delete <ServiceName>`
2. Registered, binary exists, never connects (Intel TPM Provisioning, vendor updaters): set to Manual (admin): `sc.exe config "<ServiceName>" start= demand`. Intel TPM Provisioning is already Manual on most machines and still logs 7009 at every cold boot. It is benign; leave it unless the user asks.
3. Not registered, traced to a device driver: prefer a newer driver from the OEM tool (Lenovo System Update at `C:\Program Files (x86)\Lenovo\System Update\tvsu.exe`, Dell Command Update, HP Support Assistant). Windows Update rarely carries these.
4. Not registered, device feature unused (fingerprint with EnrolledFactors 0 and a 1 KB database): disable the device (admin, reversible in Device Manager):
   ```powershell
   pnputil /disable-device '<InstanceId>'
   ```
   Verify with `Get-PnpDevice -InstanceId '<InstanceId>'` showing `CM_PROB_DISABLED`.

## EVENT LOG: 7026 boot-start drivers that failed to load

7026 lists kernel drivers with Start 0 or 1 that did not load. They are almost always leftovers from an uninstalled tuning or monitoring tool (Intel Extreme Tuning Utility leaves `uiomap` bound to ACPI device INT3394). The script maps each to its driver-store package (`oemNN.inf`) and the device still bound to it.

Confirm the parent application is gone (Installed Programs, `Get-Package`) before removing. Remediation (admin), all reversible with a driver reinstall:

```powershell
pnputil /remove-device '<DeviceInstanceId>'          # detaches the driver from the device
pnputil /delete-driver oemNN.inf /uninstall          # removes the package from the store (/force is ignored with /uninstall)
sc.exe delete <driverServiceName>                    # only if the Services key survives step 2
```

Then say: a reboot is needed; the ACPI node may reappear as an unknown device and can be disabled with `pnputil /disable-device` so Windows Update does not re-offer the driver; the DriverStore folder may still hold files for a while and is inert once the package is unpublished.

## EVENT LOG: boot type and boot timeline

- Kernel-Boot 27: `0x0` cold boot, `0x1` fast startup, `0x2` resume from hibernate. "Fast startup on" in settings is meaningless if every recorded boot is `0x0`; a Restart is always a cold boot, only Shut down uses fast startup. Judge boot complaints against cold boots only.
- The Diagnostics-Performance log (Id 100) is frequently empty even when elevated. Use the milestone list instead: Kernel-General 12 (kernel start) to Shell-Core 62170 (logon tasks begin) is the OS boot; the last Shell-Core 9708 is when the final Run-key app launched. On a healthy NVMe laptop these are about 18 s and 70 s.
- Group Policy 1502 at T+80 s on a non-domain machine is the local policy object being processed and is normal.
- Milestones are measured from kernel start, so "user logon tasks begin" and "last startup app launched" include however long the machine sat at the lock screen. The script prints Winlogon 7001 (user signed in) and the sign-in-to-last-app span; judge startup cost on that span (healthy under 60 s), not on the raw T+. A logon at T+600 s with no Kernel-Power 42/107 in between is a user who walked away, not a slow boot.
- The 9707/9708 list shows what each startup entry cost. Edge's `setup.exe --msedge --delete-old-versions` running 8 s at logon is the Edge updater cleaning up after an update, transient.

## PROCESSES and STARTUP: permanent background load

Scale everything against the core count. Four cores at 1.5 GHz cannot hide what eight cores at 4 GHz can. Use the Private_MB column to rank memory; WorkingSet double-counts shared DLL pages (93 svchost instances at 1.7 GB working set are normal on a 32 GB machine).

- Electron apps run 4 to 8 processes each and wake the CPU constantly. Discord, Slack, Teams, chat apps, AI desktop clients. Disable at login: Settings > Apps > Startup.
- WebView2 hosts grouped by parent: hosted by `SearchHost` is the Start menu web pane, by a cloud sync client its UI, by `MicrosoftWindows.Client.CBS` the Widgets board. Hide the Widgets button on the taskbar to unload that one.
- Two cloud sync clients at once (OneDrive plus Google Drive or Dropbox) double the Explorer hooks and the file-watcher load. Keep one running.
- VPN "threat protection" or web-filter services (`nordsec-threatprotection-service`) run even when the VPN is disconnected and add latency to every connection. Disable in the VPN app if unused.
- RGB, mouse, audio and printer vendor helpers (iCUE, Logitech, Razer, Realtek tasks) belong on desktops, rarely on laptops.
- OEM helper crashing repeatedly (Lenovo `UDClientService` faulting in ucrtbase) means run the OEM update tool; do not disable it.

Startup approval state: 02 is enabled, 03 is disabled. An entry in StartupApproved with no matching Run key, process, service or uninstall record is a stale ghost. Remove the value from the StartupApproved key (admin for HKLM) and it disappears from Task Manager.

Store apps do not appear in Installed Programs. Remove with:

```powershell
Get-AppxPackage <Name> | Remove-AppxPackage
Get-AppxProvisionedPackage -Online | Where-Object DisplayName -eq '<Name>' | Remove-AppxProvisionedPackage -Online   # admin
```

Phone Link is `Microsoft.YourPhone`. Also turn off Settings > Bluetooth and devices > Mobile devices.

## PROCESSES: hypervisor and VBS

`VBS status 2` with service `2` means Memory Integrity (HVCI) is on; `5` is kernel-mode hardware-enforced stack protection and is free on 11th-gen Intel and newer. `HypervisorPresent True` means Hyper-V is active for WSL, Docker or sandboxed apps. Together they cost a few percent CPU and raise kernel time; more on pre-2020 CPUs without MBEC. Only recommend turning Memory Integrity off after every other fix, and say it is a security trade-off: Windows Security > Device security > Core isolation.

## HARDWARE: what cannot be fixed

- One populated DIMM on a board whose `MemoryDevices` is 1 is single-channel forever (common on budget 15-inch business laptops). It halves memory bandwidth for the integrated GPU, which draws the desktop, and explains DWM sluggishness with transparency on and two monitors attached. Say so once and move on.
- Core count and TDP class are fixed. A 15 W four-core part will always feel slower under a heavy background load than the same apps on a desktop.
- Battery health below 70% of design with the machine on battery makes firmware clamp harder. Above 80% is fine.

## STORAGE and DISK HYGIENE

- `Avg. Disk sec/Read` or `sec/Write` above 0.020 on an SSD, or `Avg. Disk Queue Length` above 2, means the disk is a bottleneck. Below that, disk is not the problem.
- The cold-cache read test is only valid within about 10 minutes of a cold boot; after that it measures RAM. A 220 MB system file at 480 MB/s and a 500 MB file at 1400 MB/s on the same NVMe is normal variance from file fragmentation and queue depth 1.
- If a write test is wanted, do it manually with `[IO.FileOptions]::WriteThrough` on a 1 GB file in the scratchpad; 250 MB/s write-through on a laptop NVMe is a lower bound, not a fault. Delete the test file with `[IO.File]::Delete()`; a `Remove-Item` inside a command that also mentions a drive root can be blocked by the harness.
- HealthStatus not Healthy, or SMART wear above 90%, is a replace-soon signal. SMART counters need elevation; CrystalDiskInfo, if installed, shows them without a script.
- Free space under 10% on the system volume slows writes and updates. Under 15% on a data drive triggers the folder breakdown in the script; it is a housekeeping note, not a system-speed cause.
- `Pages/sec` above 100 sustained with low Available MBytes means real memory pressure. Otherwise ignore the pagefile.
- Temp folders above a few GB are worth clearing; a few hundred MB is normal. Recycle Bin at several GB and a 12 GB hiberfil are cosmetic unless C: is tight.
- Volsnap 36 with System Restore off (`RPSessionInterval` 0) means some other tool takes shadow copies that hit their quota. Not a disk fault.

## SECURITY SOFTWARE

- Windows Defender resident at 300 to 500 MB is normal. Do not recommend disabling it. "Full scan never" is fine; quick scans cover it.
- A second AV alongside Defender is a real slowdown. Remove one.
- `ScanAvgCPULoadFactor` 50 is the default; lowering it only affects scheduled scans.

## UI SETTINGS

Transparency on, VisualFXSetting "best appearance" or "let Windows choose", and animations on are cheap to turn off and matter most when the CPU is clamped or the iGPU is bandwidth-starved. Settings > Accessibility > Visual effects. Small win, list it last among the fixes.

## DRIVERS AND DEVICES

- `CM_PROB_DISABLED` is a deliberate choice, list it as fine. Any other non-OK status is a device with no working driver.
- Pending Windows Update driver offers dated 2017 or 2018 for Intel chipset or HP USB are benign catalog entries. Not a slowness cause.
- Old INF-only chipset drivers (Intel LPC, PCI root ports from 2019) are normal and never updated. Do not list them as a problem.
- Biometric: EnrolledFactors 0 or absent plus a 1 KB WinBioDatabase file means nobody uses the sensor. That makes disabling it an acceptable fix for a misbehaving fingerprint driver.

## EVENT LOG traps

- DistributedCOM 10005 or 10010 during shutdown are noise.
- WindowsUpdateClient 20 for Store apps (`9N...` ids) is a Store app that failed to update, not a system update.
- Volsnap 36 (shadow storage limit) is a quota, not a disk fault.
- Wi-Fi Direct Virtual Adapter power transition errors (NDIS 10317) are cosmetic unless Wi-Fi itself drops.
- Netwtw10 7023 "secure boot debug logging Quasar" is Intel Wi-Fi driver chatter at every boot.
- Kernel-PnP 219 "WUDFRd failed to load" in the first 10 s of boot for Intel PCI DEV_9A03 (Platform Monitoring) or a DetectionVerification device is the UMDF host not being up yet; the driver loads on retry.
- DeviceAssociationService 3502 unpairing failures are Bluetooth housekeeping.
- Service Control Manager 7023 "Phone Service terminated: a system shutdown is in progress" is shutdown ordering, not a fault.
- Intel TPM Provisioning Service 7009 at every cold boot is benign (see the 7009 section).

## Transient vs permanent

Anything at the top of the CPU or disk list during the sample that is an updater (`officeclicktorun`, `mousocoreworker`, `msiexec`, Edge `setup.exe`), the indexer after a reboot (`searchindexer`, `searchprotocolhost`), or Defender mid-scan (`msmpeng` at high disk) is transient. Report it as "happening right now" and do not recommend disabling it.

## Running something elevated when the user asks for a fix

The Claude Code shell is not elevated even when the user is an administrator (whoami shows the Administrators group "used for deny only"). Do not try to elevate the session. Write the commands to a script in the scratchpad, run it with a UAC prompt, and read the output file:

```powershell
$sp = '<scratchpad>'
Set-Content "$sp\fix.ps1" @'
& { <commands> } *>&1 | Out-File "$PSScriptRoot\fix.txt" -Encoding utf8
'@
Start-Process pwsh -Verb RunAs -Wait -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass','-File',"$sp\fix.ps1"
Get-Content "$sp\fix.txt"
```

One UAC prompt per script, so batch the inspection and the change into as few scripts as possible, but keep the read-only inspection separate from the change so the target is seen before it is touched. Print a BEFORE and AFTER state in the fix script. Tell the user a prompt is coming.

## Report template

1. Verdict: slow or not, with the healthy-range table from the top of this file.
2. The dominant cause, one paragraph, with the proving test.
3. Boot delays, if any real ones exist, with the exact `sc.exe` or `pnputil` lines. Label noise-only 7009s as noise in one line.
4. Background load, bulleted by app with process count and MB, then the disable path.
5. Smaller contributors, including what cannot be fixed.
6. What is fine and what could not be checked without elevation.
7. Recommended order of fixes, numbered, security trade-offs last.
8. State that no changes were made and offer to apply the safe ones.
