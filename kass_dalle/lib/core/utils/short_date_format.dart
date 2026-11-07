/// Dates et heures courtes en français, sans `intl` : « mar. 12 nov. 2026 »,
/// « mar. 12 nov. », « 19:30 ». Les mêmes libellés que la feuille
/// « Planifier » et la boîte « Poser dans le planning » de l'atelier repas,
/// lisibles dans une phrase et dans un test sans initialiser une locale.
library;

const List<String> _days = [
  'lun.',
  'mar.',
  'mer.',
  'jeu.',
  'ven.',
  'sam.',
  'dim.',
];
const List<String> _months = [
  'jan.',
  'fév.',
  'mars',
  'avr.',
  'mai',
  'juin',
  'juil.',
  'août',
  'sep.',
  'oct.',
  'nov.',
  'déc.',
];

/// « mar. 12 nov. 2026 ».
String formatShortDate(DateTime d) => '${formatShortDay(d)} ${d.year}';

/// « mar. 12 nov. » : le jour sans l'année, pour une phrase.
String formatShortDay(DateTime d) =>
    '${_days[d.weekday - 1]} ${d.day} ${_months[d.month - 1]}';

/// « 19:30 » : l'heure d'un repas, comme le planning l'affiche.
String formatClockTime(DateTime d) {
  String two(int n) => n < 10 ? '0$n' : '$n';
  return '${two(d.hour)}:${two(d.minute)}';
}

/// « Mar. 12 nov. » : le jour en tête de phrase.
String capitalizeFirst(String s) =>
    s.isEmpty ? s : '${s[0].toUpperCase()}${s.substring(1)}';
