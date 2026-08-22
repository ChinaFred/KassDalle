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

function Invoke-FirebaseDeployVerified {
    param(
        [Parameter(Mandatory = $true)][string]$Targets
    )

    # Même défiance que pour les fonctions : un code 0 ne prouve pas qu'on a
    # déployé. Seule la ligne « Deploy complete! » le dit, et sans elle le
    # script annoncerait une mise en ligne qui n'a pas eu lieu.
    $logFile = Join-Path $env:TEMP ("kassdalle-deploy-{0}.log" -f ([guid]::NewGuid().ToString("N")))
    try {
        & firebase deploy --only $Targets *> $logFile
        $exitCode = $LASTEXITCODE
        Get-Content $logFile | Write-Output
        $completed = (Select-String -Path $logFile -Pattern "Deploy complete" -Quiet) -eq $true
        if ($exitCode -ne 0) { throw "firebase deploy $Targets a echoue (exit $exitCode)" }
        if (-not $completed) {
            throw "firebase deploy $Targets a rendu 0 sans deployer (pas de « Deploy complete »)"
        }
    } finally {
        Remove-Item $logFile -Force -ErrorAction SilentlyContinue
    }
}

function Invoke-FirebaseFunctionsDeployWithRetry {
    param(
        [string]$FunctionsDir
    )

    # Budget de DÉCOUVERTE des fonctions, distinct du démarrage à froid.
    #
    # Avant de déployer, la CLI charge le bundle dans un processus à part pour
    # savoir quelles fonctions il déclare. Ce chargement a dix secondes par
    # défaut — et la première tentative les dépassait à chaque déploiement,
    # invariablement suivie d'une relance qui, elle, passait. La différence
    # entre les deux n'est pas le code : ce sont les cinquante fichiers que
    # « tsc » vient de réécrire, encore froids sur le disque et inspectés par
    # l'antivirus au premier accès.
    #
    # Le retard était donc dans l'attente, pas dans le programme. On l'allonge
    # au lieu de faire semblant de ne pas le voir : un échec systématique que
    # l'on rattrape par une relance finit par masquer le jour où l'échec est
    # réel.
    $env:FUNCTIONS_DISCOVERY_TIMEOUT = "120"

    # Le code de sortie NE SUFFIT PAS, et c'est le vrai piège de ce script.
    #
    # La CLI s'arrête parfois après « Loading and analyzing source code », sans
    # déployer une seule fonction, et rend malgré tout 0. Le script concluait au
    # succès, passait au hosting, et annonçait « déployé avec succès » : le web
    # partait avec un serveur resté à la version précédente. Trois fois dans une
    # même soirée, dont deux repérées seulement parce qu'une fonction attendue
    # ne répondait pas.
    #
    # On vérifie donc le RÉSULTAT et non le code de retour : la CLI écrit
    # « Deploy complete! » quand elle a fini son travail, et rien d'autre ne le
    # dit. Sans cette ligne, l'appel est traité comme un échec — quitte à
    # relancer pour rien, ce qui coûte une minute là où le silence coûtait une
    # version.
    $firstLog = Join-Path $env:TEMP ("kassdalle-functions-first-{0}.log" -f ([guid]::NewGuid().ToString("N")))
    try {
        & firebase deploy --only functions *> $firstLog
        $firstExitCode = $LASTEXITCODE
        Get-Content $firstLog | Write-Output
        $firstCompleted = (Select-String -Path $firstLog -Pattern "Deploy complete" -Quiet) -eq $true
        if ($firstExitCode -eq 0 -and $firstCompleted) { return }

        if ($firstExitCode -eq 0 -and -not $firstCompleted) {
            Write-Host "La CLI a rendu 0 SANS déployer (pas de « Deploy complete »). Relance." -ForegroundColor Yellow
        }
    } finally {
        Remove-Item $firstLog -Force -ErrorAction SilentlyContinue
    }

    # Échec réel — relancer en capturant la sortie pour identifier les fonctions en erreur
    Write-Host "Première tentative échouée (exit $LASTEXITCODE), relance avec capture..." -ForegroundColor Yellow
    $logFile = Join-Path $env:TEMP ("kassdalle-functions-deploy-{0}.log" -f ([guid]::NewGuid().ToString("N")))
    try {
        & firebase deploy --only functions *> $logFile
        $retryExitCode = $LASTEXITCODE
        Get-Content $logFile | Write-Output
        $retryCompleted = (Select-String -Path $logFile -Pattern "Deploy complete" -Quiet) -eq $true
        if ($retryExitCode -eq 0 -and $retryCompleted) { return }
        if ($retryExitCode -eq 0 -and -not $retryCompleted) {
            throw "firebase deploy functions a rendu 0 sans rien deployer, deux fois de suite"
        }

        $failedFunctions = @(
            Select-String -Path $logFile -Pattern "Failed to update function ([A-Za-z0-9_]+) in region" -AllMatches |
                ForEach-Object { $_.Matches } |
                ForEach-Object { $_.Groups[1].Value } |
                Sort-Object -Unique
        )

        if (@($failedFunctions).Count -eq 0) {
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
    flutter build web --release --no-tree-shake-icons --no-wasm-dry-run
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
        Invoke-FirebaseDeployVerified -Targets "hosting,firestore,storage"
    } else {
        Write-Host "`n[3/5] reprise ciblée: firebase deploy (hosting)..." -ForegroundColor Cyan
        Invoke-FirebaseDeployVerified -Targets "hosting"
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
        # Release/ est ignoré (artefacts de build) : un déploiement sans changement de source
        # ne doit pas créer de commit vide ni faire échouer le script.
        if (git diff --cached --name-only) {
            $commitMsg = if ($Message) { $Message } else { "deploy: $(Get-Date -Format 'yyyy-MM-dd HH:mm')" }
            git commit -m $commitMsg
            git push
        } else {
            Write-Host "Aucune modification de source à commiter." -ForegroundColor DarkGray
        }
    } finally {
        Pop-Location
    }
} else {
    Write-Host "`n[5/5] git commit + push ignorés (-SkipGit)" -ForegroundColor DarkGray
}

$version = (Get-Content "$appDir\pubspec.yaml" | Where-Object { $_ -match "^version:" }) -replace "^version:\s*", "" -replace "\+.*", ""
$heure = Get-Date -Format 'HH:mm:ss'
Write-Host "`nDéployé Version $version à $heure avec succès !" -ForegroundColor Green
