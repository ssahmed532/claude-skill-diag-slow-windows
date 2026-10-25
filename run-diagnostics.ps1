# Runs diagnose.ps1 elevated when the user approves the UAC prompt, otherwise as the current user.
# Run with:  pwsh -NoProfile -File run-diagnostics.ps1 -OutDir <folder> [-CheckUpdates] [-NoElevate] [-UacTimeoutSec 120]
# Elevation adds SMART/wear counters, BitLocker, thermal zones, the boot-duration log and system-wide scheduled tasks.
# A denied prompt, or one left unanswered for -UacTimeoutSec, falls back to a standard run; the diagnostic is still complete
# apart from those sections. A timed-out prompt stays on screen, and approving it later runs nothing. Prints "elevation: <outcome>" (approved, denied, timed out, already elevated, skipped) and
# "report: <path>" for the caller to read.
param([Parameter(Mandatory)][string]$OutDir, [switch]$CheckUpdates, [switch]$NoElevate, [int]$UacTimeoutSec = 120)

$ErrorActionPreference = 'Stop'
$diag = Join-Path $PSScriptRoot 'diagnose.ps1'
$null = New-Item -ItemType Directory -Force -Path $OutDir
$stamp = Get-Date -Format 'yyyy-MM-dd_HHmmss'
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole('Administrators')
# Name the metrics file here so an elevated run under another admin account still writes to this user's baseline folder.
$json = Join-Path $env:TEMP "win-diag-metrics_$stamp.json"

function Run-Standard($outcome) {
	$out = Join-Path $OutDir "diagnose_$stamp.txt"
	$a = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $diag, '-JsonOut', $json) + @(if ($CheckUpdates) { '-CheckUpdates' })
	& pwsh @a *>&1 | Out-File -LiteralPath $out -Encoding utf8
	"elevation: $outcome"
	"report: $out"
}

if ($isAdmin) { Run-Standard 'already elevated'; return }
if ($NoElevate) { Run-Standard 'skipped'; return }

# The elevated process cannot redirect its output back to this one, so it writes its own file. The command is passed
# encoded so that paths with spaces or quotes survive the hand-off.
$elevOut = Join-Path $OutDir "diagnose_${stamp}_elevated.txt"
# Killing the helper does not close its UAC prompt. If the user approves it after the timeout, this marker makes the
# late elevated process exit at once instead of running a second diagnostic.
$cancel = Join-Path $OutDir "uac_${stamp}_cancelled"
$q = { param($s) "'" + ($s -replace "'", "''") + "'" }
$cmd = "if (Test-Path -LiteralPath $(& $q $cancel)) { exit }; & $(& $q $diag) $(if ($CheckUpdates) { '-CheckUpdates' }) -JsonOut $(& $q $json) *>&1 | Out-File -LiteralPath $(& $q $elevOut) -Encoding utf8"
$enc = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($cmd))

# Start-Process -Verb RunAs blocks until the UAC prompt is answered and the prompt has no timeout of its own. A thread
# blocked in it keeps this process alive, so the prompt is raised from a helper process that can be killed on timeout.
# The helper writes "approved" or "denied: <reason>" to a status file, then "done" when the elevated run exits.
$status = Join-Path $OutDir "uac_$stamp.txt"
$helper = "try { `$p = Start-Process pwsh -Verb RunAs -PassThru -WindowStyle Hidden -ArgumentList '-NoProfile', '-ExecutionPolicy', 'Bypass', '-EncodedCommand', '$enc' -ErrorAction Stop } " +
	"catch { Set-Content -LiteralPath $(& $q $status) ('denied: ' + `$_.Exception.Message); exit } " +
	"Set-Content -LiteralPath $(& $q $status) 'approved'; `$p.WaitForExit(); Set-Content -LiteralPath $(& $q $status) 'done'"
$h = Start-Process pwsh -PassThru -WindowStyle Hidden -ArgumentList '-NoProfile', '-ExecutionPolicy', 'Bypass', '-EncodedCommand', ([Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($helper)))
$deadline = (Get-Date).AddSeconds($UacTimeoutSec)
# The helper may be mid-write, so a failed or empty read just means "no answer yet".
$read = { try { "$(Get-Content -LiteralPath $status -Raw -ErrorAction Stop)".Trim() } catch { '' } }
$state = ''
while (-not $state -and (Get-Date) -lt $deadline -and -not $h.HasExited) { Start-Sleep -Milliseconds 500; $state = & $read }
if (-not $state) { $state = & $read }
if (-not $state) {
	# Read the outcome before the kill below makes HasExited true.
	$outcome = if ($h.HasExited) { 'denied (the prompt could not be shown)' } else { "timed out after $UacTimeoutSec s" }
	Set-Content -LiteralPath $cancel ''
	Stop-Process -Id $h.Id -Force -ErrorAction SilentlyContinue
	Run-Standard $outcome
	return
}
# The full Windows error stays in the status file; the outcome goes into the report, so it is kept to one word.
if ($state -like 'denied*') { Run-Standard 'denied'; return }

if (-not $h.WaitForExit(600000)) { Run-Standard 'approved, but the elevated run did not finish within 10 min'; return }
if (-not (Test-Path -LiteralPath $elevOut) -or (Get-Content -LiteralPath $elevOut -TotalCount 1) -notmatch 'elevated: True') {
	Run-Standard 'approved, but the elevated run wrote no report'
	return
}
'elevation: approved'
"report: $elevOut"
