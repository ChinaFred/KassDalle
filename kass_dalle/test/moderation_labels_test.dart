import 'package:flutter_test/flutter_test.dart';
import 'package:kass_dalle/features/moderation/domain/moderation_labels.dart';

/// Toutes les clés servies par le serveur ont-elles un libellé ?
///
/// Le serveur écrit des clés (`sexual_explicit`, `manual_rejected`…) sur des
/// documents relus des mois plus tard. Une clé sans libellé s'affiche telle
/// quelle — ce qui est déjà mieux que de disparaître — mais un administrateur
/// devrait ne jamais avoir à lire une clé technique pour comprendre un refus.
///
/// Ces listes reflètent les unions de `functions/src/moderation/decision.ts` et
/// la projection de `functions/src/moderation/vision.ts`. Elles sont ici en
/// double, volontairement : c'est le même arbitrage que
/// `feature_catalog_test.dart`, où deux tables se gardent l'une l'autre. Un
/// motif ajouté côté serveur sans son libellé fait échouer ce test, et c'est
/// tout ce qu'on lui demande.
void main() {
  group('libellés de modération', () {
    // Miroir de `ModerationReason` (functions/src/moderation/decision.ts).
    const servedReasons = <String>[
      'sexual_explicit',
      'violence_no_culinary_context',
      'violent_content',
      'suggestive_content',
      'culinary_context',
      'no_signal',
      'moderation_disabled',
      'ai_generated',
      'bundled_asset',
      'unreadable_signal',
      'engine_unavailable',
      'manual_approved',
      'manual_rejected',
      'manual_folder_move',
    ];

    // Miroir de `ModerationStatus`.
    const servedStatuses = <String>[
      'approved',
      'rejected',
      'manual_review',
      'pending',
    ];

    // Miroir de `ModerationTargetKind` (functions/src/moderation/promote.ts).
    const servedTargets = <String>[
      'book_cover',
      'recipe_illustration',
      'draft_illustration',
      'free_recipe_cover',
    ];

    // Paliers projetés par `vision.ts`, `UNKNOWN` compris — c'est un état, pas
    // une absence, et il a donc son libellé propre.
    const servedLikelihoods = <String>[
      'VERY_UNLIKELY',
      'UNLIKELY',
      'POSSIBLE',
      'LIKELY',
      'VERY_LIKELY',
      'UNKNOWN',
    ];

    // Critères SafeSearch remontés par l'adaptateur.
    const servedCriteria = <String>[
      'adult',
      'racy',
      'violence',
      'medical',
      'spoof',
    ];

    test('tout motif servi a sa phrase', () {
      for (final key in servedReasons) {
        expect(
          kModerationReasons[key],
          isNotNull,
          reason:
              'Le motif « $key » est écrit par le serveur mais n\'a pas de '
              'libellé : un administrateur lirait une clé technique.',
        );
      }
    });

    test('tout état servi a son libellé', () {
      for (final key in servedStatuses) {
        expect(kModerationStatuses[key], isNotNull, reason: key);
      }
    });

    test('toute destination servie a son libellé', () {
      for (final key in servedTargets) {
        expect(kModerationTargets[key], isNotNull, reason: key);
      }
    });

    test('tout palier servi a son libellé, UNKNOWN compris', () {
      for (final key in servedLikelihoods) {
        expect(kModerationLikelihoods[key], isNotNull, reason: key);
      }
    });

    test('tout critère servi a son libellé', () {
      for (final key in servedCriteria) {
        expect(kModerationCriteria[key], isNotNull, reason: key);
      }
    });

    test(
      'une clé inconnue s\'affiche telle quelle plutôt que de disparaître',
      () {
        // Un motif qui s'évanouit de l'écran est un motif qu'on ne corrigera
        // jamais, puisque personne ne saura qu'il manque.
        expect(
          moderationLabel(kModerationReasons, 'motif_futur'),
          'motif_futur',
        );
      },
    );

    test('une clé absente rend un tiret, pas une chaîne vide', () {
      expect(moderationLabel(kModerationReasons, null), '—');
      expect(moderationLabel(kModerationReasons, ''), '—');
    });
  });
}
