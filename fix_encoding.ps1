$file = "kass_dalle\lib\features\recipes\presentation\edit\recipe_edit_screen.dart"
$r = [char]0xFFFD
$E_acute = [char]0x00C9
$e_acute = [char]0x00E9
$a_grave = [char]0x00E0

$content = [System.IO.File]::ReadAllText($file, [System.Text.Encoding]::UTF8)

$content = $content.Replace("'" + $r + "diteur'", "'" + $E_acute + "diteur'")
$content = $content.Replace("'Ingr" + $r + "dients'", "'Ingr" + $e_acute + "dients'")
$content = $content.Replace("Mettre " + $r + " jour les champs m" + $r + "ta depuis le CookLang corrig" + $r, "Mettre " + $a_grave + " jour les champs m" + $e_acute + "ta depuis le CookLang corrig" + $e_acute)
$content = $content.Replace("'difficult" + $r + "'", "'difficult" + $e_acute + "'")
$content = $content.Replace("'temps_pr" + $r + "paration'", "'temps_pr" + $e_acute + "paration'")

[System.IO.File]::WriteAllText($file, $content, [System.Text.Encoding]::UTF8)

$remaining = 0
$bytes = [System.IO.File]::ReadAllBytes($file)
for ($i = 0; $i -lt ($bytes.Count - 2); $i++) {
    if ($bytes[$i] -eq 0xEF -and $bytes[$i+1] -eq 0xBF -and $bytes[$i+2] -eq 0xBD) { $remaining++ }
}
Write-Host "Remaining replacement chars: $remaining"
