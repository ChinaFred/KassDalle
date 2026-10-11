import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/router/app_router.dart';
import '../../../core/widgets/app_states.dart';
import 'auth_providers.dart';

/// Garde d'un écran réservé aux éditeurs et aux administrateurs.
///
/// Le routeur ne porte pas de droit : un lecteur arrivé par un lien voit ici
/// un état qui le lui dit, au lieu d'un formulaire dont l'envoi serait refusé
/// par les règles Firestore. Tant que le compte n'est pas lu, ni formulaire ni
/// refus prématuré.
class EditorOnlyGate extends ConsumerWidget {
  /// Titre de la barre d'application, le même que celui de l'écran gardé.
  final String appBarTitle;

  /// Titre de l'état affiché au lecteur (« Import réservé aux éditeurs »).
  final String lockedTitle;

  /// Explication affichée au lecteur.
  final String lockedMessage;

  /// L'écran gardé, construit seulement pour un éditeur ou un administrateur.
  final WidgetBuilder builder;

  const EditorOnlyGate({
    super.key,
    required this.appBarTitle,
    required this.lockedTitle,
    required this.lockedMessage,
    required this.builder,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final userAsync = ref.watch(appUserProvider);
    AppBar appBar() => AppBar(title: Text(appBarTitle));

    if (userAsync.isLoading && !userAsync.hasValue) {
      return Scaffold(appBar: appBar(), body: const AppLoadingState());
    }
    if (userAsync.hasError) {
      return Scaffold(
        appBar: appBar(),
        body: AppErrorState(
          error: userAsync.error,
          title: 'Impossible de lire votre compte',
          onRetry: () => ref.invalidate(appUserProvider),
        ),
      );
    }
    // Profil absent compris : sans rôle lu, pas de création.
    final user = userAsync.value;
    if (user == null || !user.canEdit) {
      return Scaffold(
        appBar: appBar(),
        body: AppEmptyState(
          icon: Icons.lock_outline,
          title: lockedTitle,
          message: lockedMessage,
          action: FilledButton.tonal(
            onPressed: () => context.go(AppRoutes.books),
            child: const Text('Retour à la bibliothèque'),
          ),
        ),
      );
    }
    return builder(context);
  }
}
