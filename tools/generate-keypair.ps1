<#
.SYNOPSIS
    Generates the maintainer RSA-4096 signing keypair (one-time, local only).
.DESCRIPTION
    Creates a fresh RSA-4096 keypair and:
      - writes the PRIVATE key to .keys\private.xml  (gitignored, NEVER commit),
      - embeds the PUBLIC key (base64 JSON {Modulus, Exponent}) into install.ps1
        by replacing the $ExpectedPubKey placeholder,
      - prints the public-key fingerprint (SHA-256) to publish in the README.

    The private key never leaves this machine and is never committed. install.ps1
    carries only the public key, so a compromised repo alone cannot ship malicious
    code: an attacker would also need this offline private key.

    Re-running OVERWRITES the existing private key and rotates trust. After running
    you MUST re-sign:  tools/sign-release.ps1

    Keep this script ASCII-only (BOM-less .ps1 + Hebrew-locale PS 5.1 safety).
#>
$ErrorActionPreference = 'Stop'

$repoRoot    = Split-Path -Parent $PSScriptRoot
$keyDir      = Join-Path $repoRoot '.keys'
$privPath    = Join-Path $keyDir 'private.xml'
$installPath = Join-Path $repoRoot 'install.ps1'

if (-not (Test-Path $installPath)) { Write-Host "Missing install.ps1 at $installPath" -ForegroundColor Red; exit 1 }

if (Test-Path $privPath) {
    Write-Host "A private key already exists at $privPath" -ForegroundColor Yellow
    $ans = Read-Host "Overwrite and ROTATE the signing key? [y/N]"
    if ($ans -ne 'y') { Write-Host "Aborted; existing key kept." -ForegroundColor Cyan; exit 0 }
}

if (-not (Test-Path $keyDir)) { New-Item -ItemType Directory -Path $keyDir -Force | Out-Null }

Write-Host "Generating RSA-4096 keypair..." -ForegroundColor Cyan
$rsa = [System.Security.Cryptography.RSA]::Create(4096)

# Persist the private key locally (full key material).
$privXml = $rsa.ToXmlString($true)
[IO.File]::WriteAllText($privPath, $privXml, (New-Object System.Text.UTF8Encoding $false))
Write-Host "Private key written: $privPath  (gitignored -- do NOT commit)" -ForegroundColor Green

# Build the public-key blob: base64( JSON{ Modulus, Exponent } ).
$pub = $rsa.ExportParameters($false)
$pubObj = [pscustomobject]@{
    Modulus  = [Convert]::ToBase64String($pub.Modulus)
    Exponent = [Convert]::ToBase64String($pub.Exponent)
}
$pubJson = $pubObj | ConvertTo-Json -Compress
$blob = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($pubJson))

# Fingerprint = SHA-256 over the base64 blob bytes (matches README cross-check).
$sha = [System.Security.Cryptography.SHA256]::Create()
$fp = ($sha.ComputeHash([Text.Encoding]::ASCII.GetBytes($blob)) | ForEach-Object { $_.ToString('x2') }) -join ':'

# Embed the public key into install.ps1 (replace the placeholder/previous value).
$install = [IO.File]::ReadAllText($installPath)
$pattern = '(?m)^\s*\$ExpectedPubKey\s*=\s*''.*?''\s*$'
$replacement = "`$ExpectedPubKey = '$blob'"
if ([regex]::IsMatch($install, $pattern)) {
    $evaluator = [System.Text.RegularExpressions.MatchEvaluator] { param($m) $replacement }
    $install = [regex]::Replace($install, $pattern, $evaluator)
} else {
    Write-Host "Could not find an \$ExpectedPubKey line in install.ps1 to replace." -ForegroundColor Red
    exit 1
}
[IO.File]::WriteAllText($installPath, $install, (New-Object System.Text.UTF8Encoding $false))
Write-Host "Embedded public key into install.ps1." -ForegroundColor Green

$rsa.Dispose()

Write-Host ""
Write-Host "Public-key fingerprint (publish this in README):" -ForegroundColor Yellow
Write-Host "  $fp" -ForegroundColor White
Write-Host ""
Write-Host "NEXT: sign the patch and commit:" -ForegroundColor Yellow
Write-Host "  tools/sign-release.ps1"
Write-Host "  git add install.ps1 patch.ps1.sig"
