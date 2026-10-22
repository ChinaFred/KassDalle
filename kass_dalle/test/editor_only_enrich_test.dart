// Enrichir une recette — photo, illustration, couverture, IA — demande d'en
// être propriétaire ET éditeur (tickets #162 et #163). Un bouton interdit est
// masqué, jamais grisé ; un refus reçu en cours de session se dit sans
// « Réessayer ».
import 'dart:typed_data';

import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:kass_dalle/core/widgets/error_message.dart';
import 'package:kass_dalle/features/auth/presentation/auth_providers.dart';
import 'package:kass_dalle/features/books/domain/book.dart';
import 'package:kass_dalle/features/books/presentation/book_providers.dart';
import 'package:kass_dalle/features/recipes/domain/recipe.dart';
import 'package:kass_dalle/features/recipes/presentation/ai/ai_ui_copy.dart';
import 'package:kass_dalle/features/recipes/presentation/detail/tabs/photos_tab.dart';
import 'package:kass_dalle/features/recipes/presentation/drafts/draft_illustrations_tab.dart';
import 'package:kass_dalle/features/recipes/presentation/edit/recipe_meta_panel.dart';

Recipe _recipe() {
  final t = DateTime(2026, 1, 1);
  return Recipe(
    id: 'r1',
    titre: 'Tarte',
    langue: 'fr',
    rawCooklang: 'Cuire.',
    imageUrls: const [],
    reviewStatus: ReviewStatus.validated,
    tags: const RecipeTags(),
    ingredientsIndex: const [],
    createdBy: 'moi',
    createdAt: t,
    updatedAt: t,
  );
}

Future<void> _pump(
  WidgetTester tester,
  Widget child, {
  bool canEdit = false,
}) async {
  await tester.binding.setSurfaceSize(const Size(600, 1600));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        canEditProvider.overrideWithValue(canEdit),
        targetBooksProvider.overrideWithValue(const AsyncValue.data(<Book>[])),
      ],
      child: MaterialApp(home: Scaffold(body: child)),
    ),
  );
  await tester.pump();
}

void main() {
  group('refus reçu en cours de session', () {
    final storageRefusal = FirebaseException(
      plugin: 'firebase_storage',
      code: 'unauthorized',
    );
    final callableRefusal = FirebaseException(
      plugin: 'firebase_functions',
      code: 'permission-denied',
    );
    final network = FirebaseException(
      plugin: 'cloud_firestore',
      code: 'unavailable',
    );

    test('photo ou couverture : message de rôle, sans la cause technique', () {
      expect(isPermissionRefusal(storageRefusal), isTrue);
      expect(
        photoFailureMessage('Couverture non mise à jour', storageRefusal),
        'Photo non envoyée. Ajouter des photos est réservé aux éditeurs.',
      );
    });

    test('IA : le préfixe de l\'action est gardé', () {
      expect(
        aiFailureMessage('Recette non corrigée', callableRefusal),
        'Recette non corrigée. L\'IA est réservée aux éditeurs.',
      );
      expect(
        aiFailureMessage('Recette non améliorée', callableRefusal),
        'Recette non améliorée. L\'IA est réservée aux éditeurs.',
      );
    });

    test('une autre panne garde le message habituel', () {
      expect(isPermissionRefusal(network), isFalse);
      expect(
        photoFailureMessage('Photo non enregistrée', network),
        failureMessage('Photo non enregistrée', network),
      );
      expect(
        aiFailureMessage('Recette non corrigée', network),
        failureMessage('Recette non corrigée', network),
      );
    });
  });

  group('onglet Photos de la fiche, sans photo', () {
    testWidgets('propriétaire éditeur : bouton « Ajouter une photo »', (
      tester,
    ) async {
      await _pump(
        tester,
        PhotosTab(
          recipeId: 'r1',
          recipe: _recipe(),
          canEdit: true,
          canEnrich: true,
        ),
        canEdit: true,
      );
      expect(find.text('Ajouter une photo'), findsOneWidget);
    });

    testWidgets('propriétaire lecteur : réservé aux éditeurs, sans bouton', (
      tester,
    ) async {
      await _pump(
        tester,
        PhotosTab(
          recipeId: 'r1',
          recipe: _recipe(),
          canEdit: true,
          canEnrich: false,
        ),
      );
      expect(find.text('Aucune photo'), findsOneWidget);
      expect(find.text(kPhotosEditorOnlyMessage), findsOneWidget);
      expect(find.text('Ajouter une photo'), findsNothing);
    });

    testWidgets('non-propriétaire : texte inchangé', (tester) async {
      await _pump(
        tester,
        PhotosTab(
          recipeId: 'r1',
          recipe: _recipe(),
          canEdit: false,
          canEnrich: false,
        ),
      );
      expect(
        find.text('Personne n\'a encore ajouté de photo à cette recette.'),
        findsOneWidget,
      );
    });
  });

  // Retirer une photo réécrit `image_urls`, hors des deux écritures d'un
  // lecteur (valider, détacher) : le bouton n'apparaît pas.
  group('onglet Photos de la fiche, avec photo', () {
    Recipe withPhoto() {
      final r = _recipe();
      return Recipe(
        id: r.id,
        titre: r.titre,
        langue: r.langue,
        rawCooklang: r.rawCooklang,
        imageUrls: const ['https://example.com/a.jpg'],
        reviewStatus: r.reviewStatus,
        tags: r.tags,
        ingredientsIndex: r.ingredientsIndex,
        createdBy: r.createdBy,
        createdAt: r.createdAt,
        updatedAt: r.updatedAt,
      );
    }

    testWidgets('propriétaire lecteur : ni « Ajouter » ni suppression', (
      tester,
    ) async {
      await _pump(
        tester,
        PhotosTab(
          recipeId: 'r1',
          recipe: withPhoto(),
          canEdit: true,
          canEnrich: false,
        ),
      );
      expect(find.text('Ajouter'), findsNothing);
      expect(find.byTooltip('Supprimer cette photo'), findsNothing);
    });

    testWidgets('propriétaire éditeur : « Ajouter » et suppression', (
      tester,
    ) async {
      await _pump(
        tester,
        PhotosTab(
          recipeId: 'r1',
          recipe: withPhoto(),
          canEdit: true,
          canEnrich: true,
        ),
        canEdit: true,
      );
      expect(find.text('Ajouter'), findsOneWidget);
      expect(find.byTooltip('Supprimer cette photo'), findsOneWidget);
    });
  });

  group('onglet Photos du brouillon, sans photo', () {
    Future<String?> upload(Uint8List bytes, String name) async => null;

    testWidgets('propriétaire lecteur : réservé aux éditeurs, ni ajout ni IA', (
      tester,
    ) async {
      await _pump(
        tester,
        DraftIllustrationsTab(
          recipe: _recipe(),
          isOwner: true,
          aiRefining: false,
          saving: false,
        ),
      );
      expect(find.textContaining('réservé aux éditeurs'), findsOneWidget);
      expect(find.text('Ajouter une photo'), findsNothing);
      expect(find.text(RecipeAiUiCopy.generateImageLabel), findsNothing);
    });

    testWidgets('propriétaire éditeur : ajout et image IA', (tester) async {
      await _pump(
        tester,
        DraftIllustrationsTab(
          recipe: _recipe(),
          isOwner: true,
          aiRefining: false,
          saving: false,
          onUploadImage: upload,
        ),
        canEdit: true,
      );
      expect(find.text('Ajouter une photo'), findsOneWidget);
      expect(find.text(RecipeAiUiCopy.generateImageLabel), findsWidgets);
    });

    // « Créer une image IA » suit `canGenerateAi`, pas l'envoi de photo.
    testWidgets('éditeur sans envoi de photo : l\'image IA reste proposée', (
      tester,
    ) async {
      await _pump(
        tester,
        DraftIllustrationsTab(
          recipe: _recipe(),
          isOwner: true,
          aiRefining: false,
          saving: false,
        ),
        canEdit: true,
      );
      expect(find.text('Ajouter une photo'), findsNothing);
      expect(find.text(RecipeAiUiCopy.generateImageLabel), findsWidgets);
    });
  });

  group('« Suggérer les tags »', () {
    Widget panel({VoidCallback? onSuggestTags, bool suggesting = false}) {
      final ctrls = List.generate(7, (_) => TextEditingController());
      return SingleChildScrollView(
        child: RecipeMetaPanel(
          titleCtrl: ctrls[0],
          portionsCtrl: ctrls[1],
          difficultyCtrl: ctrls[2],
          prepTimeCtrl: ctrls[3],
          cookTimeCtrl: ctrls[4],
          restTimeCtrl: ctrls[5],
          pageNumberCtrl: ctrls[6],
          saving: false,
          selectedBookId: null,
          onBookChanged: (_, _) {},
          showBookSelector: false,
          cuisines: const [],
          onCuisinesChanged: (_) {},
          dishTypes: const [],
          onDishTypesChanged: (_) {},
          suggestingTags: suggesting,
          onSuggestTags: onSuggestTags,
        ),
      );
    }

    testWidgets('visible pour un éditeur, et appelle l\'IA', (tester) async {
      var calls = 0;
      await _pump(tester, panel(onSuggestTags: () => calls++), canEdit: true);
      expect(find.text(kSuggestTagsLabel), findsOneWidget);
      expect(find.byTooltip(kSuggestTagsTooltip), findsOneWidget);
      await tester.tap(find.text(kSuggestTagsLabel));
      expect(calls, 1);
    });

    testWidgets('masqué pour un lecteur', (tester) async {
      await _pump(tester, panel(onSuggestTags: () {}));
      expect(find.text(kSuggestTagsLabel), findsNothing);
    });

    testWidgets('pendant l\'appel : désactivé, indicateur de chargement', (
      tester,
    ) async {
      var calls = 0;
      await _pump(
        tester,
        panel(onSuggestTags: () => calls++, suggesting: true),
        canEdit: true,
      );
      await tester.tap(find.text(kSuggestTagsLabel));
      expect(calls, 0);
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
    });
  });
}
