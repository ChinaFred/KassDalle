import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:kass_dalle/features/auth/domain/app_user.dart';
import 'package:kass_dalle/features/auth/presentation/auth_providers.dart';
import 'package:kass_dalle/features/planning/domain/meal_staple.dart';
import 'package:kass_dalle/features/planning/presentation/meal_staples_providers.dart';
import 'package:kass_dalle/features/planning/presentation/my_staples_screen.dart';

import 'support/test_backend.dart';

/// « Mes garnitures » vide : le bouton « Ma garniture » pour tous, la liste
/// commune pour l'admin seul (#176).
void main() {
  const empty =
      'Aucune garniture pour l\'instant. Ajoutez les vôtres avec le '
      'bouton « Ma garniture ».';
  const adminLine =
      'La liste commune se tient dans Admin › Référentiels › Garnitures '
      'simples.';

  Future<void> pump(WidgetTester tester, UserRole role) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          appUserProvider.overrideWith(
            (ref) => Stream.value(testUser(role: role)),
          ),
          myStaplesProvider.overrideWithValue(
            const AsyncValue<List<UserStaple>>.data([]),
          ),
        ],
        child: const MaterialApp(home: MyStaplesScreen()),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('membre : le bouton « Ma garniture », rien sur l\'admin', (
    tester,
  ) async {
    await pump(tester, UserRole.editor);
    expect(find.text(empty), findsOneWidget);
    expect(find.text(adminLine), findsNothing);
    expect(find.textContaining('semer'), findsNothing);
  });

  testWidgets('admin : la ligne de la liste commune en plus', (tester) async {
    await pump(tester, UserRole.admin);
    expect(find.text(empty), findsOneWidget);
    expect(find.text(adminLine), findsOneWidget);
  });
}
