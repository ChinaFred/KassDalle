import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:kass_dalle/features/admin/domain/backfill_registry.dart';
import 'package:kass_dalle/features/admin/domain/backfill_status.dart';

BackfillSchedule _s(List<int> days, int hour, {bool enabled = true}) =>
    BackfillSchedule(enabled: enabled, days: days, hour: hour);

// Dimanche 11 octobre 2026, 14 h à Paris (heure d'été, UTC+2).
final _now = DateTime.utc(2026, 10, 11, 12);

/// Ponctuel d'essai, absent du registre : le registre n'en a plus qu'un.
const _testPonctuel = BackfillDefinition(
  key: 'test_ponctuel',
  kind: BackfillKind.ponctuel,
  title: 'Ponctuel d\'essai',
  description: 'Sert aux tests de rangement et de liste.',
  usesAi: false,
  passLimit: '',
);

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
    final sodium = backfillDefinition(BackfillKeys.refreshSodium)!;

    test('jamais lancé', () {
      expect(
        backfillStatusLine(def: roles, state: null, schedule: null, now: _now),
        'Jamais lancé. Lancez un premier passage ou programmez-le.',
      );
      expect(
        backfillStatusLine(def: sodium, state: null, schedule: null, now: _now),
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

    test('incomplet par des échecs : pas de reprise à l\'heure suivante', () {
      final nutrition = backfillDefinition(BackfillKeys.nutrition)!;
      final state = BackfillRunState.fromMap('nutrition', {
        'dernier_passage_statut': 'incomplet',
        'dernier_passage_origine': 'programme',
        'reprise_due': false,
        'echecs_restants': 9,
        'dernier_passage_le': DateTime.utc(2026, 10, 11, 3, 2),
        'last_report': {
          'reprises': 9,
          'completees': 0,
          'echouees': 9,
          'laissees': 0,
        },
      });
      expect(state.echecsRestants, 9);
      expect(
        backfillStatusLine(
          def: nutrition,
          state: state,
          schedule: _s(kAllBackfillDays, 5),
          now: _now,
        ),
        'Incomplet — dim. 11/10 à 05:02 · 9 reprises, 0 complétée, '
        '9 encore incomplètes · 9 éléments en échec, nouvel essai '
        'demain à 05:00',
      );
      // Sans programmation active, rien ne reviendra tout seul.
      expect(
        backfillStatusLine(
          def: nutrition,
          state: state,
          schedule: BackfillSchedule.fromMap({
            'enabled': false,
            'days': [1],
            'hour': 5,
          }),
          now: _now,
        ),
        'Incomplet — dim. 11/10 à 05:02 · 9 reprises, 0 complétée, '
        '9 encore incomplètes · 9 éléments en échec. Relancez pour réessayer.',
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
      final state = BackfillRunState.fromMap('refresh_sodium', {
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

  group('résumé chiffré', () {
    test('nutrition : les recettes encore incomplètes, pas « 0 restante »', () {
      expect(
        backfillReportSummary(BackfillKeys.nutrition, {
          'reprises': 9,
          'completees': 0,
          'echouees': 9,
          'laissees': 0,
        }),
        '9 reprises, 0 complétée, 9 encore incomplètes',
      );
    });

    test(
      'nutrition : laissées, sans reprise possible, abandonnées si présentes',
      () {
        expect(
          backfillReportSummary(BackfillKeys.nutrition, {
            'reprises': 20,
            'completees': 18,
            'echouees': 2,
            'laissees': 7,
            'nonReprenables': 4,
            'abandonnees': 1,
          }),
          '20 reprises, 18 complétées, 2 encore incomplètes, '
          '7 laissées faute de temps, 4 sans reprise possible, 1 abandonnée',
        );
      },
    );

    test('exclus après trois échecs, cités seulement quand il y en a', () {
      expect(
        backfillReportSummary(BackfillKeys.enrichReferentials, {
          'enrichedUnits': 1,
          'enrichedIngredients': 10,
          'failedIngredients': 2,
          'excludedUnits': 1,
          'excludedIngredients': 4,
        }),
        '1 unité enrichie, 10 ingrédients enrichis, 2 échecs, '
        '1 unité exclue après 3 échecs, 4 ingrédients exclus après 3 échecs',
      );
      expect(
        backfillReportSummary(BackfillKeys.allergens, {
          'ingredientsExamines': 38,
          'recettesCalculees': 2,
          'recettesIncompletes': 0,
          'ingredientsExclus': 3,
        }),
        '38 ingrédients examinés, 2 recettes recalculées, 0 incomplète, '
        '3 ingrédients exclus après 3 échecs',
      );
      expect(
        backfillReportSummary(BackfillKeys.recipeRoles, {
          'classees': 38,
          'restantes': 2,
          'exclues': 2,
        }),
        '38 classées, 2 restantes, 2 recettes exclues après 3 échecs',
      );
      expect(
        backfillReportSummary(BackfillKeys.recipeRoles, {
          'classees': 38,
          'restantes': 0,
        }),
        '38 classées, 0 restante',
      );
    });

    test('ustensiles : l\'essai à blanc se distingue du nettoyage', () {
      expect(
        backfillReportSummary(BackfillKeys.utensilsCleanup, {
          'essaiABlanc': true,
          'corrigees': 12,
          'fichesSupprimees': 1,
        }),
        'Essai à blanc : 12 recettes à corriger, 1 fiche à supprimer',
      );
      expect(
        backfillReportSummary(BackfillKeys.utensilsCleanup, {
          'essaiABlanc': false,
          'corrigees': 12,
          'fichesSupprimees': 2,
          'echouees': 0,
          'fichesEchouees': 0,
        }),
        '12 recettes corrigées, 2 fiches supprimées, 0 échec',
      );
    });
  });

  group('rangement', () {
    test('trois sections, ordre fixe du registre', () {
      // Un ponctuel d'essai s'ajoute à ceux du registre, après eux.
      final sections = backfillSections(
        [...kBackfillRegistry, _testPonctuel],
        {
          'refresh_sodium': BackfillRunState.fromMap('refresh_sodium', {
            'termine_le': DateTime.utc(2026, 10, 10),
          }),
          // Un état de récurrent marqué terminé ne le déplace pas.
          'nutrition': BackfillRunState.fromMap('nutrition', {
            'termine_le': DateTime.utc(2026, 10, 10),
          }),
        },
      );
      expect(sections.recurrents.map((d) => d.key), [
        'nutrition',
        'enrich_referentials',
        'allergens',
        'recipe_roles',
        'shopping_products',
      ]);
      expect(sections.ponctuelsALancer.map((d) => d.key), [
        'utensils_cleanup',
        'test_ponctuel',
      ]);
      expect(sections.ponctuelsTermines.map((d) => d.key), ['refresh_sodium']);
    });

    test('état illisible : tous les ponctuels restent à lancer', () {
      final sections = backfillSections(kBackfillRegistry, const {});
      expect(sections.ponctuelsALancer.map((d) => d.key), [
        'refresh_sodium',
        'utensils_cleanup',
      ]);
      expect(sections.ponctuelsTermines, isEmpty);
    });

    test('menu ⋮ : « Marquer comme terminé » sur un ponctuel seulement', () {
      for (final def in kBackfillRegistry) {
        expect(backfillOffersDoneMenu(def), !def.isRecurrent, reason: def.key);
      }
      expect(
        backfillOffersDoneMenu(backfillDefinition(BackfillKeys.refreshSodium)!),
        isTrue,
      );
      expect(
        backfillOffersDoneMenu(backfillDefinition(BackfillKeys.nutrition)!),
        isFalse,
      );
    });

    test('clé retirée du registre : son état resté en base est ignoré', () {
      // `app_config/backfill_run_<clé>` des ponctuels retirés en v0.23.52,
      // v0.24.33, v0.24.37, v0.24.44 et v0.24.52.
      final sections = backfillSections(kBackfillRegistry, {
        for (final key in [
          'recipe_protein',
          'estimated_times',
          'planning_defaults',
          'system_books',
          'group_planning_reach',
          'ticket_analyses',
          'ticket_delivered_pr',
          'recipe_title_keys',
          'invitation_group_owner',
          'illustration_folders',
          'illustration_folders_move',
          'move_meals_to_group',
          'default_units',
          'users_schema_check',
        ])
          key: BackfillRunState.fromMap(key, {
            'termine_le': DateTime.utc(2026, 10, 10),
            'dernier_passage_statut': 'termine',
            'last_report': {'traitees': 3},
          }),
      });
      final shown = [
        ...sections.recurrents,
        ...sections.ponctuelsALancer,
        ...sections.ponctuelsTermines,
      ].map((d) => d.key);
      expect(shown, isNot(contains('recipe_protein')));
      expect(shown, isNot(contains('estimated_times')));
      expect(shown, isNot(contains('planning_defaults')));
      expect(shown, hasLength(kBackfillRegistry.length));
      expect(sections.ponctuelsTermines, isEmpty);
      expect(backfillDefinition('estimated_times'), isNull);
      expect(backfillDefinition('system_books'), isNull);
      expect(backfillReportSummary('recipe_protein', {'traitees': 3}), '');
      expect(
        backfillReportSummary('ticket_analyses', {'ecrits': 12}),
        '',
        reason: 'résumé retiré avec le backfill',
      );
      expect(backfillDefinition('illustration_folders'), isNull);
      expect(
        backfillReportSummary('illustration_folders_move', {'rangees': 18}),
        '',
        reason: 'résumé retiré avec le backfill',
      );
      expect(backfillDefinition('move_meals_to_group'), isNull);
      expect(
        backfillReportSummary('move_meals_to_group', {
          'deplaces': 7,
          'echoues': 0,
        }),
        '',
        reason: 'résumé retiré avec le backfill',
      );
      expect(backfillDefinition('default_units'), isNull);
      expect(
        backfillReportSummary('default_units', {'creees': 2, 'completees': 38}),
        '',
        reason: 'résumé retiré avec le backfill',
      );
      expect(backfillDefinition('users_schema_check'), isNull);
      expect(
        backfillReportSummary('users_schema_check', {'examines': 7}),
        '',
        reason: 'résumé retiré avec le backfill',
      );
    });
  });

  group('liste des ponctuels terminés', () {
    test('une ligne par backfill : clé, titre, fin, origine, compte rendu', () {
      final done = [
        backfillDefinition(BackfillKeys.refreshSodium)!,
        _testPonctuel,
      ];
      final text = backfillDoneListText(done, {
        'refresh_sodium': BackfillRunState.fromMap('refresh_sodium', {
          'termine_le': DateTime.utc(2026, 10, 20, 8),
          'termine_version': '0.24.32',
          'termine_par': 'auto',
          'last_report': {
            'refreshedIngredients': 412,
            'failedIngredients': 0,
            'aRevoir': {'items': <Object>[], 'total': 0},
          },
        }),
        'test_ponctuel': BackfillRunState.fromMap('test_ponctuel', {
          'termine_le': DateTime.utc(2026, 10, 12, 8),
          'termine_par': 'manuel',
        }),
      });
      expect(
        text,
        'refresh_sodium — Reprendre le sel des ingrédients — terminé le '
        '20/10/2026 en v0.24.32 — automatique — dernier compte rendu : '
        '412 ingrédients repris, 0 échec — à revoir : 0\n'
        'test_ponctuel — Ponctuel d\'essai — terminé le '
        '12/10/2026 (version inconnue) — marqué à la main — dernier compte '
        'rendu : absent — à revoir : 0',
      );
    });

    test(
      'sans date ni version : « terminé (date inconnue, version inconnue) »',
      () {
        final text = backfillDoneListText(
          [backfillDefinition(BackfillKeys.refreshSodium)!],
          {
            'refresh_sodium': BackfillRunState.fromMap('refresh_sodium', {
              'termine_par': 'manuel',
            }),
          },
        );
        expect(
          text,
          'refresh_sodium — Reprendre le sel des ingrédients — terminé (date '
          'inconnue, version inconnue) — marqué à la main — dernier compte '
          'rendu : absent — à revoir : 0',
        );
      },
    );

    test('aucun ponctuel terminé : texte vide', () {
      expect(backfillDoneListText(const [], const {}), '');
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
