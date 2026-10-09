import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/services/error_reporting.dart';
import '../../../core/utils/context_extensions.dart';
import '../../recipes/presentation/recipe_providers.dart';
import 'book_providers.dart';

/// Message quand le compte n'est pas encore lu : rien ne s'est passé, il
/// suffit de recommencer.
const kAccountNotLoadedMessage =
    'Votre compte n\'est pas encore chargé. Réessayez dans un instant.';

/// Message quand la suppression échoue ; le détail part au rapport d'erreurs.
const kDeleteBookFailedMessage = 'La suppression du livre a échoué. Réessayez.';

/// Ligne affichée pendant le décompte des pages des autres membres.
const kCountingOthersMessage =
    'Recherche des pages ajoutées par d\'autres membres…';

enum _DeleteBookMode { detach, deleteAll }

/// Pluriel d'un nombre de pages, pour les messages qui l'annoncent.
String _pages(int n) => n == 1 ? '1 page ajoutée' : '$n pages ajoutées';

/// Ce que la boîte de confirmation dit des pages des autres membres.
///
/// [othersCount] compte les pages **partagées** des autres : leurs pages
/// privées ne sont pas lisibles, d'où « au moins ». Il vaut -1 quand le
/// décompte n'est pas possible (livre privé) ou a échoué : on prévient sans
/// chiffre.
String deleteBookOthersNotice(int othersCount) {
  if (othersCount == 0) return '';
  final quoi = othersCount < 0
      ? 'Les pages éventuellement ajoutées par d\'autres membres seront '
            'conservées'
      : 'Au moins ${_pages(othersCount)} par d\'autres membres '
            '${othersCount == 1 ? 'sera conservée' : 'seront conservées'}';
  return '$quoi : elles deviendront des recettes libres de leurs auteurs.';
}

/// Message de fin, qui dit ce qui reste.
///
/// [actsForAll] : un administrateur, qui supprime ou détache les recettes de
/// tous les auteurs. Le message ne dit alors jamais « vos ».
String deleteBookSuccessMessage({
  required bool deleteAll,
  required int othersCount,
  bool actsForAll = false,
}) {
  if (actsForAll) {
    return deleteAll
        ? 'Livre et recettes supprimés.'
        : 'Livre supprimé. Ses recettes deviennent des recettes libres de '
              'leurs auteurs.';
  }
  final base = deleteAll
      ? (othersCount == 0
            ? 'Livre et recettes supprimés.'
            : 'Livre et vos recettes supprimés.')
      : 'Livre supprimé. Vos recettes restent disponibles en recettes libres.';
  if (othersCount == 0) return base;
  return othersCount < 0
      ? '$base Les pages des autres membres restent chez leurs auteurs.'
      : '$base Au moins ${_pages(othersCount)} par d\'autres membres '
            '${othersCount == 1 ? 'reste' : 'restent'} chez leurs auteurs.';
}

/// La question posée dans la boîte.
String deleteBookQuestion({
  required String bookTitre,
  required bool actsForAll,
}) => actsForAll
    ? 'Que faire des recettes liées à « $bookTitre » ? « Supprimer aussi » '
          'les supprime pour tous leurs auteurs ; les détacher en fait des '
          'recettes libres de leurs auteurs.'
    : 'Que faire de vos recettes liées à « $bookTitre » ?';

/// Supprime un livre, après avoir demandé que faire de ses recettes.
///
/// Partagé par la bibliothèque et par la liste d'un livre. Le créateur ne
/// supprime ni ne détache que ses recettes (`firestore.rules`) ; à la
/// suppression du livre, `onBookWritten` détache les autres, qui deviennent
/// des recettes libres de leurs auteurs — privées si le livre l'était. Un
/// administrateur agit sur toutes.
///
/// La boîte s'ouvre tout de suite ; le décompte des pages des autres s'y
/// affiche dès qu'il arrive.
///
/// Rend `true` quand le livre a été supprimé.
Future<bool> confirmAndDeleteBook({
  required BuildContext context,
  required WidgetRef ref,
  required String bookId,
  required String bookTitre,
  required bool bookIsPrivate,
}) async {
  final viewer = ref.read(recipeViewerProvider);
  if (viewer == null) {
    context.showErrorSnackBar(kAccountNotLoadedMessage);
    return false;
  }
  final recipes = ref.read(recipeRepositoryProvider);
  // Un administrateur supprime ou détache les recettes de tous les auteurs,
  // y compris dans son propre livre : la question et le message le disent.
  final actsForAll = viewer.isAdmin;

  // Un administrateur agit sur toutes les recettes : rien à annoncer. Dans un
  // livre privé, les pages des autres ne sont pas lisibles : pas de chiffre.
  final int? knownCount = viewer.isAdmin
      ? 0
      : bookIsPrivate
      ? -1
      : null;
  final Future<int> countFuture = viewer.isAdmin
      ? Future.value(0)
      : bookIsPrivate
      ? Future.value(-1)
      : recipes.countOthersInBook(bookId, viewer).catchError((
          Object e,
          StackTrace stackTrace,
        ) {
          reportUnexpectedError(
            feature: 'deleteBookFlow.countOthers',
            error: e,
            stackTrace: stackTrace,
            context: {'book_id': bookId},
          );
          return -1;
        });

  final mode = await showDialog<_DeleteBookMode>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('Supprimer ce livre ?'),
      content: FutureBuilder<int>(
        future: countFuture,
        // Valeur connue d'avance (administrateur, livre privé) : affichée
        // dès l'ouverture, sans ligne d'attente.
        initialData: knownCount,
        builder: (_, snap) {
          final question = deleteBookQuestion(
            bookTitre: bookTitre,
            actsForAll: actsForAll,
          );
          final notice = snap.hasData
              ? deleteBookOthersNotice(snap.data!)
              : kCountingOthersMessage;
          if (knownCount != null) {
            return Text(notice.isEmpty ? question : '$question\n\n$notice');
          }
          // Décompte en cours : la zone de l'annonce a dès l'ouverture la
          // hauteur de la plus longue annonce possible (textes invisibles
          // empilés), quelle que soit la taille du texte. Elle ne bouge
          // donc ni à l'arrivée du chiffre, ni quand il vaut zéro.
          return Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(question),
              const SizedBox(height: 16),
              Stack(
                children: [
                  for (final longest in [
                    deleteBookOthersNotice(-1),
                    deleteBookOthersNotice(999),
                  ])
                    Visibility(
                      visible: false,
                      maintainSize: true,
                      maintainAnimation: true,
                      maintainState: true,
                      child: Text(longest),
                    ),
                  Text(notice),
                ],
              ),
            ],
          );
        },
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx),
          child: const Text('Annuler'),
        ),
        OutlinedButton(
          onPressed: () => Navigator.pop(ctx, _DeleteBookMode.detach),
          child: const Text('Détacher les recettes'),
        ),
        FilledButton(
          style: FilledButton.styleFrom(
            backgroundColor: Theme.of(ctx).colorScheme.error,
            foregroundColor: Theme.of(ctx).colorScheme.onError,
          ),
          onPressed: () => Navigator.pop(ctx, _DeleteBookMode.deleteAll),
          child: const Text('Supprimer aussi'),
        ),
      ],
    ),
  );
  if (mode == null || !context.mounted) return false;

  try {
    if (mode == _DeleteBookMode.deleteAll) {
      await recipes.deleteAllRecipesOfBook(bookId, viewer);
    } else {
      await recipes.detachAllRecipesFromBook(bookId, viewer);
    }
    await ref.read(bookRepositoryProvider).deleteBook(bookId);
    final othersCount = await countFuture;
    if (!context.mounted) return true;
    context.showSuccessSnackBar(
      deleteBookSuccessMessage(
        deleteAll: mode == _DeleteBookMode.deleteAll,
        othersCount: othersCount,
        actsForAll: actsForAll,
      ),
    );
    return true;
  } catch (e, stackTrace) {
    reportUnexpectedError(
      feature: 'deleteBookFlow.delete',
      error: e,
      stackTrace: stackTrace,
      context: {'book_id': bookId, 'mode': mode.name},
    );
    if (context.mounted) context.showErrorSnackBar(kDeleteBookFailedMessage);
    return false;
  }
}
