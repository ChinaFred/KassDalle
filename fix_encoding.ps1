param([string]$file)
# Fix double-encoded UTF-8: any C3 xx C2 yy (4 bytes) → original 2-byte sequence
# Recovery: b1 = (xx & 0x3F) | 0xC0, b2 = yy
$bytes = [System.IO.File]::ReadAllBytes($file)
$result = New-Object System.Collections.Generic.List[byte]
$i = 0; $fixed = 0
while ($i -lt $bytes.Count) {
    if ($i -lt ($bytes.Count - 3) `
        -and $bytes[$i] -eq 0xC3 `
        -and $bytes[$i+1] -ge 0x80 -and $bytes[$i+1] -le 0xBF `
        -and $bytes[$i+2] -eq 0xC2 `
        -and $bytes[$i+3] -ge 0x80 -and $bytes[$i+3] -le 0xBF) {
        $b1 = ($bytes[$i+1] -band 0x3F) -bor 0xC0
        $b2 = $bytes[$i+3]
        $result.Add($b1); $result.Add($b2)
        $i += 4; $fixed++
    } else {
        $result.Add($bytes[$i]); $i++
    }
}
[System.IO.File]::WriteAllBytes($file, $result.ToArray())
Write-Host "Fixed $fixed double-encoded sequences in $($file.Split('\')[-1])"
# Report remaining FFFD
$remaining = 0; $b = $result.ToArray()
for ($j=0; $j -lt ($b.Count-2); $j++) { if ($b[$j] -eq 0xEF -and $b[$j+1] -eq 0xBF -and $b[$j+2] -eq 0xBD) { $remaining++ } }
if ($remaining -gt 0) { Write-Host "  -> $remaining U+FFFD chars remaining" }
