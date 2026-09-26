import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kass_dalle/features/books/presentation/book_picker_field.dart';

import 'support/test_backend.dart';

/// Ce que le parent d'un `BookPickerField` a reçu, et ce qu'il lui redonne.
class _Host extends StatefulWidget {
  final List<Map<String, String>> log;
  final String? initialId;
  final String? noneLabel;
  final bool enabled;

  const _Host({
    required this.log,
    this.initialId,
    this.noneLabel,
    this.enabled = true,
  });

  @override
  State<_Host> createState() => _HostState();
}

class _HostState extends State<_Host> {
  late String? _id = widget.initialId;

  @override
  Widget build(BuildContext context) {
    final books = [
      testBook(id: 'b-sal', titre: 'Salades d\'été'),
      testBook(id: 'b-des', titre: 'Desserts'),
      testBook(id: 'b-pat', titre: 'Pâtisserie'),
      testBook(id: 'b-cook', titre: 'COOK'),
      testBook(id: 'b-cook2', titre: 'COOK 2'),
    ];
    return MaterialApp(
      home: Scaffold(
        body: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            children: [
              BookPickerField(
                books: books,
                selectedBookId: _id,
                noneLabel: widget.noneLabel,
                enabled: widget.enabled,
                onChanged: (id, titre) {
                  widget.log.add({'id': '$id', 'titre': '$titre'});
                  setState(() => _id = id);
                },
              ),
            ],
          ),
        ),
      ),
    );
  }
}

Finder _entry(String label) => find.widgetWithText(MenuItemButton, label);

String _fieldText(WidgetTester tester) => tester
    .widget<TextField>(
      find.descendant(
        of: find.byType(BookPickerField),
        matching: find.byType(TextField),
      ),
    )
    .controller!
    .text;

Future<void> _tapField(WidgetTester tester) async {
  await tester.tap(
    find.descendant(
      of: find.byType(BookPickerField),
      matching: find.byType(TextField),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('le champ montre le titre du livre actuel', (tester) async {
    await tester.pumpWidget(_Host(log: [], initialId: 'b-des'));
    await tester.pumpAndSettle();

    expect(_fieldText(tester), 'Desserts');
  });

  testWidgets(
    'taper des lettres réduit la liste aux titres qui les contiennent',
    (tester) async {
      await tester.pumpWidget(_Host(log: []));
      await tester.pumpAndSettle();
      await _tapField(tester);

      expect(_entry('Salades d\'été'), findsOneWidget);
      expect(_entry('Desserts'), findsOneWidget);
      expect(_entry('Pâtisserie'), findsOneWidget);

      await tester.enterText(
        find.descendant(
          of: find.byType(BookPickerField),
          matching: find.byType(TextField),
        ),
        'sal',
      );
      await tester.pumpAndSettle();

      expect(_entry('Salades d\'été'), findsOneWidget);
      expect(_entry('Desserts'), findsNothing);
      expect(_entry('Pâtisserie'), findsNothing);
    },
  );

  testWidgets('la saisie trouve un titre accentué sans les accents', (
    tester,
  ) async {
    await tester.pumpWidget(_Host(log: []));
    await tester.pumpAndSettle();
    await _tapField(tester);

    await tester.enterText(
      find.descendant(
        of: find.byType(BookPickerField),
        matching: find.byType(TextField),
      ),
      'patis',
    );
    await tester.pumpAndSettle();

    expect(_entry('Pâtisserie'), findsOneWidget);
    expect(_entry('Desserts'), findsNothing);
  });

  testWidgets('la liste garde l\'ordre reçu, sans tri du champ', (
    tester,
  ) async {
    await tester.pumpWidget(_Host(log: []));
    await tester.pumpAndSettle();
    await _tapField(tester);

    final labels = tester
        .widgetList<MenuItemButton>(find.byType(MenuItemButton))
        .map((b) => ((b.child as Padding).child as Text).data)
        .toList();
    expect(labels, [
      'Salades d\'été',
      'Desserts',
      'Pâtisserie',
      'COOK',
      'COOK 2',
    ]);
  });

  testWidgets('choisir une ligne prévient le parent et affiche son titre', (
    tester,
  ) async {
    final log = <Map<String, String>>[];
    await tester.pumpWidget(_Host(log: log));
    await tester.pumpAndSettle();
    await _tapField(tester);

    await tester.enterText(
      find.descendant(
        of: find.byType(BookPickerField),
        matching: find.byType(TextField),
      ),
      'sal',
    );
    await tester.pumpAndSettle();
    await tester.tap(_entry('Salades d\'été'));
    await tester.pumpAndSettle();

    expect(log, [
      {'id': 'b-sal', 'titre': 'Salades d\'été'},
    ]);
    expect(_fieldText(tester), 'Salades d\'été');
  });

  testWidgets('choisir une ligne fonctionne aussi avec une souris de bureau', (
    tester,
  ) async {
    // Sur ordinateur, un clic hors du champ lui retire le focus dès
    // l'appui, avant que le clic n'atteigne la ligne du menu.
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    try {
      final log = <Map<String, String>>[];
      await tester.pumpWidget(_Host(log: log, initialId: 'b-des'));
      await tester.pumpAndSettle();
      await _tapField(tester);

      await tester.enterText(
        find.descendant(
          of: find.byType(BookPickerField),
          matching: find.byType(TextField),
        ),
        'pat',
      );
      await tester.pumpAndSettle();
      await tester.tap(_entry('Pâtisserie'));
      await tester.pumpAndSettle();

      expect(log, [
        {'id': 'b-pat', 'titre': 'Pâtisserie'},
      ]);
      expect(_fieldText(tester), 'Pâtisserie');
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('sur ordinateur, un clic ailleurs remet le livre actuel', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    try {
      final log = <Map<String, String>>[];
      await tester.pumpWidget(_Host(log: log, initialId: 'b-des'));
      await tester.pumpAndSettle();
      await _tapField(tester);

      await tester.enterText(
        find.descendant(
          of: find.byType(BookPickerField),
          matching: find.byType(TextField),
        ),
        'sal',
      );
      await tester.pumpAndSettle();

      await tester.tapAt(const Offset(700, 560));
      await tester.pumpAndSettle();

      expect(log, isEmpty);
      expect(_fieldText(tester), 'Desserts');
      expect(_entry('Salades d\'été'), findsNothing);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('Entrée retient la première ligne de la liste réduite', (
    tester,
  ) async {
    final log = <Map<String, String>>[];
    await tester.pumpWidget(_Host(log: log, initialId: 'b-des'));
    await tester.pumpAndSettle();
    await _tapField(tester);

    await tester.enterText(
      find.descendant(
        of: find.byType(BookPickerField),
        matching: find.byType(TextField),
      ),
      'patis',
    );
    await tester.pumpAndSettle();
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();

    expect(log, [
      {'id': 'b-pat', 'titre': 'Pâtisserie'},
    ]);
    expect(_fieldText(tester), 'Pâtisserie');
  });

  testWidgets(
    'Entrée retient le titre écrit en entier avant un titre plus long',
    (tester) async {
      final log = <Map<String, String>>[];
      await tester.pumpWidget(_Host(log: log, initialId: 'b-des'));
      await tester.pumpAndSettle();
      await _tapField(tester);

      await tester.enterText(
        find.descendant(
          of: find.byType(BookPickerField),
          matching: find.byType(TextField),
        ),
        'cook',
      );
      await tester.pumpAndSettle();
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();

      expect(log.single['id'], 'b-cook');
    },
  );

  testWidgets('Entrée sans correspondance ne change rien', (tester) async {
    final log = <Map<String, String>>[];
    await tester.pumpWidget(_Host(log: log, initialId: 'b-des'));
    await tester.pumpAndSettle();
    await _tapField(tester);

    await tester.enterText(
      find.descendant(
        of: find.byType(BookPickerField),
        matching: find.byType(TextField),
      ),
      'zzz',
    );
    await tester.pumpAndSettle();
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();

    expect(log, isEmpty);
    expect(_fieldText(tester), 'Desserts');
  });

  testWidgets('un texte tapé sans choix est remplacé par le livre actuel', (
    tester,
  ) async {
    final log = <Map<String, String>>[];
    await tester.pumpWidget(_Host(log: log, initialId: 'b-des'));
    await tester.pumpAndSettle();
    await _tapField(tester);

    await tester.enterText(
      find.descendant(
        of: find.byType(BookPickerField),
        matching: find.byType(TextField),
      ),
      'sal',
    );
    await tester.pumpAndSettle();
    expect(_fieldText(tester), 'sal');

    FocusManager.instance.primaryFocus?.unfocus();
    await tester.pumpAndSettle();

    expect(log, isEmpty);
    expect(_fieldText(tester), 'Desserts');
  });

  testWidgets('sans livre retenu, le texte abandonné est effacé', (
    tester,
  ) async {
    await tester.pumpWidget(_Host(log: []));
    await tester.pumpAndSettle();
    await _tapField(tester);

    await tester.enterText(
      find.descendant(
        of: find.byType(BookPickerField),
        matching: find.byType(TextField),
      ),
      'sal',
    );
    await tester.pumpAndSettle();
    FocusManager.instance.primaryFocus?.unfocus();
    await tester.pumpAndSettle();

    expect(_fieldText(tester), '');
  });

  testWidgets('l\'entrée « aucun livre » choisit null', (tester) async {
    final log = <Map<String, String>>[];
    await tester.pumpWidget(
      _Host(log: log, initialId: 'b-des', noneLabel: 'Aucun livre'),
    );
    await tester.pumpAndSettle();
    await _tapField(tester);

    // Le menu s'ouvre défilé sur le livre actuel : on réduit la liste pour
    // que « Aucun livre » soit à l'écran.
    await tester.enterText(
      find.descendant(
        of: find.byType(BookPickerField),
        matching: find.byType(TextField),
      ),
      'aucun',
    );
    await tester.pumpAndSettle();
    await tester.tap(_entry('Aucun livre'));
    await tester.pumpAndSettle();

    expect(log, [
      {'id': 'null', 'titre': 'null'},
    ]);
    expect(_fieldText(tester), 'Aucun livre');
  });

  testWidgets('un champ désactivé n\'ouvre pas la liste', (tester) async {
    await tester.pumpWidget(_Host(log: [], initialId: 'b-des', enabled: false));
    await tester.pumpAndSettle();
    await _tapField(tester);

    expect(_entry('Pâtisserie'), findsNothing);
  });
}
