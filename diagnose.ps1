# Windows 11 slowness diagnostic. Read-only: makes no changes to the system.
# Run with:  pwsh -NoProfile -File diagnose.ps1 [-CheckUpdates]
# Elevation is optional; sections that need it say so and are skipped when unavailable.
# -CheckUpdates adds a Windows Update pending-search (COM, adds ~30 s).
# -JsonOut writes the measured KPIs to a timestamped JSON file (default %TEMP%\win-diag-metrics_<stamp>.json)
#   and prints a delta table against the newest earlier metrics file, so regressions show up run to run.
# -NoJson suppresses that file.
param([switch]$CheckUpdates, [string]$JsonOut, [switch]$NoJson)

$ErrorActionPreference = 'SilentlyContinue'
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole('Administrators')

# Metrics captured for the JSON baseline. Each section adds to this as it computes its figures, so the
# JSON always holds the same numbers the text report printed (never a second, later sample).
$script:M = [ordered]@{}
function Metric($name, $value) { $script:M[$name] = $value }

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
	# Hourly samples; the trend says more than the latest value, and interpret.md judges on it.
	$relAll = @(Get-CimInstance Win32_ReliabilityStabilityMetrics | Sort-Object TimeGenerated -Descending)
	$rel = $relAll | Select-Object -First 1
	$relAgo = @{}; foreach ($d in 7, 30) { $relAgo[$d] = ($relAll | Where-Object { $_.TimeGenerated -le (Get-Date).AddDays(-$d) } | Select-Object -First 1).SystemStabilityIndex }
	if ($rel) {
		"Reliability index: {0:N2} / 10 now, {1} 7 days ago, {2} 30 days ago (Reliability Monitor)" -f $rel.SystemStabilityIndex, $(if ($null -ne $relAgo[7]) { '{0:N2}' -f $relAgo[7] } else { 'n/a' }), $(if ($null -ne $relAgo[30]) { '{0:N2}' -f $relAgo[30] } else { 'n/a' })
		# Reliability records mix successes (WindowsUpdateClient 19 = installed, MsiInstaller 1033) with failures.
		# Only failures lower the index, so list just those to explain the score.
		$relFail = 'Application Error|1000', 'Application Hang|1002', 'Microsoft-Windows-WindowsUpdateClient|20', 'MsiInstaller|11708', 'EventLog|6008', 'Microsoft-Windows-Kernel-Power|41', 'Microsoft-Windows-WER-SystemErrorReporting|1001'
		$since30 = [Management.ManagementDateTimeConverter]::ToDmtfDateTime((Get-Date).AddDays(-30))
		$relRec = @(Get-CimInstance Win32_ReliabilityRecords -Filter "TimeGenerated > '$since30'" | Where-Object { "$($_.SourceName)|$($_.EventIdentifier)" -in $relFail })
		'  failures that lowered it, 30 days:' + $(if (-not $relRec) { ' none' })
		$relRec | Group-Object SourceName, EventIdentifier, ProductName | Sort-Object Count -Descending | Select-Object -First 8 | ForEach-Object { "    x{0,-3} {1,-28} {2,-5} {3}" -f $_.Count, ($_.Group[0].SourceName -replace '^Microsoft-Windows-', ''), $_.Group[0].EventIdentifier, (Trunc $_.Group[0].ProductName 60) }
	}
	$ws = Get-CimInstance Win32_WinSAT
	if ($ws.WinSATAssessmentState -eq 1) { "WinSAT:   cpu=$($ws.CPUScore) mem=$($ws.MemoryScore) disk=$($ws.DiskScore) gfx=$($ws.GraphicsScore) d3d=$($ws.D3DScore) (max 9.9)" }
	Metric 'model'            "$($cs.Manufacturer) $($cs.Model)"
	Metric 'bios'             ([string]$bios.BIOSVersion)
	Metric 'os_build'         $os.Version
	Metric 'cpu'              $cpu.Name
	Metric 'cpu_cores'        $cpu.NumberOfCores
	Metric 'cpu_threads'      $cpu.NumberOfLogicalProcessors
	Metric 'cpu_base_mhz'     $cpu.MaxClockSpeed
	Metric 'ram_total_gb'     ([math]::Round($cs.TotalPhysicalMemory/1GB, 1))
	Metric 'dimms_populated'  $dimms.Count
	Metric 'dimm_slots'       $slots
	Metric 'uptime_min'       ([math]::Round(((Get-Date) - $os.LastBootUpTime).TotalMinutes, 1))
	Metric 'monitors'         ((Get-CimInstance -Namespace root\wmi WmiMonitorBasicDisplayParams | Measure-Object).Count)
	Metric 'gpu_driver'       ((Get-CimInstance Win32_VideoController | Select-Object -First 1).DriverVersion)
	if ($rel) { Metric 'reliability_index' ([math]::Round($rel.SystemStabilityIndex, 2)) }
	if ($null -ne $relAgo[7])  { Metric 'reliability_7d_ago'  ([math]::Round($relAgo[7], 2)) }
	if ($null -ne $relAgo[30]) { Metric 'reliability_30d_ago' ([math]::Round($relAgo[30], 2)) }
	if ($rel) { Metric 'reliability_failures_30d' @($relRec | Group-Object SourceName, EventIdentifier, ProductName | Sort-Object Count -Descending | Select-Object -First 8 | ForEach-Object { @{ source = $_.Group[0].SourceName; id = $_.Group[0].EventIdentifier; product = $_.Group[0].ProductName; count = $_.Count } }) }
	if ($ws.WinSATAssessmentState -eq 1) {
		Metric 'winsat_cpu' $ws.CPUScore; Metric 'winsat_mem' $ws.MemoryScore; Metric 'winsat_disk' $ws.DiskScore
		Metric 'winsat_gfx' $ws.GraphicsScore; Metric 'winsat_d3d' $ws.D3DScore
	}
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
	$targets = @("$env:WINDIR\System32\MRT.exe"); $readMbps = @()
	# Mark each figure, not just the header: a bare "315 MB/s" from RAM cache reads as a slow disk.
	$coldValid = ((Get-Date) - $bootTime).TotalMinutes -lt 10
	$big = Get-ChildItem "$env:ProgramFiles" -Recurse -File -Depth 4 | Where-Object Length -gt 200MB | Sort-Object Length -Descending | Select-Object -First 1
	if ($big) { $targets += $big.FullName }
	foreach ($t in $targets) {
		if (-not (Test-Path -LiteralPath $t)) { continue }
		$buf = New-Object byte[] (4MB); $fs = [IO.File]::Open($t, 'Open', 'Read', 'ReadWrite'); $sw = [Diagnostics.Stopwatch]::StartNew(); $tot = 0L
		while (($n = $fs.Read($buf, 0, $buf.Length)) -gt 0) { $tot += $n }
		$sw.Stop(); $fs.Close()
		$mbps = $tot/1MB/$sw.Elapsed.TotalSeconds
		"  {0,-70} {1,6:N0} MB  {2,6:N0} MB/s{3}" -f (Trunc $t 70), ($tot/1MB), $mbps, $(if ($coldValid) { '' } else { '  INVALID: RAM cache, not the disk' })
		$readMbps += [math]::Round($mbps)
	}
	Metric 'seq_read_mbps'      $readMbps
	Metric 'seq_read_valid'     $coldValid   # false = the figure is RAM cache, not the disk
	Metric 'disks'              (Get-PhysicalDisk | ForEach-Object { "$($_.FriendlyName)=$($_.HealthStatus)" })
	Metric 'volume_free_pct'    (Get-Volume | Where-Object { $_.DriveLetter -and $_.Size -gt 0 } | ForEach-Object { @{ drive = [string]$_.DriveLetter; free_pct = [math]::Round(100*$_.SizeRemaining/$_.Size); free_gb = [math]::Round($_.SizeRemaining/1GB) } })
	if ($isAdmin) { Metric 'smart' (Get-PhysicalDisk | Get-StorageReliabilityCounter | ForEach-Object { @{ id = $_.DeviceId; temp_c = $_.Temperature; wear_pct = $_.Wear; read_err = $_.ReadErrorsTotal; write_err = $_.WriteErrorsTotal; power_on_hours = $_.PowerOnHours } }) }
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
			Metric 'battery_health_pct' ([math]::Round(100*[int]$b.FullChargeCapacity/[int]$b.DesignCapacity))
			Metric 'battery_cycles'     ([int]$b.CycleCount)
			[IO.File]::Delete($rep)
		}
	}
	$pnp = Get-PnpDevice -PresentOnly | Where-Object { $_.FriendlyName -match 'Dynamic Tuning Manager|Intelligent Thermal|AMD Ryzen Power|Thermal Framework' }
	if ($pnp) { "OEM/Intel power-limit drivers present: " + (($pnp.FriendlyName | Sort-Object -Unique) -join '; ') }
	Metric 'power_source'      $(if ($null -eq $ac) { 'AC (no battery)' } elseif ($ac) { 'AC' } else { 'BATTERY' })
	Metric 'power_scheme'      (((powercfg /getactivescheme) -replace '.*\(([^)]+)\).*', '$1'))
	Metric 'slider_ac'         $(if ($ov.ActiveOverlayAcPowerScheme -and $map[$ov.ActiveOverlayAcPowerScheme]) { $map[$ov.ActiveOverlayAcPowerScheme] } else { 'Balanced (default)' })
	Metric 'slider_dc'         $(if ($ov.ActiveOverlayDcPowerScheme -and $map[$ov.ActiveOverlayDcPowerScheme]) { $map[$ov.ActiveOverlayDcPowerScheme] } else { 'Balanced (default)' })
	Metric 'perfboost_override' $(if ($boost) { "AC=$($boost.ACSettingIndex) DC=$($boost.DCSettingIndex)" } else { 'none (turbo on)' })
	Metric 'oem_power_drivers' $(if ($pnp) { @($pnp.FriendlyName | Sort-Object -Unique) } else { @() })
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
	# Same samples the table above printed, keyed by short name for the JSON baseline.
	$keyMap = @{
		'% processor time'='cpu_pct'; '% privileged time'='cpu_privileged_pct'; '% interrupt time'='cpu_interrupt_pct'; '% dpc time'='cpu_dpc_pct'
		'% of maximum frequency'='cpu_max_freq_pct'; 'processor frequency'='cpu_freq_mhz'; '% processor performance'='cpu_performance_pct'
		'processor queue length'='cpu_queue_len'; 'context switches/sec'='context_switches_sec'
		'available mbytes'='mem_available_mb'; 'pages/sec'='mem_pages_sec'; '% committed bytes in use'='mem_committed_pct'
		'% idle time'='disk_idle_pct'; 'avg. disk queue length'='disk_queue_len'; 'avg. disk sec/read'='disk_sec_read'; 'avg. disk sec/write'='disk_sec_write'
	}
	foreach ($row in $sys) {
		$leaf = ($row.Counter -split '\\')[-1]
		if ($keyMap[$leaf]) { Metric $keyMap[$leaf] @{ min = $row.Min; avg = $row.Avg; max = $row.Max } }
	}
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
	Metric 'gpu_3d_pct'    ([math]::Round((($g.CookedValue | Measure-Object -Sum).Sum), 1))
	Metric 'commit_gb'     ([math]::Round(($os.TotalVirtualMemorySize - $os.FreeVirtualMemory)/1MB, 1))
	Metric 'pagefile_used_mb' ((Get-CimInstance Win32_PageFileUsage | Measure-Object CurrentUsage -Sum).Sum)
	Metric 'process_count' $p.Count
	Metric 'thread_count'  (($p.Threads.Count | Measure-Object -Sum).Sum)
	Metric 'handle_count'  (($p.Handles | Measure-Object -Sum).Sum)
	Metric 'top_cpu'       ($all | Where-Object { $_.Path -match '\\process\(' -and $_.Path -match '% processor time' -and $_.InstanceName -notin '_total','idle' } | Group-Object InstanceName | ForEach-Object { @{ name = $_.Name; cpu_pct = [math]::Round(($_.Group.CookedValue | Measure-Object -Average).Average / $n, 1) } } | Sort-Object { -$_.cpu_pct } | Select-Object -First 10)
}

Try-Run 'PROCESSES' {
	$procs = Get-Process
	"Process count: $($procs.Count)   Running services: $((Get-Service | Where-Object Status -eq Running).Count)"
	'-- memory by process name (grouped; Private is the honest number, WorkingSet double-counts shared pages) --'
	$procs | Group-Object Name | ForEach-Object { [pscustomobject]@{ Name = $_.Name; Count = $_.Count; WS_MB = [math]::Round(($_.Group | Measure-Object WorkingSet64 -Sum).Sum/1MB); Private_MB = [math]::Round(($_.Group | Measure-Object PrivateMemorySize64 -Sum).Sum/1MB) } } | Sort-Object Private_MB -Descending | Select-Object -First 20 | Format-Table -AutoSize | Out-String
	'-- Electron / Chromium-style apps (many processes each) --'
	$procs | Where-Object { $_.Path -and (Test-Path -LiteralPath (Join-Path (Split-Path $_.Path) 'resources\app.asar')) } | Group-Object Name | ForEach-Object { [pscustomobject]@{ App = $_.Name; Procs = $_.Count; MB = [math]::Round(($_.Group | Measure-Object WorkingSet64 -Sum).Sum/1MB); Path = Split-Path $_.Group[0].Path } } | Sort-Object MB -Descending | Format-Table -AutoSize | Out-String -Width 200
	'-- WebView2 hosts (by host app; Private MB) --'
	# Most WebView2 processes are children of another msedgewebview2, so the parent alone names nothing. Each
	# browser process carries --webview-exe-name=<host app>; helpers without it (crashpad) inherit their parent's host.
	$wv = @(Get-CimInstance Win32_Process -Filter "Name='msedgewebview2.exe'")
	$hostOf = @{}; foreach ($p in $wv) { if ($p.CommandLine -match '--webview-exe-name=(\S+)') { $hostOf[$p.ProcessId] = $Matches[1] } }
	$wvHosts = $wv | ForEach-Object {
		$h = $hostOf[$_.ProcessId]
		if (-not $h) { $h = $hostOf[$_.ParentProcessId] }
		if (-not $h) { $pp = Get-Process -Id $_.ParentProcessId; $h = if ($pp -and $pp.Name -ne 'msedgewebview2') { "$($pp.Name).exe" } else { 'unknown' } }
		[pscustomobject]@{ Host = $h; Private = $_.PrivatePageCount }
	} | Group-Object Host | ForEach-Object { [pscustomobject]@{ Host = $_.Name; Procs = $_.Count; Private_MB = [math]::Round(($_.Group | Measure-Object Private -Sum).Sum/1MB) } } | Sort-Object Private_MB -Descending
	$wvHosts | ForEach-Object { "  x{0,-3} {1,6:N0} MB  hosted by {2}" -f $_.Procs, $_.Private_MB, $_.Host }
	$sync = @($procs | Where-Object Name -in 'OneDrive', 'GoogleDriveFS', 'Dropbox', 'iCloudDrive', 'MEGAsync', 'nextcloud', 'pCloud', 'Box' | ForEach-Object Name | Select-Object -Unique)
	'Cloud sync clients running: ' + $(if ($sync) { $sync -join ', ' } else { 'none' }) + $(if ($sync.Count -gt 1) { '  -> MORE THAN ONE: each adds Explorer hooks and a file watcher; keep one' })
	'-- VM / hypervisor --'
	$dg = Get-CimInstance -ClassName Win32_DeviceGuard -Namespace root\Microsoft\Windows\DeviceGuard
	"VBS status: $($dg.VirtualizationBasedSecurityStatus) (2=running)   services running: $($dg.SecurityServicesRunning -join ',') (1=CredGuard 2=HVCI/MemoryIntegrity 3=SecureLaunch 4=SMM 5=KernelShadowStacks)   HypervisorPresent: $((Get-CimInstance Win32_ComputerSystem).HypervisorPresent)"
	Get-Process vmmem*, vmwp, vmcompute, wslservice | ForEach-Object { "  $($_.Name) pid=$($_.Id) $([math]::Round($_.WorkingSet64/1MB)) MB" }
	# wsl.exe writes UTF-16LE; without this the captured text is interleaved with NULs.
	$prevEnc = [Console]::OutputEncoding; [Console]::OutputEncoding = [Text.Encoding]::Unicode
	$wsl = wsl --list --running 2>$null | Where-Object { $_.Trim() -and $_ -notmatch 'no running|Windows Subsystem' }
	[Console]::OutputEncoding = $prevEnc
	"WSL distros running: " + $(if ($wsl) { ($wsl | ForEach-Object { $_.Trim() }) -join ', ' } else { 'none' })
	Metric 'services_running'  ((Get-Service | Where-Object Status -eq Running | Measure-Object).Count)
	Metric 'vbs_status'        $dg.VirtualizationBasedSecurityStatus
	Metric 'vbs_services'      ($dg.SecurityServicesRunning -join ',')
	Metric 'hypervisor_present' (Get-CimInstance Win32_ComputerSystem).HypervisorPresent
	Metric 'webview2_count'    $wv.Count
	Metric 'webview2_hosts'    @($wvHosts | ForEach-Object { @{ host = $_.Host; procs = $_.Procs; private_mb = $_.Private_MB } })
	Metric 'cloud_sync_clients' $sync
	Metric 'top_memory'        ($procs | Group-Object Name | ForEach-Object { @{ name = $_.Name; count = $_.Count; private_mb = [math]::Round(($_.Group | Measure-Object PrivateMemorySize64 -Sum).Sum/1MB) } } | Sort-Object { -$_.private_mb } | Select-Object -First 15)
	Metric 'electron_apps'     ($procs | Where-Object { $_.Path -and (Test-Path -LiteralPath (Join-Path (Split-Path $_.Path) 'resources\app.asar')) } | Group-Object Name | ForEach-Object { @{ name = $_.Name; procs = $_.Count; ws_mb = [math]::Round(($_.Group | Measure-Object WorkingSet64 -Sum).Sum/1MB) } })
}

Try-Run 'STARTUP' {
	'-- Run keys / Startup folders --'
	# HKU\.DEFAULT and HKU\S-1-5-18 are the same LocalSystem hive under two names; its Run key does not fire at user
	# logon, so label it and list it once instead of showing the same entry twice beside the real HKCU one.
	Get-CimInstance Win32_StartupCommand | Select-Object Name, @{n='Where';e={ $_.Location -replace 'HKU\\S-1-5-21[^\\]+', 'HKCU' -replace 'HKU\\(S-1-5-18|\.DEFAULT)', 'SYSTEM (not at logon)' -replace 'SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\', '' }}, @{n='Cmd';e={ Trunc ($_.Command -replace '"','') 80 }} | Sort-Object Where, Name -Unique | Format-Table -AutoSize | Out-String -Width 220
	'-- Task Manager approval state (first byte even = enabled, odd = disabled: 02/06 enabled, 03 disabled; STALE = no Run key or Startup-folder item of that name) --'
	# Print the hive so the removal command for a stale entry is known (HKLM needs elevation). Match Run approvals
	# against every Run key, including WOW6432Node, so an entry is never called stale because it lives in another hive.
	$runNames = foreach ($r in 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run','HKLM:\Software\Microsoft\Windows\CurrentVersion\Run','HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Run') { (Get-Item $r).GetValueNames() }
	$folderNames = (Get-ChildItem -LiteralPath ([Environment]::GetFolderPath('Startup')) -Force).Name
	foreach ($k in 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run','HKLM:\Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run','HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\StartupFolder') {
		$present = if ($k -like '*StartupFolder') { $folderNames } else { $runNames }
		$key = Get-Item $k
		foreach ($name in $key.GetValueNames()) {
			$b = ([byte[]]$key.GetValue($name))[0]
			"  {0,-56} {1:X2} {2,-8} {3,-22} {4}" -f $name, $b, $(if ($b -band 1) { 'disabled' } else { 'enabled' }), ($k -replace ':.*StartupApproved', ''), $(if ($name -notin $present) { 'STALE' })
		}
	}
	'-- Startup app cost this boot, slowest first (Shell-Core 9707 start to 9708 finish for each Run entry) --'
	$sc = Get-WinEvent -FilterHashtable @{ LogName='Microsoft-Windows-Shell-Core/Operational'; Id=9707,9708; StartTime=$bootTime } | Sort-Object TimeCreated
	if ($sc) {
		# Pair each start with the first unused finish for the same command; a 9708 adds "(PID n)" to the text.
		$cmdOf = { param($e) (($e.Message -replace '.*command ', '') -replace '[''"]', '' -replace '\.$', '' -replace '\s*\(PID \d+\)$', '').Trim() }
		$used = @{}
		$costs = foreach ($s in $sc | Where-Object Id -eq 9707) {
			$c = & $cmdOf $s
			$f = $sc | Where-Object { $_.Id -eq 9708 -and $_.TimeCreated -ge $s.TimeCreated -and -not $used[$_.RecordId] -and (& $cmdOf $_) -eq $c } | Select-Object -First 1
			if ($f) { $used[$f.RecordId] = $true }
			[pscustomobject]@{ StartTplus = [int]($s.TimeCreated - $bootTime).TotalSeconds; Seconds = $(if ($f) { [math]::Round(($f.TimeCreated - $s.TimeCreated).TotalSeconds, 1) } else { $null }); Command = $c }
		}
		$costs | Sort-Object { -[double]$_.Seconds } | ForEach-Object { "  {0,6}s  at T+{1,4}s  {2}" -f $(if ($null -ne $_.Seconds) { $_.Seconds } else { '?' }), $_.StartTplus, (Trunc $_.Command 90) }
		Metric 'startup_costs_s' @($costs | Sort-Object { -[double]$_.Seconds } | ForEach-Object { @{ command = (Trunc $_.Command 90); start_tplus_s = $_.StartTplus; seconds = $_.Seconds } })
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
	# One lookup of one name measures a cold cache miss and the authoritative round trip, not the resolver:
	# a single microsoft.com probe read 630 ms on a link whose warm lookups were 7-20 ms. Sample four names
	# and report the median, so a slow first hop cannot masquerade as a DNS problem.
	$dnsMs = foreach ($h in 'www.microsoft.com','github.com','www.google.com','cloudflare.com') {
		[math]::Round((Measure-Command { Resolve-DnsName $h -Type A -ErrorAction SilentlyContinue | Out-Null }).TotalMilliseconds)
	}
	$dnsSorted = $dnsMs | Sort-Object; $dnsMedian = $dnsSorted[[int]($dnsSorted.Count/2)]
	"DNS resolve: {0:N0} ms median of 4 ({1} ms)  -- judge on the median; the slowest is usually a cold cache miss" -f $dnsMedian, ($dnsMs -join ', ')
	$ping = Test-Connection 1.1.1.1 -Count 3 | Measure-Object Latency -Average; if ($ping.Count) { "Ping 1.1.1.1: {0:N0} ms avg" -f $ping.Average }
	$gw = (Get-NetRoute -DestinationPrefix '0.0.0.0/0' | Sort-Object RouteMetric | Select-Object -First 1).NextHop
	$gwPing = if ($gw) { (Test-Connection $gw -Count 3 -ErrorAction SilentlyContinue | Measure-Object Latency -Average).Average }
	if ($gwPing) { "Ping gateway ${gw}: {0:N0} ms avg" -f $gwPing }
	Metric 'av_product'        ((Get-CimInstance -Namespace root/SecurityCenter2 -ClassName AntiVirusProduct | ForEach-Object { $_.displayName }) -join ', ')
	Metric 'defender_realtime' $mp.RealTimeProtectionEnabled
	Metric 'dns_median_ms'     $dnsMedian
	Metric 'dns_samples_ms'    @($dnsMs)
	Metric 'ping_internet_ms'  ([math]::Round($ping.Average, 1))
	Metric 'ping_gateway_ms'   $(if ($gwPing) { [math]::Round($gwPing, 1) } else { $null })
	Metric 'vpn_filter_services' @(Get-CimInstance Win32_Service | Where-Object { $_.State -eq 'Running' -and $_.Name -match 'threatprotection|webfilter|nordsec' } | ForEach-Object { $_.Name })
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
	$e7009 = Get-WinEvent -FilterHashtable @{ LogName='System'; ProviderName='Service Control Manager'; Id=7009; StartTime=(Get-Date).AddDays(-30) } | ForEach-Object {
		$ev = $_
		$disp = if ($ev.Message -match 'waiting for the (.+?) service to connect') { $Matches[1] } else { '?' }
		$prevBoot = $boots | Where-Object { $_.TimeCreated -le $ev.TimeCreated } | Select-Object -Last 1
		$tplus = if ($prevBoot) { [int]($ev.TimeCreated - $prevBoot.TimeCreated).TotalSeconds } else { -1 }
		$svc = $svcByDisplay[$disp]
		[pscustomobject]@{ When = $ev.TimeCreated; Display = $disp; Tplus_s = $tplus; Verdict = $(if ($tplus -ge 0 -and $tplus -lt 45) { 'noise' } elseif ($tplus -ge 45) { 'REAL WAIT' } else { '?' }); Registered = $(if ($svc) { "$($svc.Name) start=$($svc.StartMode) state=$($svc.State)" } else { 'NOT REGISTERED (spawned by a driver/helper; correlate with Biometrics 1600, Kernel-PnP, vendor logs)' }) }
	}
	$e7009 | Group-Object Display, Verdict, Registered | ForEach-Object { "  x{0,-3} T+{1,4}s  {2,-9}  {3,-40} {4}" -f $_.Count, $_.Group[0].Tplus_s, $_.Group[0].Verdict, (Trunc $_.Group[0].Display 40), $_.Group[0].Registered }
	if (-not $e7009) { '  none in 30 days' }
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
	# Ids 1000/1002 are only crashes and hangs when Windows Error Reporting logs them. Other providers reuse the
	# same ids for routine messages: the Codex sandbox service logs "is running"/"has stopped" as 1000/1002.
	$appFaults = Get-WinEvent -FilterHashtable @{ LogName='Application'; ProviderName='Application Error','Application Hang'; Id=1000,1002; StartTime=$since }
	$appFaults | ForEach-Object { [pscustomobject]@{ Kind=$(if ($_.Id -eq 1002) {'hang'} else {'crash'}); App=$_.Properties[0].Value; Path=$(if ($_.Message -match '(?m)^(?:Faulting application path|Application Path):\s*(.+?)\s*$') { $Matches[1] } else { '?' }) } } | Group-Object Kind, App | Sort-Object Count -Descending | Select-Object -First 10 Count, Name, @{n='Path';e={ Trunc $_.Group[0].Path 110 }} | Format-Table -AutoSize | Out-String -Width 220
	if (-not $appFaults) { '  none' }
	'-- Hardware / storage / power warnings and errors, 30 days (WHEA, disk, Ntfs, volmgr, Kernel-Power 41) --'
	$hw = Get-WinEvent -FilterHashtable @{ LogName='System'; ProviderName='disk','storahci','stornvme','Ntfs','volmgr','Microsoft-Windows-WHEA-Logger','Microsoft-Windows-Kernel-Power'; Level=1,2,3; StartTime=(Get-Date).AddDays(-30) } | Group-Object ProviderName, Id
	if ($hw) { $hw | ForEach-Object { "  x$($_.Count)  $($_.Name)" } } else { '  none' }
	# A 41 count alone does not say what happened. The named fields do: a bugcheck code is a blue screen, a power-button
	# timestamp is a forced power-off, SleepInProgress non-zero means it died during a sleep or hibernate transition.
	$kp41 = @(Get-WinEvent -FilterHashtable @{ LogName='System'; ProviderName='Microsoft-Windows-Kernel-Power'; Id=41; StartTime=(Get-Date).AddDays(-30) } -MaxEvents 3)
	foreach ($e in $kp41) {
		$f = @{}; ([xml]$e.ToXml()).Event.EventData.Data | ForEach-Object { $f[$_.Name] = $_.'#text' }
		$why = if ([int64]$f['BugcheckCode'] -ne 0) { 'blue screen (check Windows\Minidump)' } elseif ([int64]$f['PowerButtonTimestamp'] -ne 0 -or $f['LongPowerButtonPressDetected'] -eq 'true') { 'power button held (forced off)' } elseif ([int]$f['SleepInProgress'] -ne 0) { 'lost during a sleep/hibernate transition' } else { 'no bugcheck, no button: power loss or hard hang' }
		"    Kernel-Power 41 at {0:yyyy-MM-dd HH:mm}: bugcheck={1} sleepInProgress={2} powerButton={3} -> {4}" -f $e.TimeCreated, $f['BugcheckCode'], $f['SleepInProgress'], $f['PowerButtonTimestamp'], $why
	}
	'-- Biometrics secure-component failures (1600): pairs with a SynaHlp-style 7009 from the fingerprint driver --'
	$bio1600 = @(Get-WinEvent -FilterHashtable @{ LogName='Microsoft-Windows-Biometrics/Operational'; Id=1600; StartTime=(Get-Date).AddDays(-30) })
	"  $($bio1600.Count) in 30 days" + $(if ($bio1600) { "  (latest $(($bio1600 | Sort-Object TimeCreated -Descending | Select-Object -First 1).TimeCreated))" })
	# 1600 outliving its 7009 means the sensor was disabled and only the cosmetic log entry remains. Compare the
	# newest of each: presence anywhere in the 30-day window proves nothing, because the window still holds the
	# boots from before the fix. Count the cold boots since, so "it stopped" is backed by boots that would have shown it.
	if ($bio1600) {
		$newest1600 = ($bio1600 | Sort-Object TimeCreated -Descending | Select-Object -First 1).TimeCreated
		$newest7009 = ($e7009 | Where-Object { $_.Registered -match 'NOT REGISTERED' } | Sort-Object When -Descending | Select-Object -First 1).When
		if (-not $newest7009) { '  (no unregistered-service 7009 in 30 days: 1600 alone is cosmetic log noise)' }
		elseif ($newest1600 -gt $newest7009) {
			$coldSince = @($boots | Where-Object { $_.TimeCreated -gt $newest7009 -and $_.Message -match 'type was 0x0' }).Count
			"  (paired 7009 last seen $($newest7009.ToString('yyyy-MM-dd')), $coldSince cold boot(s) ago, while 1600 still fires: the service timeout has stopped and 1600 alone is cosmetic)"
		}
	}
	'-- Processor power capability events (Id 55 is INFORMATIONAL, logged every boot; ignore) --'
	Get-WinEvent -FilterHashtable @{ LogName='System'; ProviderName='Microsoft-Windows-Kernel-Processor-Power'; StartTime=$since } | Group-Object Id | ForEach-Object { "  Id $($_.Name): $($_.Count)" }
	'-- Resource exhaustion detector (2004, 30 days) --'
	"  " + ((Get-WinEvent -FilterHashtable @{ LogName='System'; Id=2004; ProviderName='Microsoft-Windows-Resource-Exhaustion-Detector'; StartTime=(Get-Date).AddDays(-30) } | Measure-Object).Count) + " events"
	'-- This boot: milestones from the System and Shell-Core logs (works without elevation) --'
	$kg = Get-WinEvent -FilterHashtable @{ LogName='System'; ProviderName='Microsoft-Windows-Kernel-General'; Id=12; StartTime=$bootTime.AddMinutes(-2) } | Sort-Object TimeCreated | Select-Object -First 1
	$k0 = if ($kg) { $kg.TimeCreated } else { $bootTime }
	$el = Get-WinEvent -FilterHashtable @{ LogName='System'; ProviderName='EventLog'; Id=6005; StartTime=$k0 } | Select-Object -First 1
	$logon = Get-WinEvent -FilterHashtable @{ LogName='Microsoft-Windows-Shell-Core/Operational'; Id=62170; StartTime=$k0 } | Sort-Object TimeCreated | Select-Object -First 1
	$gp = Get-WinEvent -FilterHashtable @{ LogName='System'; ProviderName='Microsoft-Windows-GroupPolicy'; Id=1502,1500; StartTime=$k0 } | Select-Object -First 1
	$logons = @(Get-WinEvent -FilterHashtable @{ LogName='System'; ProviderName='Microsoft-Windows-Winlogon'; Id=7001; StartTime=$k0 } | Sort-Object TimeCreated)
	$wl = $logons | Select-Object -First 1
	# A sign-out and second sign-in in the same boot produces a second burst of 9708s hours later. Spanning the
	# first 7001 to the very last 9708 then reports a nonsense figure (14188s on the run that found this).
	# Score each logon session against only the startup apps that ran before the next sign-in.
	$appEnds = @(Get-WinEvent -FilterHashtable @{ LogName='Microsoft-Windows-Shell-Core/Operational'; Id=9708; StartTime=$k0 } | Sort-Object TimeCreated)
	$lastApp = $appEnds | Select-Object -Last 1
	foreach ($m in @(@('kernel start', $k0), @('services (event log) up', $el.TimeCreated), @('group policy processed', $gp.TimeCreated), @('user signed in (Winlogon 7001)', $wl.TimeCreated), @('user logon tasks begin', $logon.TimeCreated), @('last startup app launched', $lastApp.TimeCreated)) | Where-Object { $_[1] } | Sort-Object { $_[1] }) {
		"  T+{0,4}s  {1}" -f [int]($m[1] - $k0).TotalSeconds, $m[0]
	}
	$spans = @()
	for ($i = 0; $i -lt $logons.Count; $i++) {
		$start = $logons[$i].TimeCreated
		$end   = if ($i + 1 -lt $logons.Count) { $logons[$i + 1].TimeCreated } else { [datetime]::MaxValue }
		$last  = $appEnds | Where-Object { $_.TimeCreated -ge $start -and $_.TimeCreated -lt $end } | Select-Object -Last 1
		if ($last) { $spans += [pscustomobject]@{ Session = $i + 1; SignInTplus = [int]($start - $k0).TotalSeconds; Seconds = [int]($last.TimeCreated - $start).TotalSeconds } }
	}
	if ($logons.Count -gt 1) { "  ($($logons.Count) sign-ins this boot; each scored separately against its own startup apps)" }
	foreach ($s in $spans) { "  sign-in #{0} (at T+{1}s) to its last startup app: {2}s  (judge startup cost on this, healthy under 60 s; a large T+ at sign-in means the machine sat at the lock screen, not a slow boot)" -f $s.Session, $s.SignInTplus, $s.Seconds }
	Metric 'boot_type_counts'   ($boots | ForEach-Object { if ($_.Message -match 'type was (0x\d)') { $Matches[1] } else { '?' } } | Group-Object | ForEach-Object { @{ type = $_.Name; count = $_.Count } })
	Metric 'ev_7009_real'       (@($e7009 | Where-Object Verdict -eq 'REAL WAIT').Count)
	Metric 'ev_7009_noise'      (@($e7009 | Where-Object Verdict -eq 'noise').Count)
	Metric 'ev_7026_this_boot'  $(if ($e7026 -and $e7026.TimeCreated -gt $bootTime.AddMinutes(-5)) { 1 } else { 0 })
	Metric 'ev_biometrics_1600' $bio1600.Count
	Metric 'ev_sys_errors_7d'   ((Get-WinEvent -FilterHashtable @{ LogName='System'; Level=1,2; StartTime=$since } | Measure-Object).Count)
	Metric 'ev_app_crashes_7d'  (@($appFaults | Where-Object Id -eq 1000).Count)
	Metric 'ev_app_hangs_7d'    (@($appFaults | Where-Object Id -eq 1002).Count)
	Metric 'ev_hw_warnings_30d' (@($hw | ForEach-Object { $_.Count } | Measure-Object -Sum).Sum)
	Metric 'ev_resource_exhaustion_30d' ((Get-WinEvent -FilterHashtable @{ LogName='System'; Id=2004; ProviderName='Microsoft-Windows-Resource-Exhaustion-Detector'; StartTime=(Get-Date).AddDays(-30) } | Measure-Object).Count)
	Metric 'boot_services_up_s' $(if ($el) { [int]($el.TimeCreated - $k0).TotalSeconds } else { $null })
	Metric 'boot_signin_s'      $(if ($wl) { [int]($wl.TimeCreated - $k0).TotalSeconds } else { $null })
	Metric 'logon_sessions'     $logons.Count
	Metric 'startup_spans_s'    @($spans | ForEach-Object { @{ session = $_.Session; signin_tplus_s = $_.SignInTplus; seconds = $_.Seconds } })
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
		Metric 'pending_updates'       $r.Updates.Count
		Metric 'pending_update_titles' @($r.Updates | ForEach-Object { $_.Title })
	} else { '  (re-run with -CheckUpdates to search for pending updates; adds ~30 s)' }
	Metric 'pending_reboot' (
		(Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending') -or
		(Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired'))
	Metric 'wu_recent_failures' ((Get-WinEvent -FilterHashtable @{ LogName='System'; ProviderName='Microsoft-Windows-WindowsUpdateClient'; Id=20; StartTime=(Get-Date).AddDays(-7) } | Measure-Object).Count)
}

Try-Run 'DISK HYGIENE' {
	$hyg = @{}
	foreach ($d in $env:TEMP, 'C:\Windows\Temp', 'C:\Windows\SoftwareDistribution\Download', 'C:\Windows\Logs\CBS', 'C:\$Recycle.Bin', 'C:\Windows\Minidump') {
		if (-not (Test-Path -LiteralPath $d)) { continue }
		$s = (Get-ChildItem -LiteralPath $d -Recurse -Force | Measure-Object Length -Sum).Sum
		"  {0,-50} {1,8:N0} MB" -f $d, ($s/1MB)
		$hyg[$d] = [math]::Round($s/1MB)
	}
	Metric 'temp_folder_mb' $hyg
	Metric 'pagefile_gb'    ([math]::Round(((Get-ChildItem C:\ -Force | Where-Object Name -eq 'pagefile.sys').Length)/1GB, 1))
	Metric 'hiberfil_gb'    ([math]::Round(((Get-ChildItem C:\ -Force | Where-Object Name -eq 'hiberfil.sys').Length)/1GB, 1))
	$low = Get-Volume | Where-Object { $_.DriveLetter -and $_.DriveLetter -ne 'C' -and $_.Size -gt 0 -and ($_.SizeRemaining / $_.Size) -lt 0.15 }
	foreach ($v in $low) {
		"  -- $($v.DriveLetter): is under 15% free; largest top-level folders --"
		Get-ChildItem "$($v.DriveLetter):\" -Directory -Force | ForEach-Object { [pscustomobject]@{ Folder = $_.Name; GB = [math]::Round(((Get-ChildItem -LiteralPath $_.FullName -Recurse -File -Force | Measure-Object Length -Sum).Sum)/1GB, 1) } } | Sort-Object GB -Descending | Select-Object -First 8 | ForEach-Object { "     {0,-45} {1,7:N1} GB" -f $_.Folder, $_.GB }
	}
}

Try-Run 'METRICS BASELINE (JSON)' {
	if ($NoJson) { '  (-NoJson: no metrics file written)'; return }
	$dir = if ($JsonOut) { Split-Path -Parent $JsonOut } else { $env:TEMP }
	if (-not $dir) { $dir = $env:TEMP }
	$path = if ($JsonOut) { $JsonOut } else { Join-Path $env:TEMP ('win-diag-metrics_{0}.json' -f (Get-Date -Format 'yyyy-MM-dd_HHmmss')) }

	# Compare against the newest earlier baseline before writing this one, so the delta is run-over-run.
	$prior = Get-ChildItem (Join-Path $dir 'win-diag-metrics_*.json') | Sort-Object LastWriteTime -Descending | Select-Object -First 1
	# Read it now: when -JsonOut names an existing file, $prior is that file and the write below replaces it, so
	# reading after the write compared the run against itself (every delta 0).
	if ($prior) { $priorAge = [int]((Get-Date) - $prior.LastWriteTime).TotalHours; $old = (Get-Content -LiteralPath $prior.FullName -Raw | ConvertFrom-Json).metrics }

	$doc = [ordered]@{
		schema       = 'win-diag-metrics/1'
		collected_at = (Get-Date).ToString('o')
		hostname     = $env:COMPUTERNAME
		elevated     = $isAdmin
		boot_time    = $bootTime.ToString('o')
		checked_updates = [bool]$CheckUpdates
		metrics      = $script:M
	}
	$doc | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $path -Encoding utf8
	"  written: $path"

	if (-not $prior) { '  (no earlier baseline in this folder; this run is the reference for the next one)'; return }
	"  comparing against: $($prior.Name)  ($priorAge h ago)"
	# Only the scalar KPIs worth tracking. Direction says which way is bad, so a regression is obvious at a glance.
	$track = [ordered]@{
		'cpu_pct'            = 'lower'; 'cpu_privileged_pct' = 'lower'; 'cpu_queue_len'     = 'lower'
		'cpu_performance_pct'= 'higher'; 'cpu_max_freq_pct'  = 'higher'; 'cpu_freq_mhz'     = 'higher'
		'mem_available_mb'   = 'higher'; 'mem_pages_sec'     = 'lower';  'mem_committed_pct'= 'lower'
		'disk_idle_pct'      = 'higher'; 'disk_queue_len'    = 'lower';  'disk_sec_read'    = 'lower'; 'disk_sec_write' = 'lower'
		'process_count'      = 'lower';  'thread_count'      = 'lower';  'handle_count'     = 'lower'; 'services_running' = 'lower'
		'reliability_index'  = 'higher'; 'dns_median_ms'     = 'lower';  'ping_internet_ms' = 'lower'
		'battery_health_pct' = 'higher'; 'commit_gb'         = 'lower';  'gpu_3d_pct'       = 'lower'
		'ev_7009_real'       = 'lower';  'ev_app_crashes_7d' = 'lower';  'ev_app_hangs_7d'  = 'lower'
		'ev_sys_errors_7d'   = 'lower';  'ev_hw_warnings_30d'= 'lower';  'ev_resource_exhaustion_30d' = 'lower'
	}
	$rows = foreach ($k in $track.Keys) {
		$nv = $script:M[$k]; $ov = $old.$k
		# Counter metrics are {min,avg,max}; compare the average.
		if ($nv -is [hashtable]) { $nv = $nv.avg }
		if ($ov -and $ov.PSObject.Properties.Name -contains 'avg') { $ov = $ov.avg }
		if ($null -eq $nv -or $null -eq $ov) { continue }
		$d = [math]::Round([double]$nv - [double]$ov, 2)
		$flag = if ($d -eq 0) { '' } elseif (($track[$k] -eq 'lower' -and $d -gt 0) -or ($track[$k] -eq 'higher' -and $d -lt 0)) { 'WORSE' } else { 'better' }
		[pscustomobject]@{ Metric = $k; Previous = $ov; Now = $nv; Delta = $d; Change = $flag }
	}
	$rows | Format-Table -AutoSize | Out-String -Width 120
	'  A WORSE flag is only a regression if the two runs were in comparable states: check uptime_min, power_source'
	'  and whether a scan or updater was running in top_cpu on either run before calling it one.'
}

''
'==== END ===='
