import 'dart:async';

import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kass_dalle/core/services/gemini_service.dart'
    show GeminiCallableException;
import 'package:kass_dalle/core/widgets/app_states.dart';
import 'package:kass_dalle/core/widgets/error_message.dart';

/// Exception Firebase minimale : `FirebaseException` est concrète et n'exige
/// que `plugin`, ce qui suffit à rejouer l'aiguillage sur `code`.
FirebaseException _firebaseError(String code) =>
    FirebaseException(plugin: 'cloud_firestore', code: code);

Future<void> _pump(WidgetTester tester, Widget child) {
  return tester.pumpWidget(
    MaterialApp(
      locale: const Locale('fr'),
      home: Scaffold(body: child),
    ),
  );
}

void main() {
  group('describeError', () {
    test('un réseau coupé est réessayable et le dit en français', () {
      final m = describeError(_firebaseError('unavailable'));
      expect(m.title, 'Connexion perdue');
      expect(m.retryable, isTrue);
      expect(m.advice, contains('connexion internet'));
    });

    test('un refus de droits n\'est pas réessayable', () {
      final m = describeError(_firebaseError('permission-denied'));
      expect(m.title, 'Accès refusé');
      // Le distinguer n'est pas cosmétique : proposer « Réessayer » sur un
      // refus de droits promet un résultat que le deuxième appui ne donnera pas.
      expect(m.retryable, isFalse);
    });

    test('une session expirée oriente vers la reconnexion', () {
      final m = describeError(_firebaseError('unauthenticated'));
      expect(m.title, 'Session expirée');
      expect(m.retryable, isFalse);
    });

    test('un document absent n\'invite pas à réessayer', () {
      expect(describeError(_firebaseError('not-found')).retryable, isFalse);
    });

    test('un délai dépassé est réessayable', () {
      final m = describeError(TimeoutException('trop long'));
      expect(m.title, contains('trop de temps'));
      expect(m.retryable, isTrue);
    });

    test('une panne réseau sans code Firebase est reconnue au texte', () {
      final m = describeError(
        Exception(
          'SocketException: Failed host lookup: firestore.googleapis.com',
        ),
      );
      expect(m.title, 'Connexion perdue');
    });

    test(
      'une exception inconnue reste réessayable, sans mentir sur sa nature',
      () {
        final m = describeError(StateError('bizarre'));
        expect(m.title, 'Une erreur inattendue est survenue');
        expect(m.retryable, isTrue);
      },
    );

    test('une erreur nulle ne fait pas planter le message', () {
      expect(describeError(null).title, isNotEmpty);
    });

    test('une erreur de callable d\'IA est lue par son code', () {
      // SDK : `resource-exhausted` ; appel HTTP du web : `resource_exhausted`.
      for (final code in ['resource-exhausted', 'resource_exhausted']) {
        expect(
          describeError(GeminiCallableException(code, 'x', null)).title,
          'Quota atteint',
        );
      }
      final denied = describeError(
        GeminiCallableException('permission-denied', 'x', null),
      );
      expect(denied.title, 'Accès refusé');
      expect(denied.retryable, isFalse);
      expect(
        describeError(GeminiCallableException('unavailable', 'x', null)).title,
        'Connexion perdue',
      );
      expect(
        describeError(GeminiCallableException('internal', 'x', null)).title,
        'Une erreur inattendue est survenue',
      );
    });
  });

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
