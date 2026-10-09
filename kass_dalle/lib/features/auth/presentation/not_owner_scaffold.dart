import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/widgets/app_states.dart';
import '../domain/app_user.dart';
import 'auth_providers.dart';

/// L'écran à montrer tant que le droit de modifier n'est pas établi, ou
/// `null` quand l'écran d'édition peut s'afficher.
///
/// Compte en cours de lecture : chargement, sous la barre de l'écran. Lecture
/// en échec : l'erreur et « Réessayer » — ce n'est pas un refus. Compte lu
/// sans le droit : [NotOwnerScaffold].
///
/// [userAsync] est lu par l'appelant avec `ref.watch(appUserProvider)` dans
/// son `build` — pas dans un `builder` imbriqué.
Widget? ownershipGate({
  required WidgetRef ref,
  required AsyncValue<AppUser?> userAsync,
  required String title,
  required String message,
  required String fallbackLocation,
  required bool Function(AppUser user) canModify,
}) {
  if (userAsync.hasError) {
    return Scaffold(
      appBar: AppBar(title: Text(title)),
      body: AppErrorState(
        error: userAsync.error,
        onRetry: () => ref.invalidate(appUserProvider),
      ),
    );
  }
  final user = userAsync.value;
  if (user == null && userAsync.isLoading) {
    return Scaffold(
      appBar: AppBar(title: Text(title)),
      body: const AppLoadingState(),
    );
  }
  if (user != null && canModify(user)) return null;
  return NotOwnerScaffold(
    title: title,
    message: message,
    fallbackLocation: fallbackLocation,
  );
}

/// Écran d'édition ouvert par un lien sur le contenu d'un autre.
///
/// Les routes d'édition ne portent aucun droit (le routeur ne décide que de
/// l'accès à l'application) : c'est l'écran qui le dit, avant toute saisie.
/// Sans lui, la personne remplissait le formulaire et ne découvrait le refus
/// des règles Firestore qu'à l'enregistrement.
class NotOwnerScaffold extends StatelessWidget {
  final String title;
  final String message;

  /// Où revenir quand l'écran a été ouvert directement, sans page précédente.
  final String fallbackLocation;

  const NotOwnerScaffold({
    super.key,
    required this.title,
    required this.message,
    required this.fallbackLocation,
  });

  @override
  Widget build(BuildContext context) {
    void back() {
      if (context.canPop()) {
        context.pop();
      } else {
        context.go(fallbackLocation);
      }
    }

    return Scaffold(
      appBar: AppBar(title: Text(title)),
      body: AppEmptyState(
        icon: Icons.lock_outline,
        title: message,
        message: 'La consultation reste possible.',
        action: FilledButton.icon(
          onPressed: back,
          icon: const Icon(Icons.arrow_back),
          label: const Text('Retour'),
        ),
      ),
    );
  }
}
