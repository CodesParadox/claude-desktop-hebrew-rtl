<#
.SYNOPSIS
    Assembles the renderer RTL payload from src/ and injects it into patch.ps1.
.DESCRIPTION
    Single source of truth for the injected JS is src/rtl-core.js (pure, tested)
    plus src/rtl-payload.js (DOM layer / IIFE). This script:
      1. Reads src/rtl-core.js and strips its module.exports guard.
      2. Inlines that core into src/rtl-payload.js at the /*__RTL_CORE__*/ marker.
      3. Validates the assembled blob with `node --check`.
      4. Replaces the region between the CLAUDE RTL PATCH START/END markers inside
         patch.ps1's $RTL_INJECTION_CODE here-string.
      5. Writes patch.ps1 back as UTF-8 (no BOM), LF line endings.

    After running this you MUST re-sign:  tools/sign-release.ps1
    then commit patch.ps1 + patch.ps1.sig together.

    NOTE: keep this script ASCII-only. Windows PowerShell 5.1 reads BOM-less .ps1
    files using the system ANSI code page; non-ASCII bytes corrupt parsing on
    Hebrew/RTL locales.
.NOTES
    Maintainer-only build tool. Run:  npm run build   (or directly).
#>
$ErrorActionPreference = 'Stop'

$repoRoot   = Split-Path -Parent $PSScriptRoot
$corePath   = Join-Path $repoRoot 'src\rtl-core.js'
$payPath    = Join-Path $repoRoot 'src\rtl-payload.js'
$patchPath  = Join-Path $repoRoot 'patch.ps1'

foreach ($p in @($corePath, $payPath, $patchPath)) {
    if (-not (Test-Path $p)) { Write-Host "Missing: $p" -ForegroundColor Red; exit 1 }
}

function Read-Lf([string]$path) {
    return ([IO.File]::ReadAllText($path)) -replace "`r`n", "`n"
}

$core = Read-Lf $corePath
$pay  = Read-Lf $payPath

# Strip the CommonJS export guard from the core (kept only for unit tests).
$guardIdx = $core.IndexOf("if (typeof module !==")
if ($guardIdx -ge 0) { $core = $core.Substring(0, $guardIdx).TrimEnd() + "`n" }

# Inline the core into the payload's placeholder.
$marker = '/*__RTL_CORE__*/'
if ($pay.IndexOf($marker) -lt 0) {
    Write-Host "Placeholder $marker not found in rtl-payload.js" -ForegroundColor Red; exit 1
}
$payInlined = $pay.Replace($marker, $core.TrimEnd("`n"))

# Wrap with the section markers expected inside patch.ps1.
$block = "// --- CLAUDE RTL PATCH START ---`n" + $payInlined.TrimEnd("`n") + "`n// --- CLAUDE RTL PATCH END ---"

# Validate syntax before touching patch.ps1. Keep the temp file inside the repo.
$tmp = Join-Path $repoRoot '.payload-check.tmp.js'
[IO.File]::WriteAllText($tmp, $payInlined, (New-Object System.Text.UTF8Encoding $false))
& node --check $tmp
$ok = $?
Remove-Item $tmp -Force -ErrorAction SilentlyContinue
if (-not $ok) { Write-Host "node --check failed - aborting, patch.ps1 untouched." -ForegroundColor Red; exit 1 }

# Splice the block into patch.ps1 between the markers (inclusive).
$patch = Read-Lf $patchPath
$pattern = '(?s)// --- CLAUDE RTL PATCH START ---.*?// --- CLAUDE RTL PATCH END ---'
if (-not [regex]::IsMatch($patch, $pattern)) {
    Write-Host "RTL PATCH markers not found in patch.ps1" -ForegroundColor Red; exit 1
}
# MatchEvaluator so '$' in the JS is not interpreted as a replacement token.
$evaluator = [System.Text.RegularExpressions.MatchEvaluator] { param($m) $block }
$updated = [regex]::Replace($patch, $pattern, $evaluator, [System.Text.RegularExpressions.RegexOptions]::Singleline)

# Sanity guard: never write a suspiciously small file.
if ($updated.Length -lt ($patch.Length / 2)) {
    Write-Host "SANITY FAIL: assembled file too short ($($updated.Length) chars) - aborting." -ForegroundColor Red
    exit 1
}

if ($updated -eq $patch) {
    Write-Host "Payload unchanged - patch.ps1 already up to date." -ForegroundColor Yellow
} else {
    [IO.File]::WriteAllText($patchPath, $updated, (New-Object System.Text.UTF8Encoding $false))
    $written = [IO.File]::ReadAllBytes($patchPath).Length
    Write-Host "Injected payload into patch.ps1 (block $($block.Length) chars; file now $written bytes)." -ForegroundColor Green
}

Write-Host ""
Write-Host "NEXT: re-sign and commit:" -ForegroundColor Yellow
Write-Host "  tools/sign-release.ps1"
Write-Host "  git add patch.ps1 patch.ps1.sig"
