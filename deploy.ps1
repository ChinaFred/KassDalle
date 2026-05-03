<#
.SYNOPSIS
    Déploie KassDalle : build web + APK Android, Firebase hosting, Release/, git push.

.PARAMETER WebOnly
    Ne compile et déploie que le web (pas l'APK).

.PARAMETER Message
    Message de commit git. Par défaut : "deploy: <date>"

.EXAMPLE
    .\deploy.ps1
    .\deploy.ps1 -WebOnly
    .\deploy.ps1 -Message "fix: correction affichage"
#>
param(
    [switch]$WebOnly,
    [string]$Message = ""
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$root     = $PSScriptRoot
$appDir   = Join-Path $root "kass_dalle"
$envFile  = Join-Path $appDir ".env"
$releaseWeb   = Join-Path $root "Release\web"
$releaseMobile = Join-Path $root "Release\mobile"

# ── 0. Clé Gemini ──────────────────────────────────────────────────────────────
if (-not (Test-Path $envFile)) {
    Write-Error "Fichier .env introuvable : $envFile"
    exit 1
}
$geminiKey = (Get-Content $envFile | Where-Object { $_ -match "^GEMINI_API_KEY=" }) -replace "^GEMINI_API_KEY=", ""
if ([string]::IsNullOrWhiteSpace($geminiKey)) {
    Write-Error "GEMINI_API_KEY vide dans .env"
    exit 1
}

Push-Location $appDir
try {
    # ── 1. Build Web ───────────────────────────────────────────────────────────
    Write-Host "`n[1/5] flutter build web..." -ForegroundColor Cyan
    flutter build web --release --dart-define=GEMINI_API_KEY=$geminiKey
    if ($LASTEXITCODE -ne 0) { throw "flutter build web a échoué" }

    # ── 2. Build APK (sauf -WebOnly) ───────────────────────────────────────────
    if (-not $WebOnly) {
        Write-Host "`n[2/5] flutter build apk..." -ForegroundColor Cyan
        flutter build apk --release --dart-define=GEMINI_API_KEY=$geminiKey
        if ($LASTEXITCODE -ne 0) { throw "flutter build apk a échoué" }
    } else {
        Write-Host "`n[2/5] APK ignoré (-WebOnly)" -ForegroundColor DarkGray
    }

    # ── 3. Firebase deploy (hosting + firestore indexes) ───────────────────────
    Write-Host "`n[3/5] firebase deploy..." -ForegroundColor Cyan
    firebase deploy --only hosting,firestore:indexes,storage
    if ($LASTEXITCODE -ne 0) { throw "firebase deploy a échoué" }

} finally {
    Pop-Location
}

# ── 4. Copie dans Release/ ─────────────────────────────────────────────────────
Write-Host "`n[4/5] Copie dans Release/..." -ForegroundColor Cyan
Remove-Item "$releaseWeb\*" -Recurse -Force -ErrorAction SilentlyContinue
Copy-Item -Recurse -Force "$appDir\build\web\*" "$releaseWeb\"

if (-not $WebOnly) {
    $apkSrc = "$appDir\build\app\outputs\flutter-apk\app-release.apk"
    if (Test-Path $apkSrc) {
        Copy-Item $apkSrc "$releaseMobile\app-release.apk" -Force
    }
}

# ── 5. Git commit + push ────────────────────────────────────────────────────────
Write-Host "`n[5/5] git commit + push..." -ForegroundColor Cyan
Push-Location $root
try {
    git add -A
    $commitMsg = if ($Message) { $Message } else { "deploy: $(Get-Date -Format 'yyyy-MM-dd HH:mm')" }
    git commit -m $commitMsg
    git push
} finally {
    Pop-Location
}

$version = (Get-Content "$appDir\pubspec.yaml" | Where-Object { $_ -match "^version:" }) -replace "^version:\s*", "" -replace "\+.*", ""
$heure = Get-Date -Format 'HH:mm:ss'
Write-Host "`nDéployé Version $version à $heure avec succès !" -ForegroundColor Green
