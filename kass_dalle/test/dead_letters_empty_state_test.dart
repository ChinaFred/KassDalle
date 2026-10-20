import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kass_dalle/core/widgets/app_states.dart';
import 'package:kass_dalle/features/admin/presentation/dead_letters_screen.dart';

void main() {
  testWidgets('file vide : AppEmptyState avec la suite à donner', (
    tester,
  ) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          deadLettersStreamProvider.overrideWith((ref) => Stream.value([])),
        ],
        child: const MaterialApp(home: DeadLettersScreen()),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byType(AppEmptyState), findsOneWidget);
    expect(find.text('Aucun job en échec'), findsOneWidget);
    expect(
      find.textContaining('Un import qui échoue après toutes ses tentatives'),
      findsOneWidget,
    );
    expect(find.byIcon(Icons.task_alt), findsOneWidget);
  });
}
