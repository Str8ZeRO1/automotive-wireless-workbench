<#
.SYNOPSIS
  One-shot setup: sets every GitHub Actions secret the ios-ci.yml workflow
  needs, then (optionally) triggers the workflow. Run this from the repo
  root on the Windows machine, with the GitHub CLI (`gh`) already
  authenticated (`gh auth login`).

.NOTES
  Nothing here is persisted to disk in plaintext longer than the life of
  this PowerShell session's variables; `gh secret set` sends values over
  TLS directly into GitHub's encrypted secret store.
#>

param(
    [Parameter(Mandatory = $true)] [string]$Repo,                 # e.g. "Str8ZeRO1/automotive-wireless-workbench"
    [Parameter(Mandatory = $true)] [string]$DevelopmentTeamId,
    [Parameter(Mandatory = $true)] [string]$AppStoreIssuerId,
    [Parameter(Mandatory = $true)] [string]$AppStoreKeyId,
    [Parameter(Mandatory = $true)] [string]$P8KeyPath,            # local path to the downloaded .p8 file
    [Parameter(Mandatory = $true)] [string]$MatchGitUrl,           # e.g. https://github.com/Str8ZeRO1/ios-certificates-private.git
    [Parameter(Mandatory = $true)] [string]$MatchGitHubUsername,
    [Parameter(Mandatory = $true)] [string]$MatchGitHubToken,       # PAT with repo scope on the certificates repo
    [Parameter(Mandatory = $true)] [string]$MatchPassword,
    [Parameter(Mandatory = $true)] [string[]]$DeviceUdids,
    [string[]]$DeviceNames = @("Jay's iPhone"),
    [switch]$TriggerBuild
)

$ErrorActionPreference = "Stop"

function Assert-GhCli {
    if (-not (Get-Command gh -ErrorAction SilentlyContinue)) {
        throw "GitHub CLI 'gh' not found on PATH. Install it from https://cli.github.com/ and run 'gh auth login' first."
    }
    gh auth status 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw "gh is installed but not authenticated. Run 'gh auth login' first."
    }
}

function Set-GhSecret {
    param([string]$Name, [string]$Value)
    Write-Host "Setting secret $Name..." -ForegroundColor Cyan
    $Value | gh secret set $Name --repo $Repo
}

Assert-GhCli

if (-not (Test-Path $P8KeyPath)) {
    throw "P8 key file not found at $P8KeyPath"
}
$p8Contents = Get-Content -Raw -Path $P8KeyPath

$basicAuthRaw = "$($MatchGitHubUsername):$($MatchGitHubToken)"
$basicAuthB64 = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($basicAuthRaw))

Set-GhSecret -Name "DEVELOPMENT_TEAM_ID" -Value $DevelopmentTeamId
Set-GhSecret -Name "APPSTORE_ISSUER_ID" -Value $AppStoreIssuerId
Set-GhSecret -Name "APPSTORE_KEY_ID" -Value $AppStoreKeyId
Set-GhSecret -Name "APPSTORE_P8_KEY" -Value $p8Contents
Set-GhSecret -Name "MATCH_GIT_URL" -Value $MatchGitUrl
Set-GhSecret -Name "MATCH_GIT_BASIC_AUTHORIZATION" -Value $basicAuthB64
Set-GhSecret -Name "MATCH_PASSWORD" -Value $MatchPassword
Set-GhSecret -Name "DEVICE_UDIDS" -Value ($DeviceUdids -join ",")
Set-GhSecret -Name "DEVICE_NAMES" -Value ($DeviceNames -join ",")

Write-Host "All secrets set on $Repo." -ForegroundColor Green

if ($TriggerBuild) {
    Write-Host "Triggering ios-ci.yml with device registration enabled (first run)..." -ForegroundColor Cyan
    gh workflow run ios-ci.yml --repo $Repo -f register_device=true
    Write-Host "Triggered. Watch it with: gh run watch --repo $Repo" -ForegroundColor Green
}
