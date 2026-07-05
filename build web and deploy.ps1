<#
.SYNOPSIS
    Build web + déploiement web de KassDalle.

.DESCRIPTION
    Ce script lance d'abord le build web Flutter,
    puis appelle le script racine deploy.ps1 en mode WebOnly.

.PARAMETER Message
    Message de commit transmis à deploy.ps1.

.EXAMPLE
    .\build-and-deploy.ps1
    .\build-and-deploy.ps1 -Message "release: v0.17.2"
#>
param(
    [string]$Message = ""
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$root = $PSScriptRoot
$appDir = Join-Path $root "kass_dalle"
$deployScript = Join-Path $root "deploy.ps1"

if (-not (Test-Path $deployScript)) {
    throw "Script introuvable : $deployScript"
}

Write-Host "`n[1/2] flutter build web --release..." -ForegroundColor Cyan
Push-Location $appDir
try {
    flutter build web --release --no-tree-shake-icons
    if ($LASTEXITCODE -ne 0) { throw "flutter build web a échoué" }
} finally {
    Pop-Location
}

Write-Host "`n[2/2] Appel de deploy.ps1 -WebOnly..." -ForegroundColor Cyan
$deployArgs = @()
$deployArgs += "-WebOnly"
if ($Message) {
    $deployArgs += "-Message"
    $deployArgs += $Message
}

& $deployScript @deployArgs
if ($LASTEXITCODE -ne 0) {
    throw "deploy.ps1 a retourné un code d'erreur ($LASTEXITCODE)"
}

Write-Host "`nBuild + deploy terminés." -ForegroundColor Green