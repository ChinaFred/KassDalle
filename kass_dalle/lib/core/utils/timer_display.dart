/// Mise en forme des minuteurs CookLang.
///
/// Fonction pure, sortie de la couche présentation pour que l'export PDF s'en
/// serve aussi : il imprimait « Cuire 0:12:00 », c'est-à-dire la valeur brute
/// du jeton, là où l'application affiche depuis toujours « 12 minutes ».
library;

/// Formate le contenu d'un minuteur CookLang.
///
/// Supporte deux formats :
/// - hh:mm:ss → "0:30:00" → "30 minutes", "1:30:00" → "1h30"
/// - qty%unité → "30%minutes" → "30 min", "5 à 8%min" → "5 à 8 min"
String cooklangFormatTimer(String raw) {
  final trimmed = raw.trim();

  // Format hh:mm:ss
  final parts = trimmed.split(':');
  if (parts.length == 3) {
    final h = int.tryParse(parts[0]) ?? 0;
    final m = int.tryParse(parts[1]) ?? 0;
    final s = int.tryParse(parts[2]) ?? 0;
    if (h == 0 && m == 0 && s == 0) return trimmed;
    if (h == 0 && s == 0) return m == 1 ? '1 minute' : '$m minutes';
    if (h > 0 && m == 0 && s == 0) return h == 1 ? '1 heure' : '$h heures';
    if (h > 0 && m > 0 && s == 0) {
      return '${h}h${m.toString().padLeft(2, '0')}';
    }
    if (h == 0 && m > 0 && s > 0) return '$m min $s s';
    return '${h}h${m.toString().padLeft(2, '0')} $s s';
  }

  // Format qty%unité (ex: "30%minutes", "5 à 8%min", "1%heure")
  final pctIdx = trimmed.indexOf('%');
  if (pctIdx > 0) {
    final qty = trimmed.substring(0, pctIdx).trim();
    final unit = trimmed.substring(pctIdx + 1).trim().toLowerCase();
    if (qty.isNotEmpty && unit.isNotEmpty) {
      if (unit.startsWith('min')) return '$qty min';
      if (unit.startsWith('h')) return '$qty h';
      return '$qty $unit';
    }
  }

  return trimmed;
}
