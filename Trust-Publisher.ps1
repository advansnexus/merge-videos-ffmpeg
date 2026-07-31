#Requires -Version 5.1
<#
.SYNOPSIS
    Add the Merge Videos publisher certificate to CurrentUser trusted
    stores so signed scripts run without prompting under RemoteSigned
    or AllSigned execution policy.

.DESCRIPTION
    Reads MergeVideos-Publisher.cer from this script's folder (or a
    -CerPath you supply) and imports it into:
        Cert:\CurrentUser\Root                (Trusted Root CA)
        Cert:\CurrentUser\TrustedPublisher    (Trusted Publisher)

    No admin required -- both stores are per-user.

    ONE-TIME operation per receiving machine. After running this,
    Windows will trust anything signed with the shipping cert without
    prompting.

.PARAMETER CerPath
    Path to the publisher .cer file. Defaults to
    "$PSScriptRoot\MergeVideos-Publisher.cer".

.PARAMETER Untrust
    Reverse the operation: remove the shipping cert from both stores.
#>

[CmdletBinding()]
param(
    [string]$CerPath,
    [switch]$Untrust
)

$ErrorActionPreference = 'Stop'
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
if (-not $CerPath) { $CerPath = Join-Path $scriptDir 'MergeVideos-Publisher.cer' }

Write-Host ""
Write-Host "Merge Videos - publisher trust helper" -ForegroundColor Cyan
Write-Host "=====================================" -ForegroundColor Cyan
Write-Host ""

if (-not (Test-Path $CerPath)) {
    Write-Host "ERROR: certificate file not found: $CerPath" -ForegroundColor Red
    Write-Host "This ZIP does not ship a publisher cert (unsigned build), so there is nothing to trust." -ForegroundColor DarkGray
    exit 1
}

# Read the cert (do not import yet; just extract the subject/thumb for reporting).
$cert = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2 $CerPath
Write-Host "Certificate:"
Write-Host "  Subject    : $($cert.Subject)"
Write-Host "  Issuer     : $($cert.Issuer)"
Write-Host "  Thumbprint : $($cert.Thumbprint)"
Write-Host "  NotAfter   : $($cert.NotAfter)"
Write-Host ""

$stores = @('Cert:\CurrentUser\Root', 'Cert:\CurrentUser\TrustedPublisher')

if ($Untrust) {
    $removed = 0
    foreach ($s in $stores) {
        $existing = Get-ChildItem $s | Where-Object Thumbprint -eq $cert.Thumbprint | Select-Object -First 1
        if ($existing) {
            Remove-Item -Path $existing.PSPath -Force
            Write-Host "  Removed from $s" -ForegroundColor Green
            $removed++
        } else {
            Write-Host "  Not present in $s (nothing to do)" -ForegroundColor DarkGray
        }
    }
    Write-Host ""
    Write-Host "Done. Removed cert from $removed store(s)." -ForegroundColor Green
    exit 0
}

foreach ($s in $stores) {
    try {
        $existing = Get-ChildItem $s | Where-Object Thumbprint -eq $cert.Thumbprint | Select-Object -First 1
        if ($existing) {
            Write-Host "  Already trusted in $s" -ForegroundColor DarkGray
        } else {
            Import-Certificate -FilePath $CerPath -CertStoreLocation $s | Out-Null
            Write-Host "  Imported into $s" -ForegroundColor Green
        }
    } catch {
        Write-Host "  FAIL importing into $s : $($_.Exception.Message)" -ForegroundColor Red
    }
}

Write-Host ""
Write-Host "Done. Signed Merge Videos scripts will now run without prompting." -ForegroundColor Green
Write-Host "To reverse this, run: Trust-Publisher.ps1 -Untrust" -ForegroundColor DarkGray
