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
Recipe _recette({
  String? level,
  List<FidelityFinding> findings = const [],
  ReviewStatus statut = ReviewStatus.draft,
  IllustrationReport? photos,
}) => Recipe(
  id: 'r1',
  titre: 'Gravlax',
  langue: 'fr',
  rawCooklang: 'Posez le filet.',
  imageUrls: const [],
  reviewStatus: statut,
  tags: const RecipeTags(),
  ingredientsIndex: const [],
  createdBy: 'uid',
  createdAt: DateTime(2026, 8, 20),
  updatedAt: DateTime(2026, 8, 20),
  fidelityLevel: level,
  fidelityFindings: findings,
  illustrationReport: photos,
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
        findings: const [
          FidelityFinding(
            message: '4 ingrédient(s) normalisé(s) pour 5 ligne(s).',
          ),
        ],
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
        findings: const [
          FidelityFinding(
            message: 'Titre de section raccourci : pour la sauce.',
          ),
        ],
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
    final source = _recette(
      level: 'rupture',
      findings: const [FidelityFinding(message: 'un constat')],
    );
    final copie = source.copyWith(reviewStatus: ReviewStatus.validated);
    expect(copie.fidelityLevel, 'rupture');
    expect(copie.fidelityFindings.single.message, 'un constat');
    expect(copie.fidelityRejected, isTrue);
  });

  test('le verdict part bien vers Firestore', () {
    final map = _recette(
      level: 'avertissement',
      findings: const [FidelityFinding(message: 'un constat')],
    ).toFirestore();
    expect(map['fidelity_level'], 'avertissement');
    expect(map['fidelity_findings'], [
      {'message': 'un constat'},
    ]);
  });

  test('une recette fidele n ecrit aucun champ de fidelite', () {
    // Le cas normal ne doit pas alourdir chaque document d un champ vide.
    final map = _recette().toFirestore();
    expect(map.containsKey('fidelity_level'), isFalse);
    expect(map.containsKey('fidelity_findings'), isFalse);
  });
  testWidgets("une recette validee ne rappelle plus la reserve", (
    tester,
  ) async {
    // La reserve a fait son office: elle a dit ou regarder, quelqu un a
    // regarde et a tranche. La rappeler ensuite reviendrait a contester cette
    // decision indefiniment - et une alerte qui ne s eteint jamais cesse d
    // etre lue, y compris sur les brouillons ou elle compte.
    await _pump(
      tester,
      _recette(
        level: "rupture",
        findings: const [FidelityFinding(message: "un constat")],
        statut: ReviewStatus.validated,
      ),
    );
    expect(find.textContaining("livre"), findsNothing);
    expect(find.textContaining("un constat"), findsNothing);
  });
  testWidgets("les elements s affichent en puces, pas en pave", (tester) async {
    // Sept mots mal lus concatenes dans une phrase formaient un bloc qu on ne
    // relisait pas - et une alerte qu on ne relit pas ne sert a rien.
    await _pump(
      tester,
      _recette(
        level: "avertissement",
        findings: const [
          FidelityFinding(
            message: "Mot(s) mal lu(s) :",
            items: ["peau en dessous", "a l aneth"],
          ),
        ],
      ),
    );
    expect(find.textContaining("peau en dessous"), findsOneWidget);
    expect(find.textContaining("a l aneth"), findsOneWidget);
  });

  testWidgets("le bandeau se replie et se rouvre", (tester) async {
    // Ouvert au premier affichage: une reserve qu il faut aller chercher n en
    // est pas une. Mais il occupe le haut de l ecran, et on vient d abord y
    // relire la recette.
    await _pump(
      tester,
      _recette(
        level: "avertissement",
        findings: const [FidelityFinding(message: "un constat")],
      ),
    );
    expect(find.textContaining("un constat"), findsOneWidget);
    await tester.tap(find.byIcon(Icons.expand_less));
    await tester.pump();
    expect(find.textContaining("un constat"), findsNothing);
    await tester.tap(find.byIcon(Icons.expand_more));
    await tester.pump();
    expect(find.textContaining("un constat"), findsOneWidget);
  });
  testWidgets("aucune photo reperee: on le dit, et on dit quoi faire", (
    tester,
  ) async {
    // Trois causes possibles - page sans photo, filtres trop severes, panne -
    // et trois reactions opposees. L ecran ne disait rien qui permette de
    // choisir.
    await _pump(
      tester,
      _recette(
        photos: const IllustrationReport(
          detectees: 0,
          retenues: 0,
          publiees: 0,
          pagesEnEchec: 0,
        ),
      ),
    );
    expect(find.textContaining('Aucune photo repérée'), findsOneWidget);
    expect(find.textContaining('à la main'), findsOneWidget);
  });

  testWidgets(
    "une panne de detection ne se lit pas comme une page sans photo",
    (tester) async {
      await _pump(
        tester,
        _recette(
          photos: const IllustrationReport(
            detectees: 0,
            retenues: 0,
            publiees: 0,
            pagesEnEchec: 2,
          ),
        ),
      );
      expect(find.textContaining('a échoué'), findsOneWidget);
      expect(find.textContaining('Aucune photo repérée'), findsNothing);
    },
  );

  testWidgets("des photos vues puis toutes ecartees se disent autrement", (
    tester,
  ) async {
    await _pump(
      tester,
      _recette(
        photos: const IllustrationReport(
          detectees: 3,
          retenues: 1,
          publiees: 0,
          pagesEnEchec: 0,
        ),
      ),
    );
    expect(find.textContaining('3 photo(s) repérée(s)'), findsOneWidget);
  });

  testWidgets("une photo publiee ne declenche aucun message", (tester) async {
    // Elle se voit: l annoncer serait du bruit.
    await _pump(
      tester,
      _recette(
        photos: const IllustrationReport(
          detectees: 1,
          retenues: 1,
          publiees: 1,
          pagesEnEchec: 0,
        ),
      ),
    );
    expect(find.byType(Icon), findsNothing);
  });
}
