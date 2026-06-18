<#
    Claude Desktop Hebrew RTL patch -- verified installer / bootstrap.

    Resolves patch.ps1 + patch.ps1.sig (preferring local files next to this
    script, otherwise downloading from $RepoBase), verifies an RSA-4096 signature
    over the exact LF-normalized bytes against the public key embedded below, then
    self-elevates (UAC) and runs the verified patch.ps1.

    A compromised repository alone is NOT enough to ship malicious code -- the
    attacker would also need the maintainer's offline private key.

    Public-key fingerprint (SHA-256 over the embedded base64 blob) is published in
    the README; cross-check it before trusting a fresh install.

    Keep this file ASCII-only so it parses under Windows PowerShell 5.1 regardless
    of locale (it is run via `irm ... | iex`).
#>

# Populated by tools/generate-keypair.ps1. '__PUBKEY__' means "not yet generated".
$ExpectedPubKey = 'eyJNb2R1bHVzIjoiM2g4R1Vxa05qSitWdlJVRTc3VzN5b3Jrbmd3SzVEZ2JJVE9hZmUvMGFUVUtVWkFxN0gwRVkzMUlCblM3MWZuTHYvaGZhOUZ2d3BFRS9oSFB6T3VCd1J5NmU0TEtsUTVYREFBMWEwd3lFVTlPeCtnT1MxTktpZlUrdEZta1Bzd01qb3d5ZlQ4TlpTVWFKYllRU0xEUXVybWUzdk9rWmJxbXd5RWJYbVZuWGdhSmllV1Vjb3hPRVBBbVA2RnRmdytBMGtUVVF5Z3dJVmcwaTZnam4vZk16NW1RL2krV1A2cllGOHpydHFyQWpEa3JWdFZBZGY3UUxoYzVMaG5Yd0luazZaMktuRHorbytPM21xOFJpbnptVXk4Y0RGakFlTXBMWk9MeVROQkYyOUdIMVc1bE1IZXNYQy9FaDdWekJ2NUh0TlhSZzA1a054OUJJTCsvTTlyWjQrOTU4NENwaHF3SzFpRkZ4WmoxU0NMM244STBEL0s0OUxtWG1mNzNpd0crd3o2a25xOGpidFgvbW5yYkZLbUsveXJMYkFaY2JpRDZNMkh5bjU2R0RmWVlkb3Uwb05QeWlBaW9YdG9CNWxlenhNdkVHMDBOSHkvMmo1MGZubjlVbnJEbGFmUkdqU0F5WStscUQ2UlpqTktpZkU0UTNWZjlSb2h1bDVDR3hIUjFFSlJsVjBlb2VqNEFnc2V6OHA3YWdrNzVlQ1NYbVpTU0N1NnRLemRLalVUR1lZK3RDajdkREY4N0hjM2Z0LzlhaVFmWldWUDF2ZTVCMTJBVHNNUFNteGdQVy82cURMTUx1L2ozRDJNK21UR2ZqUmlJTXJ5UVdHcGZtSEVmMTBYT0Q4b2hvQU1NV1NkVWt1aTZISVdIS214OGhoZmtmc2ZudFdzUzBudXNybkU9IiwiRXhwb25lbnQiOiJBUUFCIn0='
# Local files (next to this script) win over $RepoBase when present.
$RepoBase = 'https://raw.githubusercontent.com/CodesParadox/claude-desktop-hebrew-rtl/main'
$TmpFile  = Join-Path $env:TEMP 'claude_hebrew_rtl_patch.ps1'

# PS 5.1 defaults to TLS 1.0; modern Git hosts require 1.2+.
try {
    [Net.ServicePointManager]::SecurityProtocol =
        [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
} catch { }

if ($ExpectedPubKey -eq '__PUBKEY__') {
    Write-Host ""
    Write-Host "This installer has no embedded public key yet." -ForegroundColor Red
    Write-Host "Maintainer: run tools\generate-keypair.ps1 then tools\sign-release.ps1." -ForegroundColor Yellow
    return
}

$scriptDir   = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }
$localPatch  = Join-Path $scriptDir 'patch.ps1'
$localSig    = Join-Path $scriptDir 'patch.ps1.sig'

# --- Acquire patch bytes + signature (local-first, then network). ---
$patchBytes = $null
$sigB64     = $null
if ((Test-Path $localPatch) -and (Test-Path $localSig)) {
    Write-Host "Using local patch.ps1 + signature from $scriptDir" -ForegroundColor Cyan
    $patchBytes = [IO.File]::ReadAllBytes($localPatch)
    $sigB64     = (Get-Content $localSig -Raw).Trim()
} else {
    $client = New-Object System.Net.WebClient
    try {
        # Raw bytes (not Invoke-RestMethod, which would normalize the BOM).
        $patchBytes = $client.DownloadData("$RepoBase/patch.ps1")
        $sigB64     = $client.DownloadString("$RepoBase/patch.ps1.sig").Trim()
    } catch {
        Write-Host ""
        Write-Host "Network error downloading patch: $($_.Exception.Message)" -ForegroundColor Red
        Write-Host "Check connectivity and retry." -ForegroundColor Yellow
        return
    }
}

# --- LF-normalize (matches tools/sign-release.ps1). ---
function ConvertTo-Lf([byte[]]$raw) {
    $out = New-Object System.Collections.Generic.List[byte]
    for ($i = 0; $i -lt $raw.Length; $i++) {
        if ($raw[$i] -eq 0x0D -and ($i + 1) -lt $raw.Length -and $raw[$i + 1] -eq 0x0A) { continue }
        $out.Add($raw[$i])
    }
    return $out.ToArray()
}
$verifyBytes = ConvertTo-Lf $patchBytes

# --- Import embedded public key. ---
try {
    $pubJson = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($ExpectedPubKey))
    $pubObj  = $pubJson | ConvertFrom-Json
    $params = New-Object System.Security.Cryptography.RSAParameters
    $params.Modulus  = [Convert]::FromBase64String($pubObj.Modulus)
    $params.Exponent = [Convert]::FromBase64String($pubObj.Exponent)
    $rsa = [System.Security.Cryptography.RSA]::Create()
    $rsa.ImportParameters($params)
} catch {
    Write-Host "Internal error: embedded public key is malformed ($($_.Exception.Message))." -ForegroundColor Red
    Write-Host "Do NOT proceed -- install.ps1 itself may have been tampered with." -ForegroundColor Red
    return
}

try {
    $sigBytes = [Convert]::FromBase64String($sigB64)
} catch {
    Write-Host "Signature is not valid base64. Aborting." -ForegroundColor Red
    return
}

$valid = $rsa.VerifyData(
    $verifyBytes, $sigBytes,
    [System.Security.Cryptography.HashAlgorithmName]::SHA256,
    [System.Security.Cryptography.RSASignaturePadding]::Pkcs1
)

if (-not $valid) {
    Write-Host ""
    Write-Host "================================================================" -ForegroundColor Red
    Write-Host "  SIGNATURE VERIFICATION FAILED -- REFUSING TO RUN patch.ps1     " -ForegroundColor Red
    Write-Host "================================================================" -ForegroundColor Red
    Write-Host ""
    Write-Host "The patch does not match the maintainer's signature." -ForegroundColor Yellow
    Write-Host "Possible causes: tampered repo, intercepting proxy, or an unsigned push." -ForegroundColor Yellow
    Write-Host "Cross-check the public-key fingerprint in the README before retrying." -ForegroundColor Cyan
    return
}

# Materialize the verified patch with a UTF-8 BOM so PS 5.1 parses any non-ASCII
# content correctly on a Hebrew-locale system.
$content = [Text.Encoding]::UTF8.GetString($verifyBytes)
if ($content.Length -gt 0 -and $content[0] -eq [char]0xFEFF) { $content = $content.Substring(1) }
[IO.File]::WriteAllText($TmpFile, $content, (New-Object System.Text.UTF8Encoding $true))

Write-Host "Patch verified ($($verifyBytes.Length) bytes). Elevating..." -ForegroundColor Green

# Pass the verified public-key blob to the elevated child as a PARAMETER (env vars
# do not survive the RunAs boundary) so the auto-repatch watcher pins the same
# trust anchor without a re-download TOCTOU window.
Start-Process -FilePath PowerShell.exe -Verb RunAs -ArgumentList @(
    '-NoProfile', '-NoExit', '-ExecutionPolicy', 'Bypass',
    '-File', "`"$TmpFile`"",
    '-TrustedPubKey', "`"$ExpectedPubKey`""
)
