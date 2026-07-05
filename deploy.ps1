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
    [switch]$ResumeHostingOnly,
    [switch]$SkipGit,
    [string]$Message = ""
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$root     = $PSScriptRoot
$appDir   = Join-Path $root "kass_dalle"
$releaseWeb   = Join-Path $root "Release\web"
$releaseMobile = Join-Path $root "Release\mobile"

function Invoke-FirebaseFunctionsDeployWithRetry {
    param(
        [string]$FunctionsDir
    )

    $logFile = Join-Path $env:TEMP ("kassdalle-functions-deploy-{0}.log" -f ([guid]::NewGuid().ToString("N")))
    try {
        & firebase deploy --only functions 2>&1 | Tee-Object -FilePath $logFile
        if ($LASTEXITCODE -eq 0) { return }

        $failedFunctions = @(
            Select-String -Path $logFile -Pattern "Failed to update function ([A-Za-z0-9_]+) in region" -AllMatches |
                ForEach-Object { $_.Matches } |
                ForEach-Object { $_.Groups[1].Value }
        ) | Sort-Object -Unique

        if ($failedFunctions.Count -eq 0) {
            throw "firebase deploy functions a échoué sans fonction identifiable à relancer"
        }

        Write-Host "Relance ciblée des fonctions en échec : $($failedFunctions -join ', ')" -ForegroundColor Yellow

        foreach ($fn in $failedFunctions) {
            Write-Host " - Retry functions:$fn" -ForegroundColor DarkYellow
            & firebase deploy --only "functions:$fn"
            if ($LASTEXITCODE -ne 0) {
                throw "Relance ciblée échouée pour la fonction $fn"
            }
        }
    } finally {
        Remove-Item $logFile -Force -ErrorAction SilentlyContinue
    }
}

# ── 0. Clé Gemini ──────────────────────────────────────────────────────────────
# La clé Gemini n'est plus passée côté client : elle est gérée par Secret Manager
# côté Cloud Functions (secret GEMINI_API_KEY). Voir functions/src/gemini/*.

Push-Location $appDir
try {
    # ── 0b. Sync app_version.dart avec pubspec.yaml ────────────────────────────
    $pubspecVersion = (Get-Content "$appDir\pubspec.yaml" | Where-Object { $_ -match "^version:" }) -replace "^version:\s*", "" -replace "\+.*", ""
    $appVersionFile = "$appDir\lib\core\app_version.dart"
    (Get-Content $appVersionFile) -replace "const String kAppVersion = '.*';", "const String kAppVersion = '$pubspecVersion';" | Set-Content $appVersionFile
    Write-Host "app_version.dart mis à jour → $pubspecVersion" -ForegroundColor DarkGray

    # ── 1. Build Web ───────────────────────────────────────────────────────────
    Write-Host "`n[1/5] flutter build web..." -ForegroundColor Cyan
    flutter build web --release --no-tree-shake-icons
    if ($LASTEXITCODE -ne 0) { throw "flutter build web a échoué" }

    # ── 2. Build APK (sauf -WebOnly) ───────────────────────────────────────────
    if (-not $WebOnly) {
        Write-Host "`n[2/5] flutter build apk..." -ForegroundColor Cyan
        flutter build apk --release
        if ($LASTEXITCODE -ne 0) { throw "flutter build apk a échoué" }

        # Copier l'APK dans build/web pour le lien de téléchargement du site
        $apkBuilt = "$appDir\build\app\outputs\flutter-apk\app-release.apk"
        if (Test-Path $apkBuilt) {
            Copy-Item $apkBuilt "$appDir\build\web\app-release.apk" -Force
            Write-Host "APK copié dans build/web" -ForegroundColor DarkGray
        }
    } else {
        Write-Host "`n[2/5] APK ignoré (-WebOnly)" -ForegroundColor DarkGray
    }

    # ── 3. Firebase deploy (functions puis hosting/firestore/storage) ─────────
    if (-not $ResumeHostingOnly) {
        Write-Host "`n[3/5] firebase deploy (functions)..." -ForegroundColor Cyan
        Invoke-FirebaseFunctionsDeployWithRetry -FunctionsDir $appDir

        Write-Host "`n[3b/5] firebase deploy (hosting + firestore + storage)..." -ForegroundColor Cyan
        firebase deploy --only hosting,firestore,storage
        if ($LASTEXITCODE -ne 0) { throw "firebase deploy hosting/firestore/storage a échoué" }
    } else {
        Write-Host "`n[3/5] reprise ciblée: firebase deploy (hosting)..." -ForegroundColor Cyan
        firebase deploy --only hosting
        if ($LASTEXITCODE -ne 0) { throw "firebase deploy hosting a échoué" }
    }

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
        # Copie vers Google Drive
        $gdrive = "G:\Mon Drive\Kass'Dalle\app-release.apk"
        try {
            Copy-Item $apkSrc $gdrive -Force
            Write-Host "APK copié dans Google Drive" -ForegroundColor DarkGray
        } catch {
            Write-Host "Google Drive non disponible, copie ignorée" -ForegroundColor DarkYellow
        }
    }
}

# ── 5. Git commit + push ────────────────────────────────────────────────────────
if (-not $SkipGit) {
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
} else {
    Write-Host "`n[5/5] git commit + push ignorés (-SkipGit)" -ForegroundColor DarkGray
}

$version = (Get-Content "$appDir\pubspec.yaml" | Where-Object { $_ -match "^version:" }) -replace "^version:\s*", "" -replace "\+.*", ""
$heure = Get-Date -Format 'HH:mm:ss'
Write-Host "`nDéployé Version $version à $heure avec succès !" -ForegroundColor Green
