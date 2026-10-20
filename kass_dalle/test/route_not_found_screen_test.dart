import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:kass_dalle/core/router/route_not_found_screen.dart';

/// Un routeur minimal : la bibliothèque, et la page introuvable de l'application
/// comme `errorBuilder`, comme dans `app_router.dart`.
GoRouter _router(String initialLocation) => GoRouter(
  initialLocation: initialLocation,
  routes: [
    GoRoute(
      path: '/books',
      builder: (context, state) => const Scaffold(body: Text('Bibliothèque')),
    ),
  ],
  errorBuilder: (context, state) => const RouteNotFoundScreen(),
);

void main() {
  testWidgets('adresse inconnue : « Page introuvable », sans texte '
      'd’exception, et « Retour à la bibliothèque » y ramène', (tester) async {
    await tester.pumpWidget(
      MaterialApp.router(routerConfig: _router('/nulle-part')),
    );
    await tester.pumpAndSettle();

    expect(find.text('Page introuvable'), findsOneWidget);
    expect(find.text('Retour à la bibliothèque'), findsOneWidget);
    expect(find.byIcon(Icons.link_off_outlined), findsOneWidget);
    expect(find.byIcon(Icons.library_books_outlined), findsOneWidget);
    // Le message de go_router (« no routes for location: /nulle-part »)
    // n'est pas affiché.
    expect(find.textContaining('no routes'), findsNothing);
    expect(find.textContaining('/nulle-part'), findsNothing);
    expect(find.textContaining('Exception'), findsNothing);

    await tester.tap(find.text('Retour à la bibliothèque'));
    await tester.pumpAndSettle();

    expect(find.text('Bibliothèque'), findsOneWidget);
    expect(find.text('Page introuvable'), findsNothing);
  });
}
