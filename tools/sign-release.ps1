<#
.SYNOPSIS
    Signs patch.ps1 with the maintainer RSA-4096 private key -> patch.ps1.sig.
.DESCRIPTION
    Reads .keys\private.xml, reads patch.ps1, normalizes CRLF -> LF (the canonical
    signed form), computes an RSA PKCS#1 v1.5 + SHA-256 signature, and writes the
    base64 signature to patch.ps1.sig.

    The same LF normalization is performed by install.ps1 and tools/verify-signature.ps1
    so a local working copy with CRLF still verifies identically to the raw bytes
    served by a Git host.

    After running:  git add patch.ps1 patch.ps1.sig
    Keep this script ASCII-only.
#>
$ErrorActionPreference = 'Stop'

$repoRoot  = Split-Path -Parent $PSScriptRoot
$privPath  = Join-Path $repoRoot '.keys\private.xml'
$patchPath = Join-Path $repoRoot 'patch.ps1'
$sigPath   = Join-Path $repoRoot 'patch.ps1.sig'

if (-not (Test-Path $privPath))  { Write-Host "No private key at $privPath. Run tools/generate-keypair.ps1 first." -ForegroundColor Red; exit 1 }
if (-not (Test-Path $patchPath)) { Write-Host "Missing patch.ps1." -ForegroundColor Red; exit 1 }

function Get-LfBytes([string]$Path) {
    $raw = [IO.File]::ReadAllBytes($Path)
    $out = New-Object System.Collections.Generic.List[byte]
    for ($i = 0; $i -lt $raw.Length; $i++) {
        if ($raw[$i] -eq 0x0D -and ($i + 1) -lt $raw.Length -and $raw[$i + 1] -eq 0x0A) { continue }
        $out.Add($raw[$i])
    }
    return $out.ToArray()
}

$rsa = [System.Security.Cryptography.RSA]::Create()
$rsa.FromXmlString([IO.File]::ReadAllText($privPath))

$bytes = Get-LfBytes $patchPath
$sig = $rsa.SignData(
    $bytes,
    [System.Security.Cryptography.HashAlgorithmName]::SHA256,
    [System.Security.Cryptography.RSASignaturePadding]::Pkcs1
)
$sigB64 = [Convert]::ToBase64String($sig)
[IO.File]::WriteAllText($sigPath, $sigB64, (New-Object System.Text.UTF8Encoding $false))
$rsa.Dispose()

Write-Host "Signed patch.ps1 ($($bytes.Length) LF-normalized bytes)." -ForegroundColor Green
Write-Host "Wrote signature: $sigPath" -ForegroundColor Green
Write-Host ""
Write-Host "Verify with: powershell -ExecutionPolicy Bypass -File tools\verify-signature.ps1" -ForegroundColor Yellow
