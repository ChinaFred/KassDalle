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

  // Format qty%unité (ex: "30%minutes", "5 à 8%min", "1-2%minutes", "1%heure")
  final pctIdx = trimmed.indexOf('%');
  if (pctIdx > 0) {
    final qty = formatTimerRange(trimmed.substring(0, pctIdx));
    final unit = trimmed.substring(pctIdx + 1).trim().toLowerCase();
    if (qty.isNotEmpty && unit.isNotEmpty) {
      if (unit.startsWith('min')) return '$qty min';
      if (unit.startsWith('h')) return '$qty h';
      return '$qty $unit';
    }
  }

  return trimmed;
}

/// Écrit une fourchette de durée comme on la lit : « 1 à 2 », jamais « 1-2 ».
///
/// Les modèles écrivent la fourchette au tiret, parce que c'est ainsi qu'elle
/// est imprimée dans les livres. Un tiret entre deux nombres se lit pourtant
/// « moins » avant de se lire « à », et « 1-2 min » sur une puce ressemble à
/// une soustraction. Le mot lève le doute et ne coûte rien.
///
/// Un tiret qui ne sépare pas deux nombres n'est pas touché : ce n'est alors
/// pas une fourchette.
String formatTimerRange(String qty) {
  return qty.trim().replaceAllMapped(
    RegExp(r'(\d)\s*-\s*(\d)'),
    (m) => '${m.group(1)} à ${m.group(2)}',
  );
}

/// Un temps de repos, écrit comme on le dit.
///
/// « 720 min » ne se lit pas ; « 12 h » si. Un repos se compte en heures ou en
/// jours bien plus souvent qu'en minutes — c'est ce qui le distingue des deux
/// autres durées d'une recette.
String formatRestTime(int minutes) {
  if (minutes >= 1440) {
    final jours = (minutes / 1440).round();
    return jours == 1 ? '1 jour' : '$jours jours';
  }
  if (minutes >= 60) {
    final heures = minutes ~/ 60;
    final reste = minutes % 60;
    return reste == 0 ? '$heures h' : '$heures h $reste';
  }
  return '$minutes min';
}
