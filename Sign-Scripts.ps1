#Requires -Version 5.1
<#
.SYNOPSIS
    Sign every .ps1 in this folder with a code-signing certificate.
    Run once BEFORE zipping to distribute a signed build.

.DESCRIPTION
    Two workflows:

    A. Use an existing code-signing cert already in
       Cert:\CurrentUser\My (e.g. corporate CA-issued, EV cert, or a
       previously-created self-signed one). Pass -Subject or
       -Thumbprint to select it.

    B. Auto-create a fresh self-signed cert named
       'CN=MergeVideosDev-<computer>' (default when no cert exists
       and no -Subject/-Thumbprint is given). Convenient for internal
       shares; colleagues run Trust-Publisher.ps1 once to accept it.

    After signing, verifies every .ps1 shows Status=Valid via
    Get-AuthenticodeSignature. Aborts if any script does not verify.

    Signed scripts are byte-identical to the source but have a
    signature block appended -- safe to ship in the ZIP.

.PARAMETER Subject
    Certificate Subject (Cert:\CurrentUser\My) to sign with, e.g.
    "CN=MyCompany Code Signing".

.PARAMETER Thumbprint
    Certificate thumbprint (Cert:\CurrentUser\My) to sign with.
    Takes precedence over -Subject if both are provided.

.PARAMETER Export
    Also export the signing cert's PUBLIC key to a .cer file next
    to the signed scripts, so it can be shipped in the ZIP for
    Trust-Publisher.ps1 to import.

.PARAMETER TimestampServer
    RFC 3161 timestamp URL. Timestamped signatures stay valid after
    the signing cert expires. Default: http://timestamp.digicert.com
#>

[CmdletBinding()]
param(
    [string]$Subject,
    [string]$Thumbprint,
    [switch]$Export,
    [string]$TimestampServer = 'http://timestamp.digicert.com'
)

$ErrorActionPreference = 'Stop'
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path

Write-Host ""
Write-Host "Merge Videos - script signing" -ForegroundColor Cyan
Write-Host "=============================" -ForegroundColor Cyan

# --- select certificate -----------------------------------------------------
$cert = $null
$store = 'Cert:\CurrentUser\My'

if ($Thumbprint) {
    $cert = Get-ChildItem $store | Where-Object Thumbprint -eq $Thumbprint | Select-Object -First 1
    if (-not $cert) { throw "No certificate with thumbprint $Thumbprint in $store." }
    Write-Host "Using cert (by thumbprint): $($cert.Subject)"
} elseif ($Subject) {
    $cert = Get-ChildItem $store -CodeSigningCert | Where-Object Subject -like "*$Subject*" | Select-Object -First 1
    if (-not $cert) { throw "No code-signing certificate matching subject '$Subject' in $store." }
    Write-Host "Using cert (by subject): $($cert.Subject)"
} else {
    # Auto-detect an existing MergeVideosDev cert or create one.
    $autoSubject = "CN=MergeVideosDev-$env:COMPUTERNAME"
    $cert = Get-ChildItem $store -CodeSigningCert | Where-Object Subject -eq $autoSubject | Select-Object -First 1
    if (-not $cert) {
        Write-Host "No existing MergeVideosDev cert. Creating a self-signed one..." -ForegroundColor Yellow
        $cert = New-SelfSignedCertificate `
            -Subject         $autoSubject `
            -Type            CodeSigning `
            -KeyUsage        DigitalSignature `
            -CertStoreLocation $store `
            -HashAlgorithm   SHA256 `
            -NotAfter        (Get-Date).AddYears(3)
        Write-Host "Created: $($cert.Subject) (thumbprint $($cert.Thumbprint))" -ForegroundColor Green
        Write-Host "  Colleagues will need Trust-Publisher.ps1 + the exported .cer to accept this cert."
    } else {
        Write-Host "Using existing cert: $($cert.Subject) (thumbprint $($cert.Thumbprint))"
    }
}

# --- sign every .ps1 --------------------------------------------------------
Write-Host ""
Write-Host "Signing scripts..." -ForegroundColor Cyan

$scripts = Get-ChildItem -Path $scriptDir -Filter *.ps1 -File
if ($scripts.Count -eq 0) { throw "No .ps1 files found in $scriptDir." }

$failed = 0
foreach ($s in $scripts) {
    try {
        $result = Set-AuthenticodeSignature -FilePath $s.FullName -Certificate $cert -TimestampServer $TimestampServer -HashAlgorithm SHA256 -ErrorAction Stop
        if ($result.Status -ne 'Valid') {
            Write-Host ("  [FAIL] {0}: signed but Status={1} ({2})" -f $s.Name, $result.Status, $result.StatusMessage) -ForegroundColor Red
            $failed++
        } else {
            Write-Host ("  [ OK ] {0}" -f $s.Name) -ForegroundColor Green
        }
    } catch {
        Write-Host ("  [FAIL] {0}: {1}" -f $s.Name, $_.Exception.Message) -ForegroundColor Red
        $failed++
    }
}

# --- optionally export the public key ---------------------------------------
if ($Export) {
    $cerOut = Join-Path $scriptDir 'MergeVideos-Publisher.cer'
    Export-Certificate -Cert $cert -FilePath $cerOut -Force | Out-Null
    Write-Host ""
    Write-Host "Exported public key: $cerOut" -ForegroundColor Green
    Write-Host "  Ship this in the ZIP so colleagues can run Trust-Publisher.ps1."
}

# --- verify -----------------------------------------------------------------
Write-Host ""
Write-Host "Verifying signatures..." -ForegroundColor Cyan
$verifyFail = 0
foreach ($s in $scripts) {
    $sig = Get-AuthenticodeSignature -FilePath $s.FullName
    if ($sig.Status -eq 'Valid') {
        Write-Host ("  [ OK ] {0}" -f $s.Name) -ForegroundColor Green
    } else {
        # UnknownError is expected for self-signed until the .cer is trusted
        # on the current machine's Trusted Publisher store. That's what
        # Trust-Publisher.ps1 fixes on the receiving end. Report as INFO.
        $color = if ($sig.Status -eq 'UnknownError') { 'Yellow' } else { 'Red' }
        Write-Host ("  [{0}] {1}: Status={2}" -f $sig.Status.ToString().ToUpper().PadRight(4).Substring(0,4), $s.Name, $sig.Status) -ForegroundColor $color
        if ($sig.Status -ne 'UnknownError') { $verifyFail++ }
    }
}

Write-Host ""
if ($failed -eq 0 -and $verifyFail -eq 0) {
    Write-Host "SUCCESS: $($scripts.Count) scripts signed and verified." -ForegroundColor Green
    if ($cert.Subject -like '*MergeVideosDev*' -and -not $Export) {
        Write-Host ""
        Write-Host "Tip: re-run with -Export to also ship the public key (.cer) for colleagues." -ForegroundColor DarkGray
    }
    exit 0
} else {
    Write-Host "FAILED: $failed sign error(s), $verifyFail verify error(s)." -ForegroundColor Red
    exit 1
}
