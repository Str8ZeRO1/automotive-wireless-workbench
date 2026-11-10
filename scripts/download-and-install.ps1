<#
.SYNOPSIS
  Downloads the latest signed AutomotiveDash.ipa artifact from the most
  recent successful ios-ci.yml run, then uploads it to Diawi for an
  OTA install link you open on the iPhone itself (Settings/Safari can't
  install .ipa files directly on Windows -- this is the standard
  no-Mac-needed install path for an already-signed ad-hoc build).

.PARAMETER DiawiToken
  Free API token from https://www.diawi.com/doc (sign up, "API Access").
#>

param(
    [Parameter(Mandatory = $true)] [string]$Repo,
    [Parameter(Mandatory = $true)] [string]$DiawiToken,
    [string]$OutDir = "$PWD\build"
)

$ErrorActionPreference = "Stop"

if (-not (Get-Command gh -ErrorAction SilentlyContinue)) {
    throw "GitHub CLI 'gh' not found. Install from https://cli.github.com/"
}

New-Item -ItemType Directory -Force -Path $OutDir | Out-Null

Write-Host "Finding latest successful ios-ci.yml run..." -ForegroundColor Cyan
$runId = gh run list --repo $Repo --workflow ios-ci.yml --status success --limit 1 --json databaseId -q ".[0].databaseId"
if (-not $runId) {
    throw "No successful ios-ci.yml run found. Trigger one first: gh workflow run ios-ci.yml --repo $Repo"
}

Write-Host "Downloading artifact from run $runId..." -ForegroundColor Cyan
gh run download $runId --repo $Repo --name "AutomotiveDash-adhoc" --dir $OutDir

$ipaPath = Join-Path $OutDir "AutomotiveDash.ipa"
if (-not (Test-Path $ipaPath)) {
    throw "Expected IPA not found at $ipaPath after download."
}

Write-Host "Uploading $ipaPath to Diawi for an OTA install link..." -ForegroundColor Cyan
$response = curl.exe -s -F "token=$DiawiToken" -F "file=@$ipaPath" -F "find_method=1" https://upload.diawi.com/ | ConvertFrom-Json

if (-not $response.job) {
    throw "Diawi upload failed: $($response | ConvertTo-Json -Compress)"
}

Write-Host "Diawi job queued, polling for the install link..." -ForegroundColor Cyan
do {
    Start-Sleep -Seconds 3
    $status = curl.exe -s "https://upload.diawi.com/status?token=$DiawiToken&job=$($response.job)" | ConvertFrom-Json
} while ($status.status -eq "2001")

if ($status.status -ne "2000") {
    throw "Diawi processing failed: $($status | ConvertTo-Json -Compress)"
}

Write-Host ""
Write-Host "Install link (open this in Safari ON THE IPHONE, not on this PC):" -ForegroundColor Green
Write-Host $status.link -ForegroundColor Yellow
Write-Host ""
Write-Host "QR code: $($status.qrcode)" -ForegroundColor Green
