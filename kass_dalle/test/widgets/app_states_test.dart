import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kass_dalle/core/widgets/app_states.dart';
import 'package:kass_dalle/core/widgets/error_message.dart';
import 'package:kass_dalle/features/auth/presentation/auth_providers.dart';

/// Exception Firebase minimale : `FirebaseException` est concrète et n'exige
/// que `plugin`, ce qui suffit à rejouer l'aiguillage sur `code`.
FirebaseException _firebaseError(String code) =>
    FirebaseException(plugin: 'cloud_firestore', code: code);

/// [isAdmin] fixe le rôle lu par `AppErrorState` : « Détails » n'est
/// montré qu'à un administrateur. Par défaut, un administrateur, pour que
/// les tests du repli des détails s'appliquent.
Future<void> _pump(WidgetTester tester, Widget child, {bool isAdmin = true}) {
  return tester.pumpWidget(
    ProviderScope(
      overrides: [isAdminProvider.overrideWithValue(isAdmin)],
      child: MaterialApp(
        locale: const Locale('fr'),
        home: Scaffold(body: child),
      ),
    ),
  );
}

void main() {
  group('AppErrorState', () {
    testWidgets('n\'affiche jamais l\'exception brute au premier coup d\'œil', (
      tester,
    ) async {
      await _pump(
        tester,
        AppErrorState(error: _firebaseError('unavailable'), onRetry: () {}),
      );

      expect(find.text('Connexion perdue'), findsOneWidget);
      // Le texte technique existe toujours — il est replié, pas supprimé.
      expect(find.textContaining('cloud_firestore'), findsNothing);
      expect(find.text('Détails'), findsOneWidget);
    });

    testWidgets('« Détails » révèle puis masque le texte technique', (
      tester,
    ) async {
      await _pump(tester, AppErrorState(error: _firebaseError('unavailable')));

      await tester.tap(find.text('Détails'));
      await tester.pump();
      expect(find.textContaining('cloud_firestore'), findsOneWidget);

      await tester.tap(find.text('Masquer les détails'));
      await tester.pump();
      expect(find.textContaining('cloud_firestore'), findsNothing);
    });

    testWidgets('« Détails » est absent pour un membre non administrateur', (
      tester,
    ) async {
      await _pump(
        tester,
        AppErrorState(error: StateError('bizarre'), onRetry: () {}),
        isAdmin: false,
      );

      expect(find.text('Une erreur inattendue est survenue'), findsOneWidget);
      expect(find.text('Détails'), findsNothing);
      expect(find.textContaining('bizarre'), findsNothing);
      // Le conseil ne renvoie plus à des détails qu'il ne voit pas.
      expect(find.text(kReportProblemAdvice), findsOneWidget);
      expect(find.textContaining('ci-dessous'), findsNothing);
    });

    testWidgets(
      'un administrateur garde « Détails » et le conseil d\'origine',
      (tester) async {
        await _pump(tester, AppErrorState(error: StateError('bizarre')));

        expect(find.text('Détails'), findsOneWidget);
        expect(find.text(kUnexpectedErrorAdvice), findsOneWidget);
        expect(find.text(kReportProblemAdvice), findsNothing);
      },
    );

    testWidgets('un membre garde le conseil propre à une panne connue', (
      tester,
    ) async {
      await _pump(
        tester,
        AppErrorState(error: _firebaseError('unavailable')),
        isAdmin: false,
      );

      expect(find.textContaining('connexion internet'), findsOneWidget);
      expect(find.text('Détails'), findsNothing);
    });

    testWidgets('le bouton Réessayer rappelle bien le callback', (
      tester,
    ) async {
      var appels = 0;
      await _pump(
        tester,
        AppErrorState(
          error: _firebaseError('unavailable'),
          onRetry: () => appels++,
        ),
      );

      await tester.tap(find.text('Réessayer'));
      await tester.pump();

      expect(appels, 1);
    });

    testWidgets('pas de bouton Réessayer sans callback', (tester) async {
      await _pump(tester, AppErrorState(error: _firebaseError('unavailable')));
      expect(find.text('Réessayer'), findsNothing);
    });

    testWidgets('pas de bouton Réessayer sur une erreur non réessayable', (
      tester,
    ) async {
      await _pump(
        tester,
        AppErrorState(
          error: _firebaseError('permission-denied'),
          onRetry: () {},
        ),
      );

      expect(find.text('Accès refusé'), findsOneWidget);
      expect(find.text('Réessayer'), findsNothing);
    });

    testWidgets('un titre fourni par l\'écran prend le pas', (tester) async {
      await _pump(
        tester,
        AppErrorState(
          error: _firebaseError('unavailable'),
          title: 'Coûts GCP indisponibles',
        ),
      );

      expect(find.text('Coûts GCP indisponibles'), findsOneWidget);
      expect(find.text('Connexion perdue'), findsNothing);
    });

    testWidgets('un conseil fourni par l\'écran prend le pas', (tester) async {
      await _pump(
        tester,
        AppErrorState(
          error: _firebaseError('unavailable'),
          advice: 'Le moteur de recherche est saturé.',
        ),
      );

      expect(find.text('Le moteur de recherche est saturé.'), findsOneWidget);
      expect(find.textContaining('connexion internet'), findsNothing);
    });
  });

  group('AppLoadingState', () {
    testWidgets('affiche son libellé quand il en a un', (tester) async {
      await _pump(
        tester,
        const AppLoadingState(label: 'Chargement des livres'),
      );
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      expect(find.text('Chargement des livres'), findsOneWidget);
    });

    testWidgets('reste muet sans libellé', (tester) async {
      await _pump(tester, const AppLoadingState());
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      expect(find.byType(Text), findsNothing);
    });
  });

  group('AppEmptyState', () {
    testWidgets('montre titre, message et action', (tester) async {
      await _pump(
        tester,
        AppEmptyState(
          icon: Icons.library_books_outlined,
          title: 'Aucun livre',
          message: 'Ajoutez-en un pour commencer.',
          action: FilledButton(onPressed: () {}, child: const Text('Ajouter')),
        ),
      );

      expect(find.text('Aucun livre'), findsOneWidget);
      expect(find.text('Ajoutez-en un pour commencer.'), findsOneWidget);
      expect(find.text('Ajouter'), findsOneWidget);
    });
  });
}
