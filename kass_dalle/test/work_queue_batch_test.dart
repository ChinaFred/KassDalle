import 'package:flutter_test/flutter_test.dart';
import 'package:kass_dalle/features/recipes/domain/recipe.dart';
import 'package:kass_dalle/features/recipes/presentation/drafts/work_queue_batch.dart';

/// Ce que la file « Brouillons & Traitements » fait d'une sélection multiple.
///
/// Valider un lot est un geste sans relecture : ces tests verrouillent ce qui
/// reste de côté (réserve de fidélité, contenu vide) et les phrases qui le
/// disent à l'utilisateur.
Recipe _brouillon({
  String id = 'r1',
  String raw = 'Posez le filet.',
  String? draft,
  String? fidelity,
}) => Recipe(
  id: id,
  titre: 'Gravlax $id',
  langue: 'fr',
  rawCooklang: raw,
  draftCooklang: draft,
  imageUrls: const [],
  reviewStatus: ReviewStatus.draft,
  tags: const RecipeTags(),
  ingredientsIndex: const [],
  createdBy: 'uid',
  createdAt: DateTime(2026, 9, 1),
  updatedAt: DateTime(2026, 9, 1),
  fidelityLevel: fidelity,
);

void main() {
  group('draftContent', () {
    test('la copie de travail passe avant l\'import', () {
      expect(
        draftContent(_brouillon(raw: 'import', draft: 'retouché')),
        'retouché',
      );
    });

    test('sans copie de travail, l\'import est validé', () {
      expect(draftContent(_brouillon(raw: 'import')), 'import');
    });

    test('une copie de travail vide ne remplace pas l\'import', () {
      // Valider écrit ce texte dans `raw_cooklang` : une chaîne vide
      // effacerait la recette.
      expect(draftContent(_brouillon(raw: 'import', draft: '  \n')), 'import');
    });
  });

  group('planDraftValidation', () {
    test('un brouillon sans réserve ni vide est validé', () {
      final plan = planDraftValidation([
        _brouillon(id: 'a'),
        _brouillon(id: 'b'),
      ]);
      expect(plan.toValidate.map((r) => r.id), ['a', 'b']);
      expect(plan.skipped, 0);
    });

    test(
      'une réserve de fidélité, rupture ou avertissement, reste de côté',
      () {
        final plan = planDraftValidation([
          _brouillon(id: 'ok'),
          _brouillon(id: 'rupture', fidelity: 'rupture'),
          _brouillon(id: 'avertissement', fidelity: 'avertissement'),
        ]);
        expect(plan.toValidate.map((r) => r.id), ['ok']);
        expect(plan.withFidelityReserve.map((r) => r.id), [
          'rupture',
          'avertissement',
        ]);
      },
    );

    test('un niveau de fidélité vide n\'est pas une réserve', () {
      final plan = planDraftValidation([_brouillon(fidelity: '')]);
      expect(plan.toValidate, hasLength(1));
    });

    test('un brouillon sans contenu reste de côté', () {
      final plan = planDraftValidation([_brouillon(raw: '  ', draft: '')]);
      expect(plan.toValidate, isEmpty);
      expect(plan.emptyContent, hasLength(1));
    });

    test('un brouillon vide et à réserve est compté comme vide, une fois', () {
      final plan = planDraftValidation([
        _brouillon(raw: '', fidelity: 'rupture'),
      ]);
      expect(plan.emptyContent, hasLength(1));
      expect(plan.withFidelityReserve, isEmpty);
    });
  });

  group('libellés', () {
    test('zéro et un prennent le singulier', () {
      expect(countOf(0, 'brouillon', 'brouillons'), '0 brouillon');
      expect(countOf(1, 'brouillon', 'brouillons'), '1 brouillon');
      expect(countOf(2, 'brouillon', 'brouillons'), '2 brouillons');
    });

    test('la sélection dit ce qu\'elle contient', () {
      expect(
        selectionLabel(drafts: 5, jobs: 2),
        '5 brouillons et 2 traitements',
      );
      expect(selectionLabel(drafts: 1, jobs: 0), '1 brouillon');
      expect(selectionLabel(drafts: 0, jobs: 3), '3 traitements');
    });
  });

  group('validationSummary', () {
    test('tout validé', () {
      final plan = planDraftValidation([
        _brouillon(id: 'a'),
        _brouillon(id: 'b'),
      ]);
      expect(validationSummary(plan, failed: 0), '2 brouillons validés.');
    });

    test('un seul brouillon validé', () {
      final plan = planDraftValidation([_brouillon()]);
      expect(validationSummary(plan, failed: 0), '1 brouillon validé.');
    });

    test('les échecs sont comptés en plus des validés', () {
      final plan = planDraftValidation([
        _brouillon(id: 'a'),
        _brouillon(id: 'b'),
        _brouillon(id: 'c'),
      ]);
      expect(
        validationSummary(plan, failed: 1),
        '2 brouillons validés, 1 en échec.',
      );
    });

    test('ce qui reste de côté est nommé avec sa raison', () {
      final plan = planDraftValidation([
        _brouillon(id: 'ok'),
        _brouillon(id: 'r1', fidelity: 'rupture'),
        _brouillon(id: 'r2', fidelity: 'avertissement'),
        _brouillon(id: 'v', raw: ''),
      ]);
      expect(
        validationSummary(plan, failed: 0),
        '1 brouillon validé. Non validés : '
        '2 avec réserve de fidélité, à relire un par un, 1 sans contenu.',
      );
    });

    test('rien de validé quand tout reste de côté', () {
      final plan = planDraftValidation([_brouillon(fidelity: 'rupture')]);
      expect(
        validationSummary(plan, failed: 0),
        'Aucun brouillon validé. Non validés : '
        '1 avec réserve de fidélité, à relire un par un.',
      );
    });

    test('pas de note quand tout est admis', () {
      expect(notValidatedNote(planDraftValidation([_brouillon()])), isNull);
    });
  });

  group('actionSummary', () {
    test('suppression réussie', () {
      expect(
        actionSummary(verb: 'Supprimé', drafts: 4, jobs: 1, failed: 0),
        'Supprimés : 4 brouillons et 1 traitement.',
      );
    });

    test('un seul élément traité prend le singulier', () {
      expect(
        actionSummary(verb: 'Supprimé', drafts: 1, jobs: 0, failed: 0),
        'Supprimé : 1 brouillon.',
      );
    });

    test('les échecs sont ajoutés', () {
      expect(
        actionSummary(verb: 'Relancé', drafts: 0, jobs: 2, failed: 1),
        'Relancés : 2 traitements. 1 en échec.',
      );
    });

    test('tout en échec', () {
      expect(
        actionSummary(verb: 'Supprimé', drafts: 0, jobs: 0, failed: 3),
        'Aucun élément supprimé, 3 en échec.',
      );
    });
  });
}
