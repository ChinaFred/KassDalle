import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:kass_dalle/core/router/app_router.dart';
import 'package:kass_dalle/features/auth/domain/app_user.dart';
import 'package:kass_dalle/features/auth/presentation/auth_providers.dart';
import 'package:kass_dalle/features/search/presentation/meal_workshop/meal_workshop_providers.dart';

/// La route `/search/meal-workshop`, telle que `app_router.dart` la déclare
/// (`mealWorkshopRouteBuilder`) : un lecteur arrivé par un lien lit
/// « Composition réservée aux éditeurs » et retourne à Explorer ; un éditeur
/// ouvre l'atelier, le champ garni du texte de `?q=`.
AppUser _user(UserRole role) => AppUser(
  uid: 'u1',
  email: 'u@example.test',
  displayName: 'Utilisateur',
  role: role,
  createdAt: DateTime(2026, 1, 1),
  lastSeenAt: DateTime(2026, 1, 1),
);

Future<void> _pump(
  WidgetTester tester, {
  required UserRole role,
  String location = AppRoutes.mealWorkshop,
}) async {
  tester.view.physicalSize = const Size(1000, 1200);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final router = GoRouter(
    initialLocation: location,
    routes: [
      GoRoute(
        path: AppRoutes.search,
        builder: (_, _) => const Scaffold(body: Text('Explorer')),
        routes: [
          GoRoute(path: 'meal-workshop', builder: mealWorkshopRouteBuilder),
        ],
      ),
    ],
  );
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        appUserProvider.overrideWith((ref) => Stream.value(_user(role))),
        mealWorkshopContextProvider.overrideWith(
          (ref) async => const MealWorkshopContext(
            myUid: 'u1',
            displayName: 'Utilisateur',
            summaries: [],
            recipesById: {},
            staples: [],
            globalConstraints: '',
            defaultPortions: 4,
            quota: null,
          ),
        ),
      ],
      child: MaterialApp.router(routerConfig: router),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('lecteur : la garde, puis « Retour à Explorer »', (tester) async {
    await _pump(tester, role: UserRole.reader);
    expect(find.text('Atelier repas'), findsOneWidget);
    expect(find.text('Composition réservée aux éditeurs'), findsOneWidget);
    expect(find.text('Dites ce que vous voulez manger'), findsNothing);
    await tester.tap(find.text('Retour à Explorer'));
    await tester.pumpAndSettle();
    expect(find.text('Explorer'), findsOneWidget);
  });

  testWidgets('éditeur : l\'atelier, le champ garni de ?q=, rien d\'envoyé', (
    tester,
  ) async {
    await _pump(
      tester,
      role: UserRole.editor,
      location: mealWorkshopLocation('un dîner pour 6'),
    );
    expect(find.text('Composition réservée aux éditeurs'), findsNothing);
    expect(find.text('Dites ce que vous voulez manger'), findsOneWidget);
    expect(find.widgetWithText(TextField, 'un dîner pour 6'), findsOneWidget);
    expect(
      find.text(
        'Aucune recette de la bibliothèque dans le périmètre : l\'IA ne '
        'proposera que des plats nouveaux.',
      ),
      findsOneWidget,
    );
  });
}
