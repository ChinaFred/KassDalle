<#
.SYNOPSIS
    Déploie KassDalle : build web + APK Android, Firebase hosting, Release/, git push.

.PARAMETER WebOnly
    RETIRÉ. Tout déploiement embarque désormais l'APK ; passer ce paramètre
    arrête le script au lieu de publier un site sans binaire.

.PARAMETER Message
    Message de commit git. Par défaut : "deploy: <date>"

.EXAMPLE
    .\deploy.ps1
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

# « -WebOnly » est refusé, et non ignoré.
#
# L'application Android lit le manifeste posé à côté de l'APK pour savoir si
# une mise à jour existe. Un déploiement sans APK laisse ce manifeste décrire
# une version que le téléchargement ne rend pas : la fenêtre de mise à jour
# revient à chaque lancement, et le lien pointe vers un fichier absent ou
# périmé.
#
# Le refuser plutôt que de construire l'APK quand même : un script qui fait
# silencieusement plus que ce qu'on lui demande est aussi difficile à
# comprendre qu'un script qui en fait moins.
if ($WebOnly) {
    throw "-WebOnly a ete retire : tout deploiement embarque l'APK. Relancer sans ce parametre."
}

$root     = $PSScriptRoot
$appDir   = Join-Path $root "kass_dalle"
$releaseWeb   = Join-Path $root "Release\web"
$releaseMobile = Join-Path $root "Release\mobile"

function Invoke-FirebaseCli {
    param(
        [Parameter(Mandatory = $true)][string[]]$FirebaseArgs,
        [Parameter(Mandatory = $true)][string]$LogFile
    )

    # Un « npm notice » sur stderr n'est pas un echec de deploiement.
    #
    # $ErrorActionPreference = "Stop" transforme la moindre ligne ecrite sur
    # stderr par un executable natif en erreur terminante — NativeCommandError,
    # comportement de PowerShell 5.1. Le 30 aout 2026, un simple avis de mise a
    # jour npm a arrete le deploiement juste avant les functions : le web et
    # l'APK etaient construits, rien n'etait en ligne, et le message d'erreur ne
    # parlait que de firebase.ps1.
    #
    # Ce qui decide du succes ne change pas : le code de sortie ET la ligne
    # « Deploy complete! », verifies par les appelants. Le bruit de stderr n'en
    # fait pas partie.
    $previous = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        & firebase @FirebaseArgs *> $LogFile
        return $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $previous
    }
}

function Invoke-FirebaseDeployVerified {
    param(
        [Parameter(Mandatory = $true)][string]$Targets
    )

    # Même défiance que pour les fonctions : un code 0 ne prouve pas qu'on a
    # déployé. Seule la ligne « Deploy complete! » le dit, et sans elle le
    # script annoncerait une mise en ligne qui n'a pas eu lieu.
    $logFile = Join-Path $env:TEMP ("kassdalle-deploy-{0}.log" -f ([guid]::NewGuid().ToString("N")))
    try {
        $exitCode = Invoke-FirebaseCli -FirebaseArgs @("deploy", "--only", $Targets) -LogFile $logFile
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
        $firstExitCode = Invoke-FirebaseCli -FirebaseArgs @("deploy", "--only", "functions") -LogFile $firstLog
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
        $retryExitCode = Invoke-FirebaseCli -FirebaseArgs @("deploy", "--only", "functions") -LogFile $logFile
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
            $fnLog = Join-Path $env:TEMP ("kassdalle-functions-{0}-{1}.log" -f $fn, ([guid]::NewGuid().ToString("N")))
            try {
                $fnExitCode = Invoke-FirebaseCli -FirebaseArgs @("deploy", "--only", "functions:$fn") -LogFile $fnLog
                Get-Content $fnLog | Write-Output
                if ($fnExitCode -ne 0) {
                    throw "Relance ciblée échouée pour la fonction $fn"
                }
            } finally {
                Remove-Item $fnLog -Force -ErrorAction SilentlyContinue
            }
        }
    } finally {
        Remove-Item $logFile -Force -ErrorAction SilentlyContinue
    }
}

function Get-PubspecVersion {
    param(
        [Parameter(Mandatory = $true)][string]$PubspecPath
    )

    $line = Get-Content $PubspecPath | Where-Object { $_ -match "^version:" } | Select-Object -First 1
    if (-not $line) { throw "Aucune ligne « version: » dans $PubspecPath" }

    $raw = ($line -replace "^version:\s*", "").Trim()
    $parts = $raw -split "\+", 2
    $build = ""
    if ($parts.Count -gt 1) { $build = $parts[1] }

    return [pscustomobject]@{
        Version = $parts[0]
        Build   = $build
        Raw     = $raw
    }
}

function Write-ApkManifest {
    <#
        Décrit l'APK réellement construit, à côté de lui.

        L'application Android lit ce fichier pour savoir si une mise à jour
        existe. Elle lisait « version.json » avant, qui décrit le bundle web :
        un « -WebOnly » annonçait alors une version que le téléchargement ne
        rendait pas, et la fenêtre de mise à jour revenait à chaque lancement.

        Ce manifeste n'est donc écrit qu'ici, au moment où l'APK vient d'être
        compilé, et jamais reconstitué à partir de « pubspec.yaml » plus tard :
        la version qu'il porte est celle du binaire posé à côté.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$ApkPath,
        [Parameter(Mandatory = $true)][string]$Version,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$BuildNumber,
        [Parameter(Mandatory = $true)][string]$Destination
    )

    $apk = Get-Item $ApkPath
    $manifest = [ordered]@{
        version      = $Version
        build_number = $BuildNumber
        file         = $apk.Name
        size_bytes   = $apk.Length
        built_at     = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
    }

    # UTF-8 SANS BOM : « Out-File -Encoding utf8 » en PowerShell 5.1 en ajoute
    # un, et jsonDecode côté Dart rejette le document dès le premier caractère.
    $json = $manifest | ConvertTo-Json -Compress
    [System.IO.File]::WriteAllText($Destination, $json, (New-Object System.Text.UTF8Encoding($false)))
}

function Publish-ApkPayload {
    <#
        Garantit que l'APK et son manifeste partent ensemble, ou pas du tout.

        Un déploiement hosting remplace tout le contenu de « build/web ». Sans
        cette étape, « -WebOnly » publiait un site sans APK — lien de
        téléchargement en 404 — ou, si le fichier avait survécu au build web, un
        APK ancien sous un numéro de version neuf.

        Trois cas, et un seul message pour chacun :
          - APK et manifeste présents : rien à faire.
          - Absents de build/web : on restaure la dernière paire connue depuis
            Release/mobile. L'application se verra proposer cette version-là,
            qui est bien celle qu'elle téléchargera.
          - Rien à restaurer : on ne publie ni l'un ni l'autre. Aucun manifeste
            veut dire aucune mise à jour proposée, ce qui est exact.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$WebDir,
        [Parameter(Mandatory = $true)][string]$MobileDir
    )

    $webApk      = Join-Path $WebDir "app-release.apk"
    $webManifest = Join-Path $WebDir "apk_release.json"
    $keptApk      = Join-Path $MobileDir "app-release.apk"
    $keptManifest = Join-Path $MobileDir "apk_release.json"

    if (-not (Test-Path $webApk)) {
        if ((Test-Path $keptApk) -and (Test-Path $keptManifest)) {
            Copy-Item $keptApk $webApk -Force
            Copy-Item $keptManifest $webManifest -Force
            Write-Host "APK restauré depuis Release/mobile (build non rejoué)." -ForegroundColor DarkGray
        } else {
            Remove-Item $webManifest -Force -ErrorAction SilentlyContinue
            Write-Host "Aucun APK à publier : le site n'en proposera pas et aucune mise à jour ne sera annoncée." -ForegroundColor Yellow
            return
        }
    }

    # APK présent, manifeste absent : rien ne dit quelle version porte ce
    # binaire. Emprunter celui de Release/mobile associerait un numéro à un
    # fichier qui n'est pas le sien, et un numéro trop haut ferait réinstaller
    # la même version à chaque lancement. On publie l'APK pour le lien du site,
    # sans rien annoncer. Le prochain déploiement complet rétablit la paire.
    if (-not (Test-Path $webManifest)) {
        Write-Host "APK publié sans manifeste : aucune mise à jour ne sera proposée aux téléphones." -ForegroundColor Yellow
        return
    }

    $announced = (Get-Content $webManifest -Raw | ConvertFrom-Json).version
    Write-Host "APK publié : v$announced" -ForegroundColor DarkGray
}

# ── 0. Clé Gemini ──────────────────────────────────────────────────────────────
# La clé Gemini n'est plus passée côté client : elle est gérée par Secret Manager
# côté Cloud Functions (secret GEMINI_API_KEY). Voir functions/src/gemini/*.

Push-Location $appDir
try {
    # ── 0b. La version n'a plus rien à synchroniser ────────────────────────────
    #
    # Une étape écrivait ici `const String kAppVersion = '…'` dans
    # `lib/core/app_version.dart`, recopié depuis `pubspec.yaml`. Ce fichier ne
    # porte plus cette constante : il lit la version du bundle natif au
    # démarrage (`package_info_plus`), et `version.json` sur le web. La
    # substitution ne trouvait donc plus rien, et le script annonçait quand même
    # « app_version.dart mis à jour ». Un déploiement qui affirme une action
    # qu'il ne fait pas est pire qu'un déploiement silencieux.
    #
    # Rien ne la remplace : `pubspec.yaml` reste la seule source, et les trois
    # plateformes vont l'y chercher elles-mêmes.

    # ── 1. Build Web ───────────────────────────────────────────────────────────
    Write-Host "`n[1/5] flutter build web..." -ForegroundColor Cyan
    flutter build web --release --no-tree-shake-icons --no-wasm-dry-run
    if ($LASTEXITCODE -ne 0) { throw "flutter build web a échoué" }

    # ── 2. Build APK (sauf -WebOnly) ───────────────────────────────────────────
    if (-not $WebOnly) {
        Write-Host "`n[2/5] flutter build apk..." -ForegroundColor Cyan
        flutter build apk --release
        if ($LASTEXITCODE -ne 0) { throw "flutter build apk a échoué" }

        # Copier l'APK dans build/web pour le lien de téléchargement du site,
        # et écrire le manifeste que l'application Android interroge au
        # lancement. Les deux vont ensemble : le manifeste décrit le fichier
        # posé à côté de lui, pas la version du dépôt.
        $apkBuilt = "$appDir\build\app\outputs\flutter-apk\app-release.apk"
        if (Test-Path $apkBuilt) {
            Copy-Item $apkBuilt "$appDir\build\web\app-release.apk" -Force
            $pubspec = Get-PubspecVersion -PubspecPath "$appDir\pubspec.yaml"
            Write-ApkManifest `
                -ApkPath "$appDir\build\web\app-release.apk" `
                -Version $pubspec.Version `
                -BuildNumber $pubspec.Build `
                -Destination "$appDir\build\web\apk_release.json"
            Write-Host "APK v$($pubspec.Raw) copié dans build/web avec son manifeste" -ForegroundColor DarkGray
        }
    } else {
        Write-Host "`n[2/5] APK ignoré (-WebOnly)" -ForegroundColor DarkGray
    }

    # ── 3. Firebase deploy (functions puis hosting/firestore/storage) ─────────
    # Le hosting remplace tout le contenu de build/web : sans cette étape, un
    # déploiement qui n'a pas reconstruit l'APK le supprimerait de la mise en
    # ligne, ou publierait l'ancien sous le numéro de version du web.
    Publish-ApkPayload -WebDir "$appDir\build\web" -MobileDir $releaseMobile

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
        New-Item -ItemType Directory -Force $releaseMobile | Out-Null
        Copy-Item $apkSrc "$releaseMobile\app-release.apk" -Force
        # Le manifeste suit l'APK : c'est cette paire que « Publish-ApkPayload »
        # restaure quand un déploiement ultérieur ne reconstruit pas le binaire.
        $apkManifestSrc = "$appDir\build\web\apk_release.json"
        if (Test-Path $apkManifestSrc) {
            Copy-Item $apkManifestSrc "$releaseMobile\apk_release.json" -Force
        }
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

$version = (Get-PubspecVersion -PubspecPath "$appDir\pubspec.yaml").Version
$heure = Get-Date -Format 'HH:mm:ss'
Write-Host "`nDéployé Version $version à $heure avec succès !" -ForegroundColor Green

# L'écart entre le web et l'APK est normal après un « -WebOnly » ; il devient un
# problème quand personne ne le voit. Les téléphones se verront proposer la
# version nommée ici, et pas celle du site.
$deployedManifest = "$appDir\build\web\apk_release.json"
if (Test-Path $deployedManifest) {
    $apkVersion = (Get-Content $deployedManifest -Raw | ConvertFrom-Json).version
    if ($apkVersion -ne $version) {
        # Pas de tiret cadratin dans une chaine : ce fichier n'a pas de BOM, et
        # PowerShell 5.1 le lit alors en ANSI, ou l'octet 0x94 du tiret devient
        # un guillemet fermant qui coupe la chaine en deux.
        Write-Host "APK en ligne : v$apkVersion. Les téléphones ne verront pas la v$version." -ForegroundColor Yellow
    }
} else {
    Write-Host "Aucun APK en ligne : les téléphones ne recevront aucune mise à jour." -ForegroundColor Yellow
}
