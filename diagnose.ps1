# Windows 11 slowness diagnostic. Read-only: makes no changes to the system.
# Run with:  pwsh -NoProfile -File diagnose.ps1 [-CheckUpdates]
# Elevation is optional; sections that need it say so and are skipped when unavailable.
# -CheckUpdates adds a Windows Update pending-search (COM, adds ~30 s).
param([switch]$CheckUpdates)

$ErrorActionPreference = 'SilentlyContinue'
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole('Administrators')

function Section($title) { ''; "==== $title ===="; }
function Try-Run($title, [scriptblock]$body) {
	Section $title
	try { & $body } catch { "  [error] $($_.Exception.Message)" }
}
function Trunc($s, $n) { $s = ([string]$s -replace '\s+', ' ').Trim(); if ($s.Length -gt $n) { $s.Substring(0, $n) } else { $s } }

$bootTime = (Get-CimInstance Win32_OperatingSystem).LastBootUpTime
"Windows 11 slowness diagnostic  |  $(Get-Date -Format 'yyyy-MM-dd HH:mm')  |  elevated: $isAdmin  |  uptime: {0:N1} min" -f ((Get-Date) - $bootTime).TotalMinutes

Try-Run 'HARDWARE' {
	$os  = Get-CimInstance Win32_OperatingSystem
	$cs  = Get-CimInstance Win32_ComputerSystem
	$cpu = Get-CimInstance Win32_Processor
	$bios = Get-ItemProperty 'HKLM:\HARDWARE\DESCRIPTION\System\BIOS'
	"Model:    $($cs.Manufacturer) $($cs.Model)  ($($bios.SystemFamily))"
	"BIOS:     $($bios.BIOSVersion)  released $($bios.BIOSReleaseDate)"
	"OS:       $($os.Caption) $($os.Version) $($os.OSArchitecture)  installed $($os.InstallDate.ToString('yyyy-MM-dd'))"
	"CPU:      $($cpu.Name)  cores=$($cpu.NumberOfCores) threads=$($cpu.NumberOfLogicalProcessors) baseMHz=$($cpu.MaxClockSpeed)"
	"RAM:      {0:N1} GB total, {1:N1} GB free" -f ($cs.TotalPhysicalMemory/1GB), ($os.FreePhysicalMemory/1MB)
	$dimms = Get-CimInstance Win32_PhysicalMemory
	$slots = (Get-CimInstance Win32_PhysicalMemoryArray).MemoryDevices
	"DIMMs:    $($dimms.Count) populated of $slots slot(s)  -> " + $(if ($dimms.Count -ge 2) { 'likely dual-channel' } elseif ($slots -le 1) { 'SINGLE-CHANNEL, board has one slot: not fixable' } else { 'SINGLE-CHANNEL (a second module would fix it)' })
	$dimms | ForEach-Object { "          {0} {1} GB @ {2} MHz  {3}" -f $_.Manufacturer, ($_.Capacity/1GB), $_.ConfiguredClockSpeed, $_.DeviceLocator }
	"Uptime:   {0:N1} days (booted $($os.LastBootUpTime))" -f ((Get-Date) - $os.LastBootUpTime).TotalDays
	Get-CimInstance Win32_VideoController | ForEach-Object { "GPU:      $($_.Name)  driver $($_.DriverVersion) ($($_.DriverDate.ToString('yyyy-MM-dd')))  $($_.CurrentHorizontalResolution)x$($_.CurrentVerticalResolution)@$($_.CurrentRefreshRate)" }
	"Monitors: $((Get-CimInstance -Namespace root\wmi WmiMonitorBasicDisplayParams | Measure-Object).Count)"
	$rel = Get-CimInstance Win32_ReliabilityStabilityMetrics | Select-Object -First 1
	if ($rel) { "Reliability index: {0:N2} / 10 (Reliability Monitor, latest)" -f $rel.SystemStabilityIndex }
	$ws = Get-CimInstance Win32_WinSAT
	if ($ws.WinSATAssessmentState -eq 1) { "WinSAT:   cpu=$($ws.CPUScore) mem=$($ws.MemoryScore) disk=$($ws.DiskScore) gfx=$($ws.GraphicsScore) d3d=$($ws.D3DScore) (max 9.9)" }
}

Try-Run 'STORAGE' {
	Get-PhysicalDisk | Select-Object FriendlyName, MediaType, BusType, @{n='SizeGB';e={[math]::Round($_.Size/1GB)}}, HealthStatus, FirmwareVersion | Format-Table -AutoSize | Out-String -Width 200
	Get-Volume | Where-Object DriveLetter | Select-Object DriveLetter, FileSystemLabel, FileSystem, HealthStatus, @{n='SizeGB';e={[math]::Round($_.Size/1GB)}}, @{n='FreeGB';e={[math]::Round($_.SizeRemaining/1GB)}}, @{n='Free%';e={[math]::Round(100*$_.SizeRemaining/$_.Size)}} | Format-Table -AutoSize | Out-String -Width 200
	(fsutil behavior query DisableDeleteNotify | Select-String 'NTFS').Line
	$defrag = Get-ScheduledTaskInfo -TaskPath '\Microsoft\Windows\Defrag\' -TaskName ScheduledDefrag
	if ($defrag) { "Scheduled optimize: last run $($defrag.LastRunTime) result=$($defrag.LastTaskResult)" }
	Get-ChildItem C:\ -Force | Where-Object { $_.Name -match '^(hiberfil|pagefile|swapfile)\.sys$' } | ForEach-Object { "  {0,-14} {1,6:N1} GB" -f $_.Name, ($_.Length/1GB) }
	if ($isAdmin) { Get-PhysicalDisk | Get-StorageReliabilityCounter | Select-Object DeviceId, Temperature, Wear, ReadErrorsTotal, WriteErrorsTotal, PowerOnHours | Format-Table -AutoSize | Out-String } else { '  (SMART/wear counters need elevation; CrystalDiskInfo shows the same data if installed)' }
	if ($isAdmin) { Get-BitLockerVolume | ForEach-Object { "BitLocker $($_.MountPoint): $($_.VolumeStatus) $($_.EncryptionMethod)" } } else { '  (BitLocker status needs elevation)' }
	'-- cold-cache sequential read (read-only; only meaningful within ~10 min of a cold boot, otherwise it measures RAM cache) --'
	$targets = @("$env:WINDIR\System32\MRT.exe")
	$big = Get-ChildItem "$env:ProgramFiles" -Recurse -File -Depth 4 | Where-Object Length -gt 200MB | Sort-Object Length -Descending | Select-Object -First 1
	if ($big) { $targets += $big.FullName }
	foreach ($t in $targets) {
		if (-not (Test-Path -LiteralPath $t)) { continue }
		$buf = New-Object byte[] (4MB); $fs = [IO.File]::Open($t, 'Open', 'Read', 'ReadWrite'); $sw = [Diagnostics.Stopwatch]::StartNew(); $tot = 0L
		while (($n = $fs.Read($buf, 0, $buf.Length)) -gt 0) { $tot += $n }
		$sw.Stop(); $fs.Close()
		"  {0,-70} {1,6:N0} MB  {2,6:N0} MB/s" -f (Trunc $t 70), ($tot/1MB), ($tot/1MB/$sw.Elapsed.TotalSeconds)
	}
}

Try-Run 'POWER' {
	$ac = (Get-CimInstance BatteryStatus -Namespace root\wmi).PowerOnline
	$bat = Get-CimInstance Win32_Battery
	"Power source: " + $(if ($null -eq $ac) { 'AC (no battery)' } elseif ($ac) { 'AC' } else { 'BATTERY' }) + $(if ($bat) { "  charge=$($bat.EstimatedChargeRemaining)%" })
	(powercfg /getactivescheme) -replace 'Power Scheme GUID: ', 'Scheme: '
	$ov = Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Power\User\PowerSchemes'
	$map = @{ 'ded574b5-45a0-4f42-8737-46345c09c238'='Best performance'; '3af9b8d9-7c97-431d-ad78-34a8bfea439f'='Balanced (better perf)'; '961cc777-2547-4f9d-8174-7d86181b8a7a'='Best power efficiency' }
	foreach ($side in 'Ac','Dc') { $g = $ov."ActiveOverlay${side}PowerScheme"; "Power mode slider ($side): " + $(if ($g -and $map[$g]) { $map[$g] } elseif ($g -and $g -ne '00000000-0000-0000-0000-000000000000') { $g } else { 'Balanced (default)' }) }
	foreach ($s in 'PROCTHROTTLEMAX','PROCTHROTTLEMIN') {
		$o = powercfg /q SCHEME_CURRENT SUB_PROCESSOR $s
		$acv = [regex]::Match(($o -join ' '), 'AC Power Setting Index: (0x[0-9a-fA-F]+)').Groups[1].Value
		$dcv = [regex]::Match(($o -join ' '), 'DC Power Setting Index: (0x[0-9a-fA-F]+)').Groups[1].Value
		"{0,-16} AC={1}%  DC={2}%" -f $s, $(if ($acv) { [int]$acv } else { '?' }), $(if ($dcv) { [int]$dcv } else { '?' })
	}
	# PERFBOOSTMODE is a hidden setting: powercfg /q prints nothing for it. Read the scheme's registry override; absent means the default (2 = Aggressive, turbo on).
	$scheme = [regex]::Match((powercfg /getactivescheme), '[0-9a-f-]{36}').Value
	$boost = Get-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Control\Power\User\PowerSchemes\$scheme\54533251-82be-4824-96c1-47b60b740d00\be337238-0d82-4146-a960-4f3749d470c7"
	"PERFBOOSTMODE    " + $(if ($boost) { "AC=$($boost.ACSettingIndex) DC=$($boost.DCSettingIndex)  (0 = turbo DISABLED)" } else { 'not overridden (default: turbo on)' })
	"Fast startup setting: " + $(if ((Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power').HiberbootEnabled -eq 1) { 'on' } else { 'off' }) + '  (see EVENT LOG boot types for whether it is actually used)'
	if ($bat) {
		$rep = Join-Path $env:TEMP "battreport_$PID.xml"
		powercfg /batteryreport /xml /output $rep | Out-Null
		if (Test-Path $rep) {
			$b = ([xml](Get-Content $rep)).BatteryReport.Batteries.Battery
			"Battery health: {0:N0}% of design ({1} / {2} mWh), {3} cycles" -f (100*[int]$b.FullChargeCapacity/[int]$b.DesignCapacity), $b.FullChargeCapacity, $b.DesignCapacity, $b.CycleCount
			[IO.File]::Delete($rep)
		}
	}
	$pnp = Get-PnpDevice -PresentOnly | Where-Object { $_.FriendlyName -match 'Dynamic Tuning Manager|Intelligent Thermal|AMD Ryzen Power|Thermal Framework' }
	if ($pnp) { "OEM/Intel power-limit drivers present: " + (($pnp.FriendlyName | Sort-Object -Unique) -join '; ') }
	if ($isAdmin) { Get-CimInstance -Namespace root/wmi MSAcpi_ThermalZoneTemperature | ForEach-Object { "Thermal zone: {0:N0} C" -f ($_.CurrentTemperature/10 - 273.15) } } else { '  (thermal zone temperatures need elevation)' }
}

Try-Run 'LIVE LOAD (10 s sample)' {
	$n = (Get-CimInstance Win32_ComputerSystem).NumberOfLogicalProcessors
	$paths = '\Processor(_Total)\% Processor Time','\Processor(_Total)\% Privileged Time','\Processor(_Total)\% Interrupt Time','\Processor(_Total)\% DPC Time',
			 '\Processor Information(_Total)\% of Maximum Frequency','\Processor Information(_Total)\Processor Frequency','\Processor Information(_Total)\% Processor Performance','\Processor Information(_Total)\% Processor Utility',
			 '\System\Processor Queue Length','\System\Context Switches/sec',
			 '\Memory\Available MBytes','\Memory\Pages/sec','\Memory\% Committed Bytes In Use','\Memory\Pool Nonpaged Bytes',
			 '\PhysicalDisk(_Total)\% Idle Time','\PhysicalDisk(_Total)\Avg. Disk Queue Length','\PhysicalDisk(_Total)\Avg. Disk sec/Read','\PhysicalDisk(_Total)\Avg. Disk sec/Write',
			 '\Process(*)\% Processor Time','\Process(*)\IO Data Bytes/sec'
	# Process(*) counters throw "data is not valid" when a process exits mid-sample; SilentlyContinue keeps the good samples.
	$c = Get-Counter -Counter $paths -SampleInterval 1 -MaxSamples 10 -ErrorAction SilentlyContinue
	$all = $c.CounterSamples | Where-Object Status -eq 0
	$sys = $all | Where-Object { $_.Path -notmatch '\\process\(' } | Group-Object Path | ForEach-Object {
		[pscustomobject]@{ Counter = ($_.Name -replace '^\\\\[^\\]+', ''); Min = [math]::Round(($_.Group.CookedValue | Measure-Object -Minimum).Minimum, 2); Avg = [math]::Round(($_.Group.CookedValue | Measure-Object -Average).Average, 2); Max = [math]::Round(($_.Group.CookedValue | Measure-Object -Maximum).Maximum, 2) } }
	$sys | Format-Table -AutoSize | Out-String -Width 200
	'-- top CPU consumers (% of whole machine; this script itself is pwsh) --'
	$all | Where-Object { $_.Path -match '\\process\(' -and $_.Path -match '% processor time' -and $_.InstanceName -notin '_total','idle' } | Group-Object InstanceName | ForEach-Object {
		[pscustomobject]@{ Process = $_.Name; CPUpct = [math]::Round(($_.Group.CookedValue | Measure-Object -Average).Average / $n, 1) } } | Sort-Object CPUpct -Descending | Select-Object -First 10 | Format-Table -AutoSize | Out-String
	'-- top disk I/O consumers --'
	$all | Where-Object { $_.Path -match 'io data bytes' -and $_.InstanceName -notin '_total','idle' } | Group-Object InstanceName | ForEach-Object {
		[pscustomobject]@{ Process = $_.Name; MBps = [math]::Round(($_.Group.CookedValue | Measure-Object -Average).Average / 1MB, 2) } } | Sort-Object MBps -Descending | Select-Object -First 8 | Format-Table -AutoSize | Out-String
	$g = (Get-Counter '\GPU Engine(*engtype_3D)\Utilization Percentage' -ErrorAction SilentlyContinue).CounterSamples
	"GPU 3D engine total: {0:N1}%" -f (($g.CookedValue | Measure-Object -Sum).Sum)
	$os = Get-CimInstance Win32_OperatingSystem
	"Commit: {0:N1} / {1:N1} GB" -f (($os.TotalVirtualMemorySize - $os.FreeVirtualMemory)/1MB), ($os.TotalVirtualMemorySize/1MB)
	Get-CimInstance Win32_PageFileUsage | ForEach-Object { "Pagefile: $($_.Name) allocated=$($_.AllocatedBaseSize)MB used=$($_.CurrentUsage)MB peak=$($_.PeakUsage)MB" }
	$p = Get-Process
	"Processes: $($p.Count)  Threads: $(($p.Threads.Count | Measure-Object -Sum).Sum)  Handles: $(($p.Handles | Measure-Object -Sum).Sum)"
}

Try-Run 'PROCESSES' {
	$procs = Get-Process
	"Process count: $($procs.Count)   Running services: $((Get-Service | Where-Object Status -eq Running).Count)"
	'-- memory by process name (grouped; Private is the honest number, WorkingSet double-counts shared pages) --'
	$procs | Group-Object Name | ForEach-Object { [pscustomobject]@{ Name = $_.Name; Count = $_.Count; WS_MB = [math]::Round(($_.Group | Measure-Object WorkingSet64 -Sum).Sum/1MB); Private_MB = [math]::Round(($_.Group | Measure-Object PrivateMemorySize64 -Sum).Sum/1MB) } } | Sort-Object Private_MB -Descending | Select-Object -First 20 | Format-Table -AutoSize | Out-String
	'-- Electron / Chromium-style apps (many processes each) --'
	$procs | Where-Object { $_.Path -and (Test-Path -LiteralPath (Join-Path (Split-Path $_.Path) 'resources\app.asar')) } | Group-Object Name | ForEach-Object { [pscustomobject]@{ App = $_.Name; Procs = $_.Count; MB = [math]::Round(($_.Group | Measure-Object WorkingSet64 -Sum).Sum/1MB); Path = Split-Path $_.Group[0].Path } } | Sort-Object MB -Descending | Format-Table -AutoSize | Out-String -Width 200
	'-- WebView2 hosts (by parent process) --'
	Get-CimInstance Win32_Process -Filter "Name='msedgewebview2.exe'" | Group-Object ParentProcessId | ForEach-Object { $pp = Get-Process -Id $_.Name; "  x{0,-3} hosted by {1}" -f $_.Count, $(if ($pp.Name -eq 'msedgewebview2') { 'msedgewebview2 (nested; check --user-data-dir)' } elseif ($pp) { $pp.Name } else { 'exited parent' }) }
	'-- VM / hypervisor --'
	$dg = Get-CimInstance -ClassName Win32_DeviceGuard -Namespace root\Microsoft\Windows\DeviceGuard
	"VBS status: $($dg.VirtualizationBasedSecurityStatus) (2=running)   services running: $($dg.SecurityServicesRunning -join ',') (1=CredGuard 2=HVCI/MemoryIntegrity 3=SecureLaunch 4=SMM 5=KernelShadowStacks)   HypervisorPresent: $((Get-CimInstance Win32_ComputerSystem).HypervisorPresent)"
	Get-Process vmmem*, vmwp, vmcompute, wslservice | ForEach-Object { "  $($_.Name) pid=$($_.Id) $([math]::Round($_.WorkingSet64/1MB)) MB" }
	# wsl.exe writes UTF-16LE; without this the captured text is interleaved with NULs.
	$prevEnc = [Console]::OutputEncoding; [Console]::OutputEncoding = [Text.Encoding]::Unicode
	$wsl = wsl --list --running 2>$null | Where-Object { $_.Trim() -and $_ -notmatch 'no running|Windows Subsystem' }
	[Console]::OutputEncoding = $prevEnc
	"WSL distros running: " + $(if ($wsl) { ($wsl | ForEach-Object { $_.Trim() }) -join ', ' } else { 'none' })
}

Try-Run 'STARTUP' {
	'-- Run keys / Startup folders --'
	Get-CimInstance Win32_StartupCommand | Select-Object Name, @{n='Where';e={ $_.Location -replace 'HKU\\S-1-5-21[^\\]+', 'HKCU' -replace 'SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\', '' }}, @{n='Cmd';e={ Trunc ($_.Command -replace '"','') 80 }} | Format-Table -AutoSize | Out-String -Width 220
	'-- Task Manager approval state (02=enabled 03=disabled; entries without a matching Run key are stale) --'
	foreach ($k in 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run','HKLM:\Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run','HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\StartupFolder') {
		$p = Get-ItemProperty $k; $p.PSObject.Properties | Where-Object { $_.Name -notlike 'PS*' } | ForEach-Object { "  {0,-50} {1}" -f $_.Name, ('{0:X2}' -f $_.Value[0]) }
	}
	'-- Startup app launch timeline this boot (Shell-Core 9707 start / 9708 finish; the gap is what each Run entry cost) --'
	$sc = Get-WinEvent -FilterHashtable @{ LogName='Microsoft-Windows-Shell-Core/Operational'; Id=9707,9708; StartTime=$bootTime } | Sort-Object TimeCreated
	if ($sc) {
		$sc | ForEach-Object { "  T+{0,4}s  {1}  {2}" -f [int]($_.TimeCreated - $bootTime).TotalSeconds, $(if ($_.Id -eq 9707) { 'start ' } else { 'finish' }), (Trunc (($_.Message -replace '.*command ', '') -replace '[''"]', '' -replace '\.$', '') 90) }
	} else { '  (no Shell-Core startup events this boot)' }
	'-- Non-Microsoft running services --'
	Get-CimInstance Win32_Service | Where-Object { $_.State -eq 'Running' -and $_.PathName -notmatch 'Windows\\(system32|SysWOW64|servicing)' -and $_.PathName } | Select-Object Name, StartMode, @{n='Path';e={ (($_.PathName -replace '"','') -split '\s+[-/]')[0] }} | Sort-Object Path | Format-Table -AutoSize | Out-String -Width 220
	'-- Auto-start services that are NOT running (delayed-start ones that exit when idle are normal; a missing binary is an orphan) --'
	Get-CimInstance Win32_Service | Where-Object { $_.StartMode -eq 'Auto' -and $_.State -ne 'Running' -and $_.PathName -notmatch 'svchost' } | ForEach-Object {
		$exe = (($_.PathName -replace '"','') -split '\s+[-/]')[0].Trim()
		"  {0,-45} state={1,-8} delayed={2,-5} exit={3,-5} binary exists: {4}" -f $_.Name, $_.State, $_.DelayedAutoStart, $_.ExitCode, (Test-Path -LiteralPath $exe)
	}
	'-- Third-party scheduled tasks (ready/running) --'
	Get-ScheduledTask | Where-Object { $_.State -in 'Ready','Running' -and $_.TaskPath -notlike '\Microsoft\*' } | Select-Object TaskPath, TaskName | Format-Table -AutoSize | Out-String -Width 200
	'-- Third-party Explorer shell extensions (slow right-click / folder browsing) --'
	$paths = 'HKLM:\SOFTWARE\Classes\*\shellex\ContextMenuHandlers','HKLM:\SOFTWARE\Classes\Directory\shellex\ContextMenuHandlers','HKLM:\SOFTWARE\Classes\Directory\Background\shellex\ContextMenuHandlers','HKLM:\SOFTWARE\Classes\Folder\shellex\ContextMenuHandlers','HKLM:\SOFTWARE\Classes\AllFilesystemObjects\shellex\ContextMenuHandlers'
	$out = foreach ($p in $paths) { Get-ChildItem -LiteralPath $p | ForEach-Object {
		$clsid = (Get-ItemProperty -LiteralPath $_.PSPath).'(default)'; if (-not $clsid) { $clsid = $_.PSChildName }
		$dll = (Get-ItemProperty -LiteralPath "HKLM:\SOFTWARE\Classes\CLSID\$clsid\InprocServer32").'(default)'
		if ($dll -and $dll -notmatch 'Windows\\(System32|SysWOW64)') { "  {0,-35} {1}" -f $_.PSChildName, $dll } } }
	$out | Sort-Object -Unique
}

Try-Run 'DRIVERS AND DEVICES' {
	'-- devices not OK (CM_PROB_DISABLED is deliberate; anything else needs a driver) --'
	$bad = Get-PnpDevice | Where-Object { $_.Status -ne 'OK' -and $_.Present }
	if ($bad) { $bad | Select-Object Status, Class, FriendlyName, Problem, InstanceId | Format-Table -AutoSize | Out-String -Width 200 } else { '  none' }
	'-- biometric sensors and whether anyone is enrolled (unenrolled sensors can be disabled if their driver misbehaves at boot) --'
	Get-PnpDevice -Class Biometric | ForEach-Object { "  $($_.Status)  $($_.FriendlyName)  $($_.InstanceId)  driver $((Get-PnpDeviceProperty -InstanceId $_.InstanceId -KeyName DEVPKEY_Device_DriverVersion).Data) ($((Get-PnpDeviceProperty -InstanceId $_.InstanceId -KeyName DEVPKEY_Device_DriverDate).Data.ToString('yyyy-MM-dd')))" }
	$enr = Get-ChildItem 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WinBio\AccountInfo' | ForEach-Object { "$($_.PSChildName -replace 'S-1-5-21-.*-(\d+)$','user-$1')=$((Get-ItemProperty $_.PSPath).EnrolledFactors)" }
	"  Windows Hello EnrolledFactors: " + $(if ($enr) { $enr -join ', ' } else { 'none recorded' }) + '  (0 or absent = nothing enrolled; 8 = fingerprint, 2 = face)'
	Get-ChildItem "$env:WINDIR\System32\WinBioDatabase" | ForEach-Object { "  db {0}  {1,7:N0} bytes  (about 1 KB = empty)" -f $_.Name, $_.Length }
	'-- OEM update tools present (drivers come from these, not Windows Update) --'
	Get-ChildItem "${env:ProgramFiles(x86)}\Lenovo\System Update\tvsu.exe", "$env:ProgramFiles\Lenovo\Vantage*", "$env:ProgramFiles\Dell\*Update*", "$env:ProgramFiles\HP\*Assistant*" | ForEach-Object { "  $($_.FullName)" }
}

Try-Run 'SECURITY SOFTWARE' {
	Get-CimInstance -Namespace root/SecurityCenter2 -ClassName AntiVirusProduct | ForEach-Object { "AV: $($_.displayName)" }
	$mp = Get-MpComputerStatus
	if ($mp) { "Defender: mode=$($mp.AMRunningMode) realtime=$($mp.RealTimeProtectionEnabled) quickScanAge=$($mp.QuickScanAge)d fullScanAge=$(if ($mp.FullScanAge -gt 10000) {'never'} else {"$($mp.FullScanAge)d"})" }
	$pref = Get-MpPreference
	if ($pref) { "Defender prefs: ScanAvgCPULoadFactor=$($pref.ScanAvgCPULoadFactor)% ControlledFolderAccess=$($pref.EnableControlledFolderAccess) exclusions=$(($pref.ExclusionPath | Measure-Object).Count)" }
	Get-Process | Where-Object { $_.Company -match 'Nord|Norton|McAfee|Avast|AVG|Kaspersky|Bitdefender|ESET|Malwarebytes|CrowdStrike|SentinelOne|Sophos' } | Group-Object Company | ForEach-Object { "3rd-party security/VPN processes: $($_.Name) x$($_.Count)" }
	Get-CimInstance Win32_Service | Where-Object { $_.State -eq 'Running' -and $_.Name -match 'threatprotection|webfilter|nordsec' } | ForEach-Object { "VPN filter service running: $($_.Name) (filters traffic even with VPN disconnected)" }
	Get-NetAdapter | Where-Object Status -eq Up | ForEach-Object { "Network up: $($_.Name) ($($_.InterfaceDescription)) $($_.LinkSpeed)" }
	$dns = Measure-Command { Resolve-DnsName microsoft.com | Out-Null }; "DNS resolve: {0:N0} ms" -f $dns.TotalMilliseconds
	$ping = Test-Connection 1.1.1.1 -Count 3 | Measure-Object Latency -Average; if ($ping.Count) { "Ping 1.1.1.1: {0:N0} ms avg" -f $ping.Average }
}

Try-Run 'UI SETTINGS' {
	"Transparency: " + $(if ((Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize').EnableTransparency -eq 1) { 'on' } else { 'off' })
	$vfx = (Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\VisualEffects').VisualFXSetting
	"VisualFXSetting: " + $(switch ($vfx) { 0 {'let Windows choose'} 1 {'best appearance'} 2 {'best performance'} 3 {'custom'} default {'let Windows choose'} })
	"Window min/max animation: " + $(if ((Get-ItemProperty 'HKCU:\Control Panel\Desktop\WindowMetrics').MinAnimate -eq '1') { 'on' } else { 'off' })
	$adv = Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'
	"Taskbar animations: $($adv.TaskbarAnimations)   Widgets button: $(if ($adv.TaskbarDa -eq 0) {'hidden'} else {'shown'})"
	$ws = Get-Service WSearch; "Windows Search: $($ws.Status) ($($ws.StartType))"
	$sm = Get-Service SysMain; "SysMain (Superfetch): $($sm.Status) ($($sm.StartType))"
	"Storage Sense: " + $(if ((Get-ItemProperty 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\StorageSense\Parameters\StoragePolicy').'01' -eq 1) { 'on' } else { 'off' })
}

Try-Run 'EVENT LOG (last 7 days unless stated)' {
	$since = (Get-Date).AddDays(-7)
	'-- Boot types, last 30 days (Kernel-Boot 27: 0x0 cold boot, 0x1 fast startup, 0x2 resume from hibernate) --'
	$boots = Get-WinEvent -FilterHashtable @{ LogName='System'; ProviderName='Microsoft-Windows-Kernel-Boot'; Id=27; StartTime=(Get-Date).AddDays(-30) } | Sort-Object TimeCreated
	$boots | ForEach-Object { if ($_.Message -match 'type was (0x\d)') { $Matches[1] } else { '?' } } | Group-Object | ForEach-Object { "  $($_.Name): $($_.Count) boot(s)" }
	'-- Service Control Manager 7009 timeouts: REAL only if logged 45 s or more after the boot that preceded it; earlier means the process exited without connecting (log noise) --'
	$svcByDisplay = @{}; Get-CimInstance Win32_Service | ForEach-Object { $svcByDisplay[$_.DisplayName] = $_ }
	Get-WinEvent -FilterHashtable @{ LogName='System'; ProviderName='Service Control Manager'; Id=7009; StartTime=(Get-Date).AddDays(-30) } | ForEach-Object {
		$ev = $_
		$disp = if ($ev.Message -match 'waiting for the (.+?) service to connect') { $Matches[1] } else { '?' }
		$prevBoot = $boots | Where-Object { $_.TimeCreated -le $ev.TimeCreated } | Select-Object -Last 1
		$tplus = if ($prevBoot) { [int]($ev.TimeCreated - $prevBoot.TimeCreated).TotalSeconds } else { -1 }
		$svc = $svcByDisplay[$disp]
		[pscustomobject]@{ Display = $disp; Tplus_s = $tplus; Verdict = $(if ($tplus -ge 0 -and $tplus -lt 45) { 'noise' } elseif ($tplus -ge 45) { 'REAL WAIT' } else { '?' }); Registered = $(if ($svc) { "$($svc.Name) start=$($svc.StartMode) state=$($svc.State)" } else { 'NOT REGISTERED (spawned by a driver/helper; correlate with Biometrics 1600, Kernel-PnP, vendor logs)' }) }
	} | Group-Object Display, Verdict, Registered | ForEach-Object { "  x{0,-3} T+{1,4}s  {2,-9}  {3,-40} {4}" -f $_.Count, $_.Group[0].Tplus_s, $_.Group[0].Verdict, (Trunc $_.Group[0].Display 40), $_.Group[0].Registered }
	'-- Other Service Control Manager failures --'
	Get-WinEvent -FilterHashtable @{ LogName='System'; ProviderName='Service Control Manager'; Id=7000,7011,7022,7023,7024,7031,7034; StartTime=$since } | ForEach-Object { [pscustomobject]@{ Id=$_.Id; Msg=(Trunc $_.Message 120) } } | Group-Object Id, Msg | Sort-Object Count -Descending | Select-Object -First 10 Count, @{n='Event';e={$_.Name}} | Format-Table -AutoSize | Out-String -Width 220
	'-- Boot-start drivers that failed to load (7026): leftovers from uninstalled tools; map to the driver package with pnputil --'
	$e7026 = Get-WinEvent -FilterHashtable @{ LogName='System'; ProviderName='Service Control Manager'; Id=7026 } -MaxEvents 1
	if ($e7026 -and $e7026.TimeCreated -gt $bootTime.AddMinutes(-5)) {
		$drivers = ($e7026.Message -split "`n" | Select-Object -Skip 1 | ForEach-Object { $_.Trim() } | Where-Object { $_ })
		$infs = (pnputil /enum-drivers | Out-String) -split '(?=Published Name:)' | Where-Object { $_ -match 'Published Name' }
		foreach ($d in $drivers) {
			$k = Get-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Services\$d"
			$img = $k.ImagePath
			$exists = if ($img) { Test-Path -LiteralPath ((($img -replace '^\\SystemRoot', $env:WINDIR) -replace '^\\\?\?\\', '')) } else { 'no service key' }
			$infName = if ($img -match '\\([^\\]+\.inf)_amd64') { $Matches[1] } else { $null }
			$pub = if ($infName) { ($infs | Where-Object { $_ -match "Original Name:\s+$([regex]::Escape($infName))" } | ForEach-Object { [regex]::Match($_, 'Published Name:\s+(\S+)').Groups[1].Value }) -join ',' } else { '' }
			$owner = if ($pub) { (Get-CimInstance Win32_PnPSignedDriver | Where-Object InfName -eq $pub | Select-Object -First 1) } else { $null }
			"  {0,-14} start={1} image exists={2}  inf={3} published={4}  device={5}" -f $d, $k.Start, $exists, $(if ($infName) { $infName } else { '?' }), $(if ($pub) { $pub } else { 'not in store' }), $(if ($owner) { "$($owner.DeviceName) [$($owner.DeviceID)]" } else { 'none bound' })
		}
	} else { '  none this boot' }
	'-- System log errors/criticals grouped --'
	Get-WinEvent -FilterHashtable @{ LogName='System'; Level=1,2; StartTime=$since } | Group-Object ProviderName, Id | Sort-Object Count -Descending | Select-Object -First 12 Count, Name, @{n='Sample';e={ Trunc $_.Group[0].Message 110 }} | Format-Table -AutoSize | Out-String -Width 220
	'-- Application hangs (1002) and crashes (1000) --'
	Get-WinEvent -FilterHashtable @{ LogName='Application'; Id=1000,1002; StartTime=$since } | ForEach-Object { [pscustomobject]@{ Kind=$(if ($_.Id -eq 1002) {'hang'} else {'crash'}); App=$_.Properties[0].Value } } | Group-Object Kind, App | Sort-Object Count -Descending | Select-Object -First 10 Count, Name | Format-Table -AutoSize | Out-String
	'-- Hardware / storage / power warnings and errors, 30 days (WHEA, disk, Ntfs, volmgr, Kernel-Power 41) --'
	$hw = Get-WinEvent -FilterHashtable @{ LogName='System'; ProviderName='disk','storahci','stornvme','Ntfs','volmgr','Microsoft-Windows-WHEA-Logger','Microsoft-Windows-Kernel-Power'; Level=1,2,3; StartTime=(Get-Date).AddDays(-30) } | Group-Object ProviderName, Id
	if ($hw) { $hw | ForEach-Object { "  x$($_.Count)  $($_.Name)" } } else { '  none' }
	'-- Biometrics secure-component failures (1600): pairs with a SynaHlp-style 7009 from the fingerprint driver --'
	"  " + ((Get-WinEvent -FilterHashtable @{ LogName='Microsoft-Windows-Biometrics/Operational'; Id=1600; StartTime=(Get-Date).AddDays(-30) } | Measure-Object).Count) + " in 30 days"
	'-- Processor power capability events (Id 55 is INFORMATIONAL, logged every boot; ignore) --'
	Get-WinEvent -FilterHashtable @{ LogName='System'; ProviderName='Microsoft-Windows-Kernel-Processor-Power'; StartTime=$since } | Group-Object Id | ForEach-Object { "  Id $($_.Name): $($_.Count)" }
	'-- Resource exhaustion detector (2004, 30 days) --'
	"  " + ((Get-WinEvent -FilterHashtable @{ LogName='System'; Id=2004; ProviderName='Microsoft-Windows-Resource-Exhaustion-Detector'; StartTime=(Get-Date).AddDays(-30) } | Measure-Object).Count) + " events"
	'-- This boot: milestones from the System and Shell-Core logs (works without elevation) --'
	$kg = Get-WinEvent -FilterHashtable @{ LogName='System'; ProviderName='Microsoft-Windows-Kernel-General'; Id=12; StartTime=$bootTime.AddMinutes(-2) } | Sort-Object TimeCreated | Select-Object -First 1
	$k0 = if ($kg) { $kg.TimeCreated } else { $bootTime }
	$el = Get-WinEvent -FilterHashtable @{ LogName='System'; ProviderName='EventLog'; Id=6005; StartTime=$k0 } | Select-Object -First 1
	$logon = Get-WinEvent -FilterHashtable @{ LogName='Microsoft-Windows-Shell-Core/Operational'; Id=62170; StartTime=$k0 } | Sort-Object TimeCreated | Select-Object -First 1
	$lastApp = Get-WinEvent -FilterHashtable @{ LogName='Microsoft-Windows-Shell-Core/Operational'; Id=9708; StartTime=$k0 } | Sort-Object TimeCreated | Select-Object -Last 1
	$gp = Get-WinEvent -FilterHashtable @{ LogName='System'; ProviderName='Microsoft-Windows-GroupPolicy'; Id=1502,1500; StartTime=$k0 } | Select-Object -First 1
	$wl = Get-WinEvent -FilterHashtable @{ LogName='System'; ProviderName='Microsoft-Windows-Winlogon'; Id=7001; StartTime=$k0 } | Sort-Object TimeCreated | Select-Object -First 1
	foreach ($m in @(@('kernel start', $k0), @('services (event log) up', $el.TimeCreated), @('group policy processed', $gp.TimeCreated), @('user signed in (Winlogon 7001)', $wl.TimeCreated), @('user logon tasks begin', $logon.TimeCreated), @('last startup app launched', $lastApp.TimeCreated)) | Where-Object { $_[1] } | Sort-Object { $_[1] }) {
		"  T+{0,4}s  {1}" -f [int]($m[1] - $k0).TotalSeconds, $m[0]
	}
	if ($wl -and $lastApp) { "  sign-in to last startup app: {0}s  (judge startup cost on this; a large T+ at sign-in means the machine sat at the lock screen, not a slow boot)" -f [int]($lastApp.TimeCreated - $wl.TimeCreated).TotalSeconds }
	if ($isAdmin) {
		'-- Boot duration (Diagnostics-Performance 100; the log is often empty even when elevated) --'
		$bp = Get-WinEvent -FilterHashtable @{ LogName='Microsoft-Windows-Diagnostics-Performance/Operational'; Id=100 } -MaxEvents 5
		if ($bp) { $bp | ForEach-Object {
			$d = @{}; ([xml]$_.ToXml()).Event.EventData.Data | ForEach-Object { $d[$_.Name] = $_.'#text' }
			"  {0}  total={1}s  mainPath={2}s  postBoot={3}s" -f $_.TimeCreated, [math]::Round($d.BootTime/1000), [math]::Round($d.MainPathBootTime/1000), [math]::Round($d.BootPostBootTime/1000) } } else { '  (no Id 100 records; use the milestone list above)' }
	} else { '  (boot-duration log needs elevation; use the milestone list above)' }
}

Try-Run 'WINDOWS UPDATE' {
	"Pending reboot: CBS=$(Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending') WU=$(Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired') FileRename=$($null -ne (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager').PendingFileRenameOperations)"
	$s = New-Object -ComObject Microsoft.Update.Session; $srch = $s.CreateUpdateSearcher(); $n = $srch.GetTotalHistoryCount()
	if ($n) { $srch.QueryHistory(0, [math]::Min(5, $n)) | ForEach-Object { "  {0:yyyy-MM-dd}  {1,-5} {2}" -f $_.Date, $(switch ($_.ResultCode) { 2 {'OK'} 3 {'OK*'} 4 {'FAIL'} 5 {'ABORT'} default {$_} }), (Trunc $_.Title 90) } }
	if ($CheckUpdates) {
		$r = $srch.Search('IsInstalled=0 and IsHidden=0')
		"Pending updates: $($r.Updates.Count)"; $r.Updates | ForEach-Object { "  - $($_.Title)" }
	} else { '  (re-run with -CheckUpdates to search for pending updates; adds ~30 s)' }
}

Try-Run 'DISK HYGIENE' {
	foreach ($d in $env:TEMP, 'C:\Windows\Temp', 'C:\Windows\SoftwareDistribution\Download', 'C:\Windows\Logs\CBS', 'C:\$Recycle.Bin', 'C:\Windows\Minidump') {
		if (-not (Test-Path -LiteralPath $d)) { continue }
		$s = (Get-ChildItem -LiteralPath $d -Recurse -Force | Measure-Object Length -Sum).Sum
		"  {0,-50} {1,8:N0} MB" -f $d, ($s/1MB)
	}
	$low = Get-Volume | Where-Object { $_.DriveLetter -and $_.DriveLetter -ne 'C' -and $_.Size -gt 0 -and ($_.SizeRemaining / $_.Size) -lt 0.15 }
	foreach ($v in $low) {
		"  -- $($v.DriveLetter): is under 15% free; largest top-level folders --"
		Get-ChildItem "$($v.DriveLetter):\" -Directory -Force | ForEach-Object { [pscustomobject]@{ Folder = $_.Name; GB = [math]::Round(((Get-ChildItem -LiteralPath $_.FullName -Recurse -File -Force | Measure-Object Length -Sum).Sum)/1GB, 1) } } | Sort-Object GB -Descending | Select-Object -First 8 | ForEach-Object { "     {0,-45} {1,7:N1} GB" -f $_.Folder, $_.GB }
	}
}

''
'==== END ===='
