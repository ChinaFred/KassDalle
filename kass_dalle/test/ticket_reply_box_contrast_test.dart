import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kass_dalle/core/theme/app_theme.dart';
import 'package:kass_dalle/features/tickets/presentation/ticket_widgets.dart';

/// Ratio de contraste WCAG entre deux couleurs opaques.
double _contrast(Color a, Color b) {
  final la = a.computeLuminance();
  final lb = b.computeLuminance();
  final hi = la > lb ? la : lb;
  final lo = la > lb ? lb : la;
  return (hi + 0.05) / (lo + 0.05);
}

void main() {
  for (final entry in {
    'clair': AppTheme.light,
    'sombre': AppTheme.dark,
  }.entries) {
    testWidgets('TicketReplyBox : texte lisible en mode ${entry.key}', (
      tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: entry.value,
          home: const Scaffold(
            body: TicketReplyBox(title: 'Réponse', text: 'Texte de réponse'),
          ),
        ),
      );
      final box = tester.widget<Container>(
        find.descendant(
          of: find.byType(TicketReplyBox),
          matching: find.byType(Container),
        ),
      );
      final background = (box.decoration! as BoxDecoration).color!;
      final text = tester.widget<SelectableText>(find.byType(SelectableText));
      final title = tester.widget<Text>(find.text('Réponse'));
      expect(
        _contrast(text.style!.color!, background),
        greaterThanOrEqualTo(4.5),
      );
      expect(
        _contrast(title.style!.color!, background),
        greaterThanOrEqualTo(4.5),
      );
    });
  }
}
