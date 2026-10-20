import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:kass_dalle/core/theme/app_theme.dart';
import 'package:kass_dalle/features/recipes/presentation/editor/cooklang_block_widgets.dart';
import 'package:kass_dalle/features/recipes/presentation/editor/cooklang_editor_colors.dart';
import 'package:kass_dalle/features/recipes/presentation/editor/cooklang_syntax_controller.dart';
import 'package:kass_dalle/features/recipes/presentation/editor/cooklang_visual_editor.dart';
import 'package:kass_dalle/features/recipes/presentation/editor/hybrid_recipe_editor.dart';
import 'package:kass_dalle/features/recipes/presentation/editor/markdown_visual_editor.dart';

double contrast(Color a, Color b) {
  final la = a.computeLuminance();
  final lb = b.computeLuminance();
  final hi = la > lb ? la : lb;
  final lo = la > lb ? lb : la;
  return (hi + 0.05) / (lo + 0.05);
}

const _recipe = '''>> portions: 4
## Préparation
Dans un #bol, mélanger @farine{200%g} et @sucre{50%g}.
+ Laisser reposer ~{10%minutes}.
-- un commentaire
''';

Widget _app(Widget child, {ThemeData? theme}) => MaterialApp(
  theme: theme ?? AppTheme.light,
  home: Scaffold(body: child),
);

void main() {
  group('CooklangPalette', () {
    for (final entry in {
      'clair': AppTheme.light,
      'sombre': AppTheme.dark,
    }.entries) {
      test('contraste ≥ 4,5:1 sur surfaceContainerLowest, ${entry.key}', () {
        final palette = CooklangPalette.of(entry.value.brightness);
        final bg = entry.value.colorScheme.surfaceContainerLowest;
        for (final c in palette.all) {
          expect(contrast(c, bg), greaterThanOrEqualTo(4.5), reason: '$c');
        }
      });
    }

    testWidgets('le contrôleur colore selon le thème', (tester) async {
      final ctrl = CooklangSyntaxController()..text = '@farine{200%g}';
      addTearDown(ctrl.dispose);
      late TextSpan span;
      await tester.pumpWidget(
        _app(
          Builder(
            builder: (context) {
              span = ctrl.buildTextSpan(context: context, withComposing: false);
              return const SizedBox();
            },
          ),
          theme: AppTheme.dark,
        ),
      );
      final first = span.children!.first as TextSpan;
      expect(first.style!.color, CooklangPalette.dark.ingredient);
    });
  });

  group('CooklangBlockRow', () {
    testWidgets('poignée et « Supprimer la ligne » : cibles conformes', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      await tester.pumpWidget(
        _app(
          ReorderableListView(
            buildDefaultDragHandles: false,
            onReorderItem: (_, _) {},
            children: [
              CooklangBlockRow(
                key: const ValueKey('row'),
                index: 0,
                enabled: true,
                onTap: () {},
                onDelete: () {},
                child: const Text('Mélanger la farine'),
              ),
            ],
          ),
        ),
      );
      expect(find.byTooltip('Supprimer la ligne'), findsOneWidget);
      final del = tester.getSize(find.byType(IconButton));
      expect(del.width, greaterThanOrEqualTo(48));
      expect(del.height, greaterThanOrEqualTo(48));
      final grip = tester.getSize(
        find.ancestor(
          of: find.byIcon(Icons.drag_indicator),
          matching: find.byType(SizedBox),
        ),
      );
      expect(grip.width, greaterThanOrEqualTo(48));
      expect(grip.height, greaterThanOrEqualTo(48));
      await expectLater(tester, meetsGuideline(androidTapTargetGuideline));
      await expectLater(tester, meetsGuideline(iOSTapTargetGuideline));
      handle.dispose();
    });
  });

  group('CooklangVisualEditor', () {
    testWidgets('thème sombre : fond foncé, texte lisible', (tester) async {
      final handle = tester.ensureSemantics();
      final ctrl = TextEditingController(text: _recipe);
      addTearDown(ctrl.dispose);
      await tester.binding.setSurfaceSize(const Size(800, 1000));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        _app(CooklangVisualEditor(ctrl: ctrl), theme: AppTheme.dark),
      );
      await tester.pumpAndSettle();
      final containers = tester.widgetList<Container>(find.byType(Container));
      expect(
        containers.any((c) => c.color == Colors.white),
        isFalse,
        reason: 'aucun fond blanc en thème sombre',
      );
      await expectLater(tester, meetsGuideline(textContrastGuideline));
      handle.dispose();
    });
  });

  group('MdVisualEditor', () {
    testWidgets('pas de poignée sans action, « Supprimer la ligne » à 48 px', (
      tester,
    ) async {
      final ctrl = TextEditingController(text: '# Titre\n\nUn paragraphe.\n');
      addTearDown(ctrl.dispose);
      await tester.pumpWidget(_app(MdVisualEditor(ctrl: ctrl)));
      await tester.pumpAndSettle();
      expect(find.byIcon(Icons.drag_indicator), findsNothing);
      final buttons = find.byTooltip('Supprimer la ligne');
      expect(buttons, findsWidgets);
      final size = tester.getSize(
        find.ancestor(of: buttons.first, matching: find.byType(IconButton)),
      );
      expect(size.width, greaterThanOrEqualTo(48));
      expect(size.height, greaterThanOrEqualTo(48));
    });
  });

  group('HybridRecipeEditor', () {
    testWidgets('barre à 360 px : aide à 48 px, sans débordement', (
      tester,
    ) async {
      final ctrl = TextEditingController(text: _recipe);
      addTearDown(ctrl.dispose);
      await tester.binding.setSurfaceSize(const Size(360, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        _app(
          HybridRecipeEditor(
            ctrl: ctrl,
            enabled: true,
            showHelp: true,
            previewWidget: const Text('Aperçu'),
            onProcessWithAI: () {},
            onImportFromUrl: () {},
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      final help = tester.getSize(
        find.ancestor(
          of: find.byIcon(Icons.help_outline),
          matching: find.byType(IconButton),
        ),
      );
      expect(help.width, greaterThanOrEqualTo(48));
      expect(help.height, greaterThanOrEqualTo(48));
    });
  });
}
