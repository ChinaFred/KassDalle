import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../widgets/app_states.dart';
import 'app_router.dart' show AppRoutes;

/// Page affichée par go_router quand l'adresse ne correspond à aucune route.
///
/// Le texte de `GoRouterState.error` (« no routes for location: … ») est un
/// message de développeur en anglais : il n'est pas affiché. La page dit ce
/// qui se passe et ramène à la bibliothèque.
class RouteNotFoundScreen extends StatelessWidget {
  const RouteNotFoundScreen({super.key});

  static const title = 'Page introuvable';
  static const message =
      'Ce lien ne mène à aucune page de Kass\'Dalle. Il a peut-être été mal '
      'copié, ou la page a changé d\'adresse.';
  static const backLabel = 'Retour à la bibliothèque';

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: AppEmptyState(
          icon: Icons.link_off_outlined,
          title: title,
          message: message,
          action: FilledButton.icon(
            onPressed: () => context.go(AppRoutes.books),
            icon: const Icon(Icons.library_books_outlined),
            label: const Text(backLabel),
          ),
        ),
      ),
    );
  }
}
