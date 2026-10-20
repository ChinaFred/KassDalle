/// Textes de l'envoi des repas vers Google Calendar, accordés au nombre.
///
/// L'écran du planning (« exportés vers le calendrier ») et le nouveau
/// planning (« ajoutés au calendrier ») comptent de la même façon : un envoi
/// partiel dit combien de repas manquent, et ni l'un ni l'autre ne propose
/// « Réessayer », qui doublerait dans l'agenda les événements déjà posés.
library;

/// Première phrase d'un refus d'autorisation Google (fenêtre fermée, jeton
/// absent) : la cause lisible de `describeError` suit.
const kCalendarAccessNotGranted = 'Accès au calendrier non accordé';

/// « 1 repas planifié », « 3 repas planifiés ».
String plannedMealsLabel(int count) =>
    '$count repas ${_agree('planifié', count)}';

/// « 1 remplacé », « 3 remplacés ».
String replacedMealsLabel(int count) => '$count ${_agree('remplacé', count)}';

/// Succès d'un envoi complet : « 1 repas exporté vers le calendrier ✓ ».
String calendarExportSuccess(int count) =>
    '$count repas ${_agree('exporté', count)} vers le calendrier ✓';

/// Échec, total ou partiel, d'un envoi de [total] repas dont [exported] sont
/// partis. [participle] est au masculin singulier (« exporté », « ajouté »),
/// [place] dit où (« vers le calendrier », « au calendrier »).
///
/// Aucun repas parti : « Repas non exportés vers le calendrier. ». Sinon, le
/// compte de ce qui manque : « 2 repas sur 5 non exportés vers le
/// calendrier. », « 1 repas sur 2 non exporté vers le calendrier. ».
String calendarExportMissed({
  required int exported,
  required int total,
  required String participle,
  required String place,
}) {
  final missing = total - exported;
  if (exported <= 0) {
    return 'Repas non ${_agree(participle, total)} $place.';
  }
  return '$missing repas sur $total non ${_agree(participle, missing)} '
      '$place.';
}

String _agree(String participle, int count) =>
    count > 1 ? '${participle}s' : participle;
