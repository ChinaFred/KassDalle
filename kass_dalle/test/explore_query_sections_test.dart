import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kass_dalle/features/recipes/domain/recipe_filter.dart';
import 'package:kass_dalle/features/search/domain/explore_facets.dart';
import 'package:kass_dalle/features/search/presentation/search_widgets.dart';

/// L'en-tête repliable d'une section de la recherche par texte : ligne de
/// 48 px au moins, bouton annoncé avec son état, bascule au doigt et au
/// clavier.
void main() {
  Future<List<bool>> pump(WidgetTester tester, {required bool open}) async {
    final toggles = <bool>[];
    var state = open;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: StatefulBuilder(
            builder: (context, setState) => QuerySectionHeader(
              title: 'Dans les ingrédients principaux',
              count: 4,
              open: state,
              onToggle: () => setState(() {
                state = !state;
                toggles.add(state);
              }),
            ),
          ),
        ),
      ),
    );
    return toggles;
  }

  testWidgets('libellé, compteur, cible de 48 px', (tester) async {
    await pump(tester, open: false);
    expect(find.text('Dans les ingrédients principaux (4)'), findsOneWidget);
    expect(
      tester.getSize(find.byType(QuerySectionHeader)).height,
      greaterThanOrEqualTo(48),
    );
    expect(find.byIcon(Icons.expand_more), findsOneWidget);
    expect(find.byTooltip('Afficher'), findsOneWidget);
  });

  testWidgets('annoncé comme bouton, avec son état', (tester) async {
    final handle = tester.ensureSemantics();
    await pump(tester, open: true);
    expect(
      tester.getSemantics(find.byType(QuerySectionHeader)),
      matchesSemantics(
        isButton: true,
        hasExpandedState: true,
        isExpanded: true,
        hasTapAction: true,
        isFocusable: true,
        hasFocusAction: true,
        label: 'Dans les ingrédients principaux (4)',
        tooltip: 'Masquer',
      ),
    );
    handle.dispose();
  });

  testWidgets('bascule au doigt, puis au clavier', (tester) async {
    final toggles = await pump(tester, open: false);
    await tester.tap(find.byType(QuerySectionHeader));
    await tester.pump();
    expect(toggles, [true]);
    expect(find.byIcon(Icons.expand_less), findsOneWidget);

    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.pump();
    expect(toggles, [true, false, true]);
  });

  test('la ligne grise cite le mot tel que tapé, accent compris', () {
    expect(titleOnlyQueryWords('Sésame'), ['Sésame']);
    expect(
      titleOnlyWordsLine(titleOnlyQueryWords('poulet Sésame')),
      '« Sésame » n\'est cherché que dans les titres.',
    );
    // Le repli ne sert qu'à dédoublonner : « sesame » après « Sésame »
    // n'est pas cité deux fois.
    expect(titleOnlyQueryWords('Sésame, sesame AIL'), ['Sésame', 'AIL']);
  });
}
