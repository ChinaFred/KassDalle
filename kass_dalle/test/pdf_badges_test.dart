import 'package:flutter_test/flutter_test.dart';
import 'package:kass_dalle/core/services/recipe_pdf_export.dart';
import 'package:pdf/widgets.dart' as pw;

/// Les badges du PDF : ce qu'ils portent, et ce qu'ils ne laissent pas passer.
///
/// Le PDF imprimait le CookLang débarrassé de sa syntaxe. Le lecteur ne pouvait
/// pas savoir que « carotte » n'était pas un mot de la phrase mais une
/// référence structurée — d'où une faute d'accord apparente et une syntaxe
/// invisible. Le badge sort le jeton du fil de la phrase, comme la puce le fait
/// déjà à l'écran.
void main() {
  final regular = pw.Font.helvetica();
  final bold = pw.Font.helveticaBold();

  List<String> spansOf(String raw) {
    final widget = cooklangRichText(
      raw,
      regular: regular,
      bold: bold,
      fontSize: 10,
    );
    final rich = widget as pw.RichText;
    final children = (rich.text as pw.TextSpan).children ?? const [];
    return children
        .whereType<pw.TextSpan>()
        .map((s) => s.text ?? '')
        .toList(growable: false);
  }

  bool isBadge(pw.TextSpan span) => span.style?.background != null;

  List<String> badgesOf(String raw) {
    final rich =
        cooklangRichText(raw, regular: regular, bold: bold, fontSize: 10)
            as pw.RichText;
    final children = (rich.text as pw.TextSpan).children ?? const [];
    return children
        .whereType<pw.TextSpan>()
        .where(isBadge)
        .map((s) => (s.text ?? '').trim())
        .toList(growable: false);
  }

  test('un ingrédient devient un badge accordé, pas un mot de la phrase', () {
    expect(
      badgesOf(
        'Émincer finement les @carotte{2%pièces} et le @poivron{1%pièces}.',
      ),
      ['2 carottes', '1 poivron'],
    );
  });

  test('le matériel et les minuteurs aussi', () {
    expect(badgesOf('Chauffer la #poêle{} puis cuire ~{0:12:00}.'), [
      'poêle',
      '12 minutes',
    ]);
  });

  test('le texte entre les jetons est conservé mot pour mot', () {
    final texte = spansOf('Ajouter le @sel{1%pincée} en fin de cuisson.');
    expect(texte.first, 'Ajouter le ');
    expect(texte.last, ' en fin de cuisson.');
  });

  test('une ligne sans jeton reste une ligne de texte', () {
    expect(badgesOf('Laisser reposer hors du feu.'), isEmpty);
    expect(spansOf('Laisser reposer hors du feu.'), [
      'Laisser reposer hors du feu.',
    ]);
  });

  test('les badges respirent : un espace insécable les borde', () {
    final rich =
        cooklangRichText(
              'Ajouter le @sel{1%pincée}.',
              regular: regular,
              bold: bold,
              fontSize: 10,
            )
            as pw.RichText;
    final badge = ((rich.text as pw.TextSpan).children ?? const [])
        .whereType<pw.TextSpan>()
        .firstWhere(isBadge);
    expect(badge.text, startsWith(' '));
    expect(badge.text, endsWith(' '));
  });
}
