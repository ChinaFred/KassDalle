$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
$targetFile = Join-Path $repoRoot 'kass_dalle/lib/features/recipes/presentation/detail/recipe_detail_screen.dart'
$routerFile = Join-Path $repoRoot 'kass_dalle/lib/core/router/app_router.dart'
$v2File = Join-Path $repoRoot 'kass_dalle/lib/features/recipes/presentation/detail/recipe_detail_screen_v2.dart'

if (-not (Test-Path $targetFile)) {
  Write-Error "Fichier introuvable: $targetFile"
}
if (-not (Test-Path $routerFile)) {
  Write-Error "Fichier introuvable: $routerFile"
}
if (-not (Test-Path $v2File)) {
  Write-Error "Fichier introuvable: $v2File"
}

$content = Get-Content -Path $targetFile -Raw -Encoding UTF8
$routerContent = Get-Content -Path $routerFile -Raw -Encoding UTF8
$v2Content = Get-Content -Path $v2File -Raw -Encoding UTF8

$checks = @(
  @{ Id = 'app_bar'; Description = 'AppBar de detail presente'; Pattern = 'RecipeDetailAppBar\s*\(' },
  @{ Id = 'annotations_dialog'; Description = 'Bouton annoter ouvre AnnotationDialog'; Pattern = 'AnnotationDialog\(recipeId:\s*recipeId\)' },
  @{ Id = 'book_reader_viewport'; Description = 'Navigation reader viewport active'; Pattern = 'BookReaderViewport\s*\(' },
  @{ Id = 'book_reader_bottom'; Description = 'Navigation reader bottom bar active'; Pattern = 'BookReaderBottomBar\s*\(' },
  @{ Id = 'export_pdf'; Description = 'Export PDF actif'; Pattern = '_exportPdf\(' },
  @{ Id = 'copy_as_draft'; Description = 'Copie en brouillon active'; Pattern = '_copyAsDraft\(' },
  @{ Id = 'detach_from_book'; Description = 'Detacher du livre actif'; Pattern = '_detachFromBook\(' },
  @{ Id = 'delete_recipe'; Description = 'Suppression recette active'; Pattern = '_deleteRecipe\(' },
  @{ Id = 'scroll_to_annotations'; Description = 'Ancre annotations active'; Pattern = '_scrollToAnnotations\(' },
  @{ Id = 'portions_wiring'; Description = 'Passage portions au body'; Pattern = 'selectedPortions:\s*_selectedPortions' },
  @{ Id = 'cooklang_body'; Description = 'Body detail rendu'; Pattern = 'RecipeDetailBody\s*\(' }
)

$results = foreach ($check in $checks) {
  $ok = [regex]::IsMatch($content, $check.Pattern)
  [PSCustomObject]@{
    Id = $check.Id
    Description = $check.Description
    Status = if ($ok) { 'OK' } else { 'MISSING' }
  }
}

$migrationChecks = @(
  @{ Id = 'router_v2_override'; Description = 'Routeur: override recipeUi v2 supporte'; Pattern = "forceUi\s*==\s*'v2'" },
  @{ Id = 'router_v1_override'; Description = 'Routeur: override recipeUi v1 supporte'; Pattern = "forceUi\s*!=\s*'v1'" },
  @{ Id = 'router_v2_screen'; Description = 'Routeur: RecipeDetailScreenV2 branche'; Pattern = 'RecipeDetailScreenV2\s*\(' },
  @{ Id = 'v2_entrypoint'; Description = 'V2: classe ecran presente'; Pattern = 'class\s+RecipeDetailScreenV2\s+extends\s+ConsumerStatefulWidget' },
  @{ Id = 'v2_tabbar'; Description = 'V2: navigation onglets presente'; Pattern = 'TabBar\s*\(' },
  @{ Id = 'v2_prepare_tab'; Description = 'V2: onglet Preparer presente'; Pattern = 'class\s+_PrepareTab\s+extends' },
  @{ Id = 'v2_community_tab'; Description = 'V2: onglet Communaute presente'; Pattern = 'class\s+_CommunityTab\s+extends' },
  @{ Id = 'v2_sources_tab'; Description = 'V2: onglet Sources presente'; Pattern = 'class\s+_SourcesTab\s+extends' }
)

$migrationResults = foreach ($check in $migrationChecks) {
  $source = if ($check.Id -like 'v2_*') { $v2Content } else { $routerContent }
  $ok = [regex]::IsMatch($source, $check.Pattern)
  [PSCustomObject]@{
    Id = $check.Id
    Description = $check.Description
    Status = if ($ok) { 'OK' } else { 'MISSING' }
  }
}

$allResults = @($results + $migrationResults)

$missing = $allResults | Where-Object { $_.Status -eq 'MISSING' }

$allResults | Format-Table -AutoSize | Out-String | Write-Host

if ($missing.Count -gt 0) {
  Write-Host "\nResultat global: ECHEC ($($missing.Count) verifications manquantes)" -ForegroundColor Red
  exit 1
}

Write-Host "\nResultat global: SUCCES (toutes les verifications de presence sont OK)" -ForegroundColor Green
exit 0
