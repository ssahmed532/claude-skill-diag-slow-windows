# Builds the report artifact page from report-template.html and one run's report-data JSON.
# Run with:  pwsh -NoProfile -File build-report.ps1 -Data <report-data.json> -Out <report.html>
# The title is always "<device> Performance and Health Report", taken from the data's device field, so every run's
# artifact is named the same way. report-sample.json shows every field the template reads.
param([Parameter(Mandatory)][string]$Data, [Parameter(Mandatory)][string]$Out)

$ErrorActionPreference = 'Stop'
$json = Get-Content -LiteralPath $Data -Raw -Encoding utf8
$d = $json | ConvertFrom-Json
foreach ($k in 'device', 'windows', 'scanned', 'elevation', 'verdict', 'checks', 'findings') {
	if (-not $d.$k) { throw "report data is missing '$k'" }
}
$title = "$($d.device) Performance and Health Report"
# Every '<' becomes <, which is still valid JSON, so no data string can close the <script> block it sits in.
$html = (Get-Content -LiteralPath (Join-Path $PSScriptRoot 'report-template.html') -Raw -Encoding utf8).
	Replace('__REPORT_TITLE__', [Net.WebUtility]::HtmlEncode($title)).
	Replace('__REPORT_DATA__', $json.Replace('<', '<'))
[IO.File]::WriteAllText($Out, $html, [Text.UTF8Encoding]::new($false))
"title: $title"
"page: $Out"
