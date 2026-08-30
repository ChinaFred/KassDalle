import 'package:flutter_test/flutter_test.dart';
import 'package:kass_dalle/features/admin/domain/ai_call.dart';
import 'package:kass_dalle/features/admin/domain/log_entry.dart';
import 'package:kass_dalle/features/admin/domain/log_scan_group.dart';

/// Le regroupement des journaux en trois niveaux, et l'addition des coûts.
///
/// Ce qui se casse ici ne lève aucune erreur : un appel rattaché au mauvais
/// scan, ou compté deux fois, produit un total qui s'affiche normalement et
/// qui est faux. C'est la même famille de panne que la grille tarifaire.
LogEntry _entry({
  required String timestamp,
  String severity = 'INFO',
  String? correlationId,
  String? scanId,
  String? callId,
  String? feature,
  String message = 'message',
}) {
  return LogEntry(
    timestamp: timestamp,
    severity: severity,
    labels: {
      'correlationId': ?correlationId,
      'scanId': ?scanId,
      'callId': ?callId,
      'feature': ?feature,
    },
    payload: {'message': message},
  );
}

AiCall _call({
  String? callId,
  String? correlationId,
  String? scanId,
  String feature = 'transcription_page',
  double? costUsd = 0.01,
  String status = 'ok',
  String timestamp = '2026-08-30T10:00:00.000Z',
}) {
  return AiCall(
    callId: callId,
    correlationId: correlationId,
    scanId: scanId,
    feature: feature,
    provider: 'gemini',
    model: 'gemini-2.5-flash',
    status: status,
    inputTokens: 100,
    outputTokens: 50,
    totalTokens: 150,
    costUsd: costUsd,
    timestamp: DateTime.parse(timestamp),
  );
}

void main() {
  group('correlationRoot', () {
    test('l\'horodatage tombe, la racine reste', () {
      expect(
        correlationRoot('import_recette_1756540000000_ab12cd34'),
        'import_recette',
      );
    });

    test(
      'le suffixe de page d\'une détection d\'illustrations tombe aussi',
      () {
        // Sans cela, chaque page ouvrait un traitement dont le nom ne se
        // traduisait pas : « import_recette_1756…_ab12_p2 ».
        expect(
          correlationRoot('import_recette_1756540000000_ab12cd34_p2'),
          'import_recette',
        );
      },
    );

    test('un UUID ne nomme rien', () {
      expect(correlationRoot('3f2a1b4c-5d6e-7f80-9a1b-2c3d4e5f6071'), isNull);
    });
  });

  group('groupLogsByScan — niveau 1', () {
    test('les quatre traitements d\'un scan ne font qu\'un groupe', () {
      final entries = [
        _entry(
          timestamp: '2026-08-30T10:00:03.000Z',
          correlationId: 'ecriture_recette:creation_1756540003000_dd',
          scanId: 'scan_1',
        ),
        _entry(
          timestamp: '2026-08-30T10:00:02.000Z',
          correlationId: 'import_recette_1756540002000_cc_p1',
          scanId: 'scan_1',
        ),
        _entry(
          timestamp: '2026-08-30T10:00:01.000Z',
          correlationId: 'import_recette_1756540002000_cc',
          scanId: 'scan_1',
        ),
        _entry(
          timestamp: '2026-08-30T10:00:00.000Z',
          correlationId: 'upload_security_scan_1756540000000_bb',
          scanId: 'scan_1',
        ),
      ];

      final groups = groupLogsByScan(entries, const []);

      expect(groups, hasLength(1));
      expect(groups.single.isScan, isTrue);
      expect(groups.single.label, 'Scan d\'une page de livre');
      expect(groups.single.entryCount, 4);
      // La détection d'illustrations d'une page partage la racine de l'import :
      // trois traitements nommés, pas quatre. Dans l'ordre du déroulement.
      expect(groups.single.treatments, [
        'Contrôle du fichier importé',
        'Import d\'une recette',
        'Après écriture d\'une recette — Recette créée',
      ]);
    });

    test(
      'un appel dont seule la corrélation est connue rejoint quand même son scan',
      () {
        // Cas des lignes de consommation écrites avant que `scan_id` existe :
        // une entrée qui porte les deux étiquettes suffit à rattacher tout le
        // traitement.
        final entries = [
          _entry(
            timestamp: '2026-08-30T10:00:00.000Z',
            correlationId: 'ecriture_recette:creation_1756540000000_dd',
            scanId: 'scan_1',
          ),
        ];
        final calls = [
          _call(
            callId: 'call_1',
            correlationId: 'ecriture_recette:creation_1756540000000_dd',
            feature: 'estimate_piece_weights',
          ),
        ];

        final groups = groupLogsByScan(entries, calls);

        expect(groups, hasLength(1));
        expect(groups.single.key, 'scan_1');
        expect(groups.single.total.calls, 1);
      },
    );

    test('sans scan, le traitement reste le groupe', () {
      final entries = [
        _entry(
          timestamp: '2026-08-30T10:00:00.000Z',
          correlationId: 'generation_recette_1756540000000_aa',
        ),
      ];

      final groups = groupLogsByScan(entries, const []);

      expect(groups.single.isScan, isFalse);
      expect(groups.single.label, 'Génération d\'une recette par l\'IA');
    });

    test('une couverture de livre se nomme par son poste', () {
      final entries = [
        _entry(
          timestamp: '2026-08-30T10:00:00.000Z',
          correlationId: 'import_recette_1756540000000_cc',
          scanId: 'scan_2',
        ),
      ];
      final calls = [
        _call(
          callId: 'c1',
          scanId: 'scan_2',
          correlationId: 'import_recette_1756540000000_cc',
          feature: 'book_cover',
        ),
      ];

      expect(
        groupLogsByScan(entries, calls).single.label,
        'Scan d\'une couverture',
      );
    });

    test('un appel sans aucune ligne de journal ouvre son groupe', () {
      // Son coût est réel. L'écarter parce qu'aucune ligne ne le mentionne
      // amputerait le total sans que rien ne le dise.
      final groups = groupLogsByScan(const [], [
        _call(callId: 'c1', scanId: 'scan_3', correlationId: 'import_1'),
      ]);

      expect(groups, hasLength(1));
      expect(groups.single.total.calls, 1);
      expect(groups.single.entryCount, 0);
    });
  });

  group('groupLogsByScan — niveau 2 et 3', () {
    test('les lignes d\'un appel se rangent sous cet appel', () {
      final entries = [
        _entry(
          timestamp: '2026-08-30T10:00:02.000Z',
          correlationId: 'import_recette_1756540000000_cc',
          scanId: 'scan_1',
          callId: 'call_a',
          message: 'Appel IA terminé',
        ),
        _entry(
          timestamp: '2026-08-30T10:00:01.000Z',
          correlationId: 'import_recette_1756540000000_cc',
          scanId: 'scan_1',
          callId: 'call_a',
          severity: 'DEBUG',
          message: 'Appel IA démarré',
        ),
        _entry(
          timestamp: '2026-08-30T10:00:00.000Z',
          correlationId: 'import_recette_1756540000000_cc',
          scanId: 'scan_1',
          message: 'Pipeline démarré',
        ),
      ];
      final calls = [
        _call(callId: 'call_a', scanId: 'scan_1', correlationId: 'import_1'),
      ];

      final items = groupLogsByScan(entries, calls).single.items;

      expect(items, hasLength(2));
      // L'étape du pipeline vient d'abord : les éléments suivent le temps.
      expect(items.first, isA<EntryItem>());
      final call = items.last as CallItem;
      expect(call.call, isNotNull);
      expect(call.entries, hasLength(2));
    });

    test(
      'une ligne dont l\'appel n\'a pas été lu ouvre un appel sans montant',
      () {
        final entries = [
          _entry(
            timestamp: '2026-08-30T10:00:00.000Z',
            correlationId: 'import_recette_1756540000000_cc',
            scanId: 'scan_1',
            callId: 'call_orphelin',
          ),
        ];

        final items = groupLogsByScan(entries, const []).single.items;

        expect(items, hasLength(1));
        final call = items.single as CallItem;
        expect(call.call, isNull);
        expect(call.entries, hasLength(1));
      },
    );
  });

  group('AiCostTotal', () {
    test('le total additionne, et compte à part ce qu\'il ne sait pas', () {
      final total = AiCostTotal.of([
        _call(callId: 'a', costUsd: 0.01),
        _call(callId: 'b', costUsd: 0.02),
        _call(callId: 'c', costUsd: null),
      ]);

      expect(total.calls, 3);
      expect(total.unpricedCalls, 1);
      expect(total.costUsd, closeTo(0.03, 1e-9));
      expect(total.totalTokens, 450);
    });

    test('un appel non chiffré n\'ajoute pas zéro : il ajoute un manque', () {
      // Ajouter zéro le ferait passer pour gratuit. Le compteur séparé est le
      // seul moyen de lire « 0,03 » comme un minimum et non comme un total.
      final total = AiCostTotal.of([_call(callId: 'a', costUsd: null)]);
      expect(total.costUsd, 0);
      expect(total.unpricedCalls, 1);
      expect(total.calls, 1);
    });
  });

  group('mergeAiCalls', () {
    test('un appel présent dans deux pages n\'est compté qu\'une fois', () {
      // Deux pages voisines partagent souvent un traitement : sans cette
      // fusion, le coût du scan doublait à chaque « Charger la suite ».
      final a = _call(callId: 'call_a');
      final merged = mergeAiCalls([a], [a, _call(callId: 'call_b')]);

      expect(merged, hasLength(2));
      expect(AiCostTotal.of(merged).costUsd, closeTo(0.02, 1e-9));
    });

    test('deux appels anciens sans identifiant restent distincts', () {
      final merged = mergeAiCalls(
        [
          _call(
            correlationId: 'c1',
            feature: 'enrich_unit_weights',
            timestamp: '2026-08-30T10:00:00.000Z',
          ),
        ],
        [
          _call(
            correlationId: 'c1',
            feature: 'enrich_unit_weights',
            timestamp: '2026-08-30T10:00:05.000Z',
          ),
        ],
      );

      expect(merged, hasLength(2));
    });
  });

  group('montants', () {
    test('sans taux, le montant reste en dollars', () {
      // Convertir avec une constante du code afficherait un montant périmé
      // présenté comme exact.
      final rendu = formatCost(0.0123, null);
      expect(rendu, startsWith('0,0123'));
      expect(rendu, isNot(contains('€')));
    });

    test('avec un taux, le montant passe en euros', () {
      expect(formatCost(1.0, 0.9), '0,90 €');
    });

    test('les zéros de fin tombent, les millionièmes restent', () {
      // Six décimales fixes noieraient « 0,90 € » ; deux décimales fixes
      // afficheraient « 0,00 € » pour un appel à quatre millionièmes de
      // dollar, et un montant nul est ce qu'on ne veut jamais montrer à la
      // place d'un montant réel.
      expect(formatCost(0.000004, 1.0), '0,000004 €');
      expect(formatCost(12.5, 1.0), '12,50 €');
      expect(formatCost(0.9, 1.0), '0,90 €');
    });

    test('un coût inconnu se dit, il ne vaut pas zéro', () {
      expect(formatCost(null, 0.9), 'sans montant');
    });

    test('un total entièrement non chiffré ne s\'affiche pas à zéro', () {
      final total = AiCostTotal.of([
        _call(callId: 'a', costUsd: null),
        _call(callId: 'b', costUsd: null),
      ]);
      expect(formatTotal(total, 0.9), 'sans montant · 2 appel(s)');
    });

    test('un total partiel dit ce qu\'il ne couvre pas', () {
      final total = AiCostTotal.of([
        _call(callId: 'a', costUsd: 0.01),
        _call(callId: 'b', costUsd: null),
      ]);
      expect(formatTotal(total, 1.0), '0,01 € · 2 appel(s) · 1 sans montant');
    });
  });
}
