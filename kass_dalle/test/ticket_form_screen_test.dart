import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kass_dalle/features/auth/presentation/auth_providers.dart';
import 'package:kass_dalle/features/tickets/domain/ticket.dart';
import 'package:kass_dalle/features/tickets/presentation/ticket_form_screen.dart';
import 'package:kass_dalle/features/tickets/presentation/ticket_widgets.dart';

/// Le bouton « Envoyer » reste actif : les fautes s'affichent à l'appui,
/// sous leur champ, et rien ne part.
void main() {
  Future<void> pump(WidgetTester tester, {String? screen}) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [appUserProvider.overrideWith((ref) => Stream.value(null))],
        child: MaterialApp(home: TicketFormScreen(initialScreen: screen)),
      ),
    );
    await tester.pump();
  }

  testWidgets('Bug est sélectionné à l\'ouverture', (tester) async {
    await pump(tester);

    expect(find.textContaining('Ce que vous faisiez : …'), findsWidgets);
  });

  testWidgets('formulaire vide : faute du titre, sans faute de type', (
    tester,
  ) async {
    await pump(tester);

    await tester.ensureVisible(find.text('Envoyer'));
    await tester.tap(find.text('Envoyer'));
    await tester.pump();

    expect(find.text('Choisissez le type de ticket.'), findsNothing);
    expect(
      find.text('Le titre doit faire au moins 5 caractères.'),
      findsOneWidget,
    );
  });

  testWidgets('le type choisi donne son gabarit', (tester) async {
    await pump(tester);

    await tester.tap(find.text('Question'));
    await tester.pump();

    expect(find.text('Choisissez le type de ticket.'), findsNothing);
    expect(find.textContaining('Votre question : …'), findsWidgets);
  });

  testWidgets('écran présélectionné depuis le modèle de route', (tester) async {
    await pump(tester, screen: '/recipes/:recipeId');
    expect(find.text('Fiche recette'), findsOneWidget);
  });

  testWidgets('une adresse réelle devient « Je ne sais pas »', (tester) async {
    await pump(tester, screen: '/recipes/Xy7AbC12');
    expect(find.text('Je ne sais pas'), findsOneWidget);
  });

  testWidgets('l\'avertissement de publication est affiché', (tester) async {
    await pump(tester);
    expect(
      find.textContaining('seront publiés sur un site public'),
      findsOneWidget,
    );
  });

  testWidgets(
    'la faute du titre reste tant qu\'il fait moins de 5 caractères',
    (tester) async {
      await pump(tester);
      await tester.ensureVisible(find.text('Envoyer'));
      await tester.tap(find.text('Envoyer'));
      await tester.pump();
      const fault = 'Le titre doit faire au moins 5 caractères.';

      await tester.enterText(find.widgetWithText(TextField, 'Titre'), 'Bug');
      await tester.pump();
      expect(find.text(fault), findsOneWidget);

      await tester.enterText(find.widgetWithText(TextField, 'Titre'), 'Bug vu');
      await tester.pump();
      expect(find.text(fault), findsNothing);
    },
  );

  testWidgets('l\'icône de type n\'est annoncée qu\'une fois', (tester) async {
    final handle = tester.ensureSemantics();
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(body: TicketTypeIcon(type: TicketType.bug)),
      ),
    );
    expect(find.bySemanticsLabel(TicketType.bug.label), findsOneWidget);
    handle.dispose();
  });
}
