import 'package:flutter_test/flutter_test.dart';
import 'package:kass_dalle/core/services/recipe_pdf_export.dart';
import 'package:kass_dalle/features/recipes/domain/recipe.dart';
import 'package:pdf/widgets.dart' as pw;

/// La remarque d'un ingrédient sur la fiche imprimée.
///
/// Elle s'affichait à l'écran et disparaissait du PDF — c'est-à-dire au moment
/// précis où l'on emporte la recette en cuisine. « Avec la peau mais
/// écaillée », « concassés », « à température ambiante » : ce que le livre
/// disait en plus de la quantité ne survivait pas à l'impression.
///
/// Une remarque absente ne lève aucune erreur et ne se voit sur aucun écran.
/// C'est le seul genre de perte qu'un test doit tenir.
void main() {
  final regular = pw.Font.helvetica();
  final oblique = pw.Font.helveticaOblique();

  RecipeIngredient ing({String? note}) =>
      RecipeIngredient(name: 'tomate', qty: '3', unit: 'piece', note: note);

  /// Les fragments de texte d'une ligne d'ingrédient, dans l'ordre.
  List<String> textsOf(RecipeIngredient ingredient) {
    final row = ingredientPdfRow(ingredient, regular, oblique);
    final texts = <String>[];

    void walk(pw.Widget widget) {
      if (widget is pw.Text) {
        texts.add(widget.text.toPlainText());
        return;
      }
      if (widget is pw.RichText) {
        final span = widget.text;
        if (span is pw.TextSpan) {
          if (span.text != null) texts.add(span.text!);
          for (final child in span.children ?? const <pw.InlineSpan>[]) {
            if (child is pw.TextSpan && child.text != null) {
              texts.add(child.text!);
            }
          }
        }
        return;
      }
      if (widget is pw.Padding) {
        if (widget.child != null) walk(widget.child!);
        return;
      }
      if (widget is pw.Row) {
        for (final child in widget.children) {
          walk(child);
        }
        return;
      }
      if (widget is pw.Expanded) {
        final child = widget.child;
        if (child != null) walk(child);
        return;
      }
    }

    walk(row);
    return texts;
  }

  test('la remarque suit l\'ingrédient, entre parenthèses', () {
    final texts = textsOf(ing(note: 'bien mûres'));
    expect(texts.join(), contains('(bien mûres)'));
  });

  test('la remarque vient APRÈS le libellé, jamais avant', () {
    final texts = textsOf(ing(note: 'bien mûres'));
    final joined = texts.join();
    expect(joined.indexOf('tomate'), lessThan(joined.indexOf('(bien mûres)')));
  });

  test('sans remarque, aucune parenthèse vide ne s\'imprime', () {
    expect(textsOf(ing()).join(), isNot(contains('(')));
  });

  test('une remarque blanche ne compte pas pour une remarque', () {
    // Le champ vient de l'éditeur et du serveur : une chaîne d'espaces y arrive
    // aussi sûrement qu'un `null`, et imprimerait « ( ) ».
    expect(textsOf(ing(note: '   ')).join(), isNot(contains('(')));
  });
}
