import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kass_dalle/features/tickets/domain/ticket.dart';
import 'package:kass_dalle/features/tickets/presentation/ticket_widgets.dart';

Widget _host(TicketStatus status, {bool blink = true, bool reduced = false}) =>
    MaterialApp(
      home: MediaQuery(
        data: MediaQueryData(disableAnimations: reduced),
        child: Scaffold(
          body: TicketStatusChip(status: status, blinkOnChange: blink),
        ),
      ),
    );

Finder get _fade => find.descendant(
  of: find.byType(TicketStatusChip),
  matching: find.byType(FadeTransition),
);

double _opacity(WidgetTester t) =>
    t.widget<FadeTransition>(_fade).opacity.value;

void main() {
  testWidgets('pas de clignotement au premier affichage', (t) async {
    await t.pumpWidget(_host(TicketStatus.analyzed));
    await t.pump(const Duration(milliseconds: 150));
    expect(_opacity(t), 1.0);
  });

  testWidgets('clignote au changement de statut puis reste fixe', (t) async {
    await t.pumpWidget(_host(TicketStatus.analyzed));
    await t.pumpWidget(_host(TicketStatus.validated));
    await t.pump(const Duration(milliseconds: 200));
    expect(_opacity(t), lessThan(1.0));
    await t.pumpAndSettle();
    expect(_opacity(t), 1.0);
    expect(find.text(TicketStatus.validated.label), findsOneWidget);
  });

  testWidgets('pas de clignotement avec les animations réduites', (t) async {
    await t.pumpWidget(_host(TicketStatus.analyzed, reduced: true));
    await t.pumpWidget(_host(TicketStatus.validated, reduced: true));
    await t.pump(const Duration(milliseconds: 200));
    expect(_opacity(t), 1.0);
  });

  testWidgets('sans blinkOnChange, la puce ne clignote jamais', (t) async {
    await t.pumpWidget(_host(TicketStatus.analyzed, blink: false));
    await t.pumpWidget(_host(TicketStatus.validated, blink: false));
    await t.pump(const Duration(milliseconds: 200));
    for (final f in t.widgetList<FadeTransition>(_fade)) {
      expect(f.opacity.value, 1.0);
    }
  });
}
