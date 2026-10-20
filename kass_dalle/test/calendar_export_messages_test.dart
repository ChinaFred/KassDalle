/// Textes de l'envoi des repas vers Google Calendar : un envoi partiel compte
/// ce qui manque, et chaque texte s'accorde au nombre.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:kass_dalle/core/widgets/error_message.dart';
import 'package:kass_dalle/features/planning/domain/calendar_export_messages.dart';

String exportMissed(int exported, int total) => calendarExportMissed(
  exported: exported,
  total: total,
  participle: 'exporté',
  place: 'vers le calendrier',
);

void main() {
  test('un envoi partiel compte les repas qui manquent', () {
    expect(
      exportMissed(3, 5),
      '2 repas sur 5 non exportés vers le calendrier.',
    );
    expect(exportMissed(1, 2), '1 repas sur 2 non exporté vers le calendrier.');
  });

  test('aucun repas parti : la phrase ne compte pas', () {
    expect(exportMissed(0, 5), 'Repas non exportés vers le calendrier.');
    expect(exportMissed(0, 1), 'Repas non exporté vers le calendrier.');
  });

  test('le nouveau planning dit « ajouté au calendrier »', () {
    expect(
      calendarExportMissed(
        exported: 3,
        total: 5,
        participle: 'ajouté',
        place: 'au calendrier',
      ),
      '2 repas sur 5 non ajoutés au calendrier.',
    );
  });

  test('succès et comptes accordés au nombre', () {
    expect(calendarExportSuccess(1), '1 repas exporté vers le calendrier ✓');
    expect(calendarExportSuccess(4), '4 repas exportés vers le calendrier ✓');
    expect(plannedMealsLabel(1), '1 repas planifié');
    expect(plannedMealsLabel(12), '12 repas planifiés');
    expect(replacedMealsLabel(1), '1 remplacé');
    expect(replacedMealsLabel(2), '2 remplacés');
  });

  test('un refus d\'autorisation nomme le calendrier dans la première '
      'phrase', () {
    expect(
      failureMessage(
        kCalendarAccessNotGranted,
        Exception('Token Google non disponible'),
      ),
      'Accès au calendrier non accordé. Une erreur inattendue est survenue.',
    );
  });
}
