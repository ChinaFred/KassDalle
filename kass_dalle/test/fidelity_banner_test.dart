import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kass_dalle/features/recipes/domain/recipe.dart';
import 'package:kass_dalle/features/recipes/presentation/fidelity_banner.dart';

/// Le verdict de fidélité doit se LIRE.
///
/// Ce que ces tests verrouillent : un écart constaté à l'import arrive sous les
/// yeux de qui relit la recette. Un champ produit et jamais affiché finit par
/// mentir sans que personne s'en aperçoive — c'est précisément le défaut que ce
/// contrôle est censé attraper.
Recipe _recette({String? level, List<String> findings = const []}) => Recipe(
  id: 'r1',
  titre: 'Gravlax',
  langue: 'fr',
  rawCooklang: 'Posez le filet.',
  imageUrls: const [],
  reviewStatus: ReviewStatus.draft,
  tags: const RecipeTags(),
  ingredientsIndex: const [],
  createdBy: 'uid',
  createdAt: DateTime(2026, 8, 20),
  updatedAt: DateTime(2026, 8, 20),
  fidelityLevel: level,
  fidelityFindings: findings,
);

Future<void> _pump(WidgetTester tester, Recipe recipe) => tester.pumpWidget(
  MaterialApp(
    home: Scaffold(body: FidelityBanner(recipe: recipe)),
  ),
);

void main() {
  testWidgets('une recette fidèle n\'affiche aucun bandeau', (tester) async {
    await _pump(tester, _recette());
    expect(find.byType(Icon), findsNothing);
    expect(find.textContaining('livre'), findsNothing);
  });

  testWidgets('une rupture dit que le texte est conservé sans balise', (
    tester,
  ) async {
    // C'est l'information dont le lecteur a besoin : la recette est exacte,
    // mais ses ingrédients ne sont pas mis en évidence — inutile de chercher
    // pourquoi les puces manquent.
    await _pump(
      tester,
      _recette(
        level: 'rupture',
        findings: const ['4 ingrédient(s) normalisé(s) pour 5 ligne(s).'],
      ),
    );
    expect(find.textContaining('sans balise'), findsOneWidget);
    expect(find.textContaining('4 ingrédient(s)'), findsOneWidget);
    expect(find.textContaining('Raffiner'), findsOneWidget);
  });

  testWidgets('un avertissement ne prétend pas que le balisage est perdu', (
    tester,
  ) async {
    await _pump(
      tester,
      _recette(
        level: 'avertissement',
        findings: const ['Titre de section raccourci : pour la sauce.'],
      ),
    );
    expect(find.textContaining('Écart constaté'), findsOneWidget);
    expect(find.textContaining('sans balise'), findsNothing);
    expect(find.textContaining('Titre de section'), findsOneWidget);
  });

  testWidgets('un niveau sans constat affiche quand même l\'avertissement', (
    tester,
  ) async {
    // Le niveau est le fait principal ; l'absence de détail ne doit pas faire
    // disparaître le bandeau, sinon l'écart devient invisible.
    await _pump(tester, _recette(level: 'avertissement'));
    expect(find.textContaining('Écart constaté'), findsOneWidget);
  });

  test('le verdict survit à une copie de la recette', () {
    // Valider ou renommer une recette ne la rend pas plus fidèle au livre.
    final source = _recette(level: 'rupture', findings: const ['un constat']);
    final copie = source.copyWith(reviewStatus: ReviewStatus.validated);
    expect(copie.fidelityLevel, 'rupture');
    expect(copie.fidelityFindings, ['un constat']);
    expect(copie.fidelityRejected, isTrue);
  });

  test('le verdict part bien vers Firestore', () {
    final map = _recette(
      level: 'avertissement',
      findings: const ['un constat'],
    ).toFirestore();
    expect(map['fidelity_level'], 'avertissement');
    expect(map['fidelity_findings'], ['un constat']);
  });

  test('une recette fidele n ecrit aucun champ de fidelite', () {
    // Le cas normal ne doit pas alourdir chaque document d un champ vide.
    final map = _recette().toFirestore();
    expect(map.containsKey('fidelity_level'), isFalse);
    expect(map.containsKey('fidelity_findings'), isFalse);
  });
}
