import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:kass_dalle/features/admin/domain/backfill_registry.dart';
import 'package:kass_dalle/features/admin/domain/backfill_status.dart';

BackfillSchedule _s(List<int> days, int hour, {bool enabled = true}) =>
    BackfillSchedule(enabled: enabled, days: days, hour: hour);

// Dimanche 11 octobre 2026, 14 h à Paris (heure d'été, UTC+2).
final _now = DateTime.utc(2026, 10, 11, 12);

void main() {
  group('libellé de programmation', () {
    test('un seul jour', () {
      expect(backfillScheduleLabel(_s([7], 3)), 'Tous les dimanches à 3 h');
    });
    test('plusieurs jours', () {
      expect(
        backfillScheduleLabel(_s([1, 3, 5], 3)),
        'Lun., mer. et ven. à 3 h',
      );
      expect(backfillScheduleLabel(_s([2, 6], 22)), 'Mar. et sam. à 22 h');
    });
    test('tous les jours', () {
      expect(
        backfillScheduleLabel(_s(kAllBackfillDays, 5)),
        'Tous les jours à 5 h',
      );
    });
    test('non programmé : absent, désactivé ou sans jour', () {
      expect(backfillScheduleLabel(null), 'Non programmé');
      expect(
        backfillScheduleLabel(_s([7], 3, enabled: false)),
        'Non programmé',
      );
      expect(backfillScheduleLabel(_s([], 3)), 'Non programmé');
    });
  });

  group('programmations stockées', () {
    test(
      'sans réglage stocké : le défaut du registre, marqué « par défaut »',
      () {
        final s = BackfillSchedules.empty.scheduleFor(BackfillKeys.nutrition);
        expect(s?.isActive, isTrue);
        expect(
          backfillScheduleLabel(
            s,
            isDefault: BackfillSchedules.empty.isDefault(
              BackfillKeys.nutrition,
            ),
          ),
          'Tous les jours à 5 h (par défaut)',
        );
        expect(
          BackfillSchedules.empty.scheduleFor(BackfillKeys.recipeRoles),
          isNull,
        );
        expect(
          BackfillSchedules.empty.isDefault(BackfillKeys.recipeRoles),
          isFalse,
        );
      },
    );
    test('réglage stocké : plus de mention « par défaut »', () {
      const schedules = BackfillSchedules({
        'nutrition': {
          'enabled': false,
          'days': [1],
          'hour': 5,
        },
      });
      expect(schedules.isDefault('nutrition'), isFalse);
    });
    test('défaut semé par le serveur : tous les jours à 5 h', () {
      const schedules = BackfillSchedules({
        'nutrition': {
          'enabled': true,
          'days': [1, 2, 3, 4, 5, 6, 7],
          'hour': 5,
          'programme_par_uid': null,
        },
      });
      expect(
        backfillScheduleLabel(schedules.scheduleFor('nutrition')),
        'Tous les jours à 5 h',
      );
    });
    test('réglage stocké : il remplace le défaut, désactivé compris', () {
      const schedules = BackfillSchedules({
        'nutrition': {
          'enabled': false,
          'days': [1],
          'hour': 5,
        },
        'recipe_roles': {
          'enabled': true,
          'days': [7, 3, 3],
          'hour': 3,
        },
      });
      expect(
        backfillScheduleLabel(schedules.scheduleFor('nutrition')),
        'Non programmé',
      );
      expect(schedules.scheduleFor('recipe_roles')!.days, [3, 7]);
    });
  });

  group('prochain passage', () {
    test('dimanche 3 h, vu un dimanche après-midi : le dimanche suivant', () {
      final next = nextScheduledRun(_s([7], 3), _now)!;
      expect(formatNextRunLong(next), 'dimanche 18 octobre à 3 h');
      expect(
        backfillScheduleSummary(_s([7], 3), _now),
        'Tous les dimanches à 3 h. Prochain passage : dimanche 18 octobre à 3 h.',
      );
    });
    test('tous les jours à 5 h : demain', () {
      final next = nextScheduledRun(_s(kAllBackfillDays, 5), _now)!;
      expect(formatNextRunShort(next, _now), 'demain à 05:00');
    });
    test('heure d\'hiver : 3 h à Paris reste 3 h', () {
      // Samedi 31 octobre 2026, 12 h UTC ; le dimanche suivant est à UTC+1.
      final next = nextScheduledRun(
        _s([7], 3),
        DateTime.utc(2026, 10, 31, 12),
      )!;
      expect(next.hour, 3);
      expect(next.day, 1);
      expect(next.month, 11);
    });
  });

  group('ligne d\'état', () {
    final roles = backfillDefinition(BackfillKeys.recipeRoles)!;
    final protein = backfillDefinition(BackfillKeys.recipeProtein)!;

    test('jamais lancé', () {
      expect(
        backfillStatusLine(def: roles, state: null, schedule: null, now: _now),
        'Jamais lancé. Lancez un premier passage ou programmez-le.',
      );
      expect(
        backfillStatusLine(
          def: protein,
          state: null,
          schedule: null,
          now: _now,
        ),
        'Jamais lancé.',
      );
    });

    test('terminé, programmé, avec résumé chiffré', () {
      final state = BackfillRunState.fromMap('recipe_roles', {
        'dernier_passage_statut': 'termine',
        'dernier_passage_origine': 'programme',
        'dernier_passage_le': DateTime.utc(2026, 10, 11, 1, 2),
        'last_report': {'classees': 38, 'restantes': 0},
      });
      expect(
        backfillStatusLine(def: roles, state: state, schedule: null, now: _now),
        'Terminé — dim. 11/10 à 03:02, programmé · 38 classées, 0 restante',
      );
    });

    test('incomplet programmé : reprise à l\'heure suivante', () {
      final state = BackfillRunState.fromMap('recipe_roles', {
        'dernier_passage_statut': 'incomplet',
        'reprise_due': true,
        'dernier_passage_le': DateTime.utc(2026, 10, 11, 1, 2),
        'last_report': {'classees': 40, 'restantes': 23},
      });
      expect(
        backfillStatusLine(
          def: roles,
          state: state,
          schedule: _s([7], 3),
          now: DateTime.utc(2026, 10, 11, 1, 10),
        ),
        'Incomplet — dim. 11/10 à 03:02 · 40 classées, 23 restantes · '
        'reprise à 04:00',
      );
    });

    test('incomplet par plafond : reprise au prochain créneau', () {
      final state = BackfillRunState.fromMap('recipe_roles', {
        'dernier_passage_statut': 'incomplet',
        'arret_plafond': true,
      });
      expect(
        backfillStatusLine(
          def: roles,
          state: state,
          schedule: _s(kAllBackfillDays, 3),
          now: _now,
        ),
        'Incomplet — plafond de dépense atteint · reprise demain à 03:00',
      );
    });

    test('en cours, puis verrou expiré', () {
      final depuis = DateTime.utc(2026, 10, 11, 1);
      final state = BackfillRunState.fromMap('recipe_roles', {
        'dernier_passage_statut': 'en_cours',
        'en_cours_depuis': depuis,
        // L'échéance vient du serveur ; le client ne connaît pas la durée.
        'en_cours_expire_le': depuis.add(const Duration(minutes: 10)),
        'en_cours_origine': 'programme',
      });
      expect(
        backfillStatusLine(
          def: roles,
          state: state,
          schedule: null,
          now: depuis.add(const Duration(minutes: 3)),
        ),
        'En cours depuis 03:00 (programmé)',
      );
      expect(
        state.status(depuis.add(const Duration(minutes: 11))),
        BackfillRunStatus.interrompu,
      );
      expect(
        backfillStatusLine(
          def: roles,
          state: state,
          schedule: null,
          now: depuis.add(const Duration(minutes: 11)),
        ),
        'En erreur — passage interrompu',
      );
    });

    test('verrou sans échéance : interrompu', () {
      final state = BackfillRunState.fromMap('recipe_roles', {
        'dernier_passage_statut': 'en_cours',
        'en_cours_depuis': DateTime.utc(2026, 10, 11, 1),
      });
      expect(state.status(_now), BackfillRunStatus.interrompu);
    });

    test('auteur de la programmation rétrogradé : l\'erreur s\'affiche', () {
      final state = BackfillRunState.fromMap('recipe_roles', {
        'dernier_passage_statut': 'erreur',
        'dernier_passage_origine': 'programme',
        'dernier_passage_le': DateTime.utc(2026, 10, 11, 1),
        'dernier_passage_erreur':
            'L\'auteur de la programmation n\'est plus administrateur.',
      });
      expect(
        backfillStatusLine(def: roles, state: state, schedule: null, now: _now),
        'En erreur — dim. 11/10 à 03:00 : L\'auteur de la programmation '
        'n\'est plus administrateur.',
      );
    });

    test('ponctuel terminé à la main', () {
      final state = BackfillRunState.fromMap('estimated_times', {
        'termine_le': DateTime.utc(2026, 10, 10, 10),
        'termine_version': '0.23.30',
        'termine_par': 'manuel',
      });
      expect(
        backfillDoneLine(state),
        'Terminé le 10/10/2026 en v0.23.30 — à retirer du code '
        '(marqué à la main)',
      );
    });
  });

  group('rangement', () {
    test('trois sections, ordre fixe du registre', () {
      final sections = backfillSections(kBackfillRegistry, {
        'estimated_times': BackfillRunState.fromMap('estimated_times', {
          'termine_le': DateTime.utc(2026, 10, 10),
        }),
        // Un état de récurrent marqué terminé ne le déplace pas.
        'nutrition': BackfillRunState.fromMap('nutrition', {
          'termine_le': DateTime.utc(2026, 10, 10),
        }),
      });
      expect(sections.recurrents.map((d) => d.key), [
        'nutrition',
        'enrich_referentials',
        'allergens',
        'recipe_roles',
        'shopping_products',
      ]);
      expect(sections.ponctuelsALancer.map((d) => d.key), [
        'recipe_protein',
        'refresh_sodium',
        'planning_defaults',
      ]);
      expect(sections.ponctuelsTermines.map((d) => d.key), ['estimated_times']);
    });

    test('état illisible : tous les ponctuels restent à lancer', () {
      final sections = backfillSections(kBackfillRegistry, const {});
      expect(sections.ponctuelsALancer, hasLength(4));
      expect(sections.ponctuelsTermines, isEmpty);
    });
  });

  group('fixture backfill_schedule.json (partagée avec le serveur)', () {
    final fixture =
        jsonDecode(
              File('test-fixtures/backfill_schedule.json').readAsStringSync(),
            )
            as Map<String, dynamic>;

    test(
      'registre : mêmes clés, même ordre, même nature, même usage de l\'IA',
      () {
        expect([
          for (final def in kBackfillRegistry)
            {
              'key': def.key,
              'kind': def.kind.name,
              'uses_ai': def.usesAi,
              'default_schedule': def.defaultSchedule == null
                  ? null
                  : {
                      'days': def.defaultSchedule!.days,
                      'hour': def.defaultSchedule!.hour,
                    },
            },
        ], fixture['registry']);
      },
    );

    for (final c in (fixture['parse_schedule'] as List).cast<Map>()) {
      test('lecture d\'une programmation : ${c['name']}', () {
        final parsed = BackfillSchedule.fromMap(c['input']);
        expect(
          parsed == null
              ? null
              : {
                  'enabled': parsed.enabled,
                  'days': parsed.days,
                  'hour': parsed.hour,
                  'programme_par_uid': parsed.programmeParUid,
                },
          c['expected'],
        );
      });
    }
  });
}
