/// Une durée en minutes, écrite comme partout dans l'application :
/// « 45 min », « 1h », « 1h50min ».
String formatDurationMinutes(int totalMin) {
  if (totalMin >= 60) {
    final h = totalMin ~/ 60;
    final m = totalMin % 60;
    return m > 0 ? '${h}h${m}min' : '${h}h';
  }
  return '$totalMin min';
}
