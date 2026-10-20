import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../features/admin/presentation/admin_providers.dart'
    show errorReportServiceProvider;
import '../../features/auth/presentation/auth_providers.dart';
import '../services/error_reporting.dart';
import '../utils/context_extensions.dart';

/// Ce qu'un écran répond quand on veut le quitter : vrai si on peut partir,
/// faux s'il retient l'utilisateur.
///
/// L'écran qui pose une question — « abandonner cet envoi ? » — la pose ici et
/// renvoie la réponse. Il fait aussi ce que « partir » implique : supprimer ce
/// qui a été envoyé, par exemple.
typedef LeaveGuard = Future<bool> Function();

/// Le garde de l'écran courant, ou null quand l'écran se quitte librement.
///
/// `PopScope` ne voit que le retour : le bouton, le geste, la flèche de la barre.
/// La navigation du bas et le menu latéral appellent `context.go`, qui remplace
/// l'écran sans rien lui demander. Un envoi de livre de plusieurs minutes se
/// perdait ainsi d'un appui sur une icône. Le garde est lu par la navigation
/// avant chaque changement de destination.
class LeaveGuardNotifier extends Notifier<LeaveGuard?> {
  @override
  LeaveGuard? build() => null;

  void set(LeaveGuard guard) => state = guard;

  /// Retire [guard] s'il est toujours celui en place.
  ///
  /// Un écran qui se ferme ne doit pas retirer le garde qu'un autre vient de
  /// poser : les deux écrans peuvent se croiser le temps d'une transition.
  void clearIf(LeaveGuard guard) {
    // Le retrait est différé par l'écran qui se ferme : à l'arrêt de
    // l'application, le conteneur peut être fermé avant qu'il n'arrive.
    if (!ref.mounted) return;
    if (state == guard) state = null;
  }

  /// Remet [previous] en place si [guard] est toujours celui en place.
  ///
  /// Pour un écran poussé par-dessus un écran qui avait déjà son garde (une
  /// idée de l'IA ouverte depuis l'Explorer) : en se fermant, il rend la main
  /// au garde de l'écran du dessous au lieu de le laisser sans garde.
  void restoreIf(LeaveGuard guard, LeaveGuard? previous) {
    if (!ref.mounted) return;
    if (state == guard) state = previous;
  }
}

final leaveGuardProvider = NotifierProvider<LeaveGuardNotifier, LeaveGuard?>(
  LeaveGuardNotifier.new,
);

/// Va vers [route] après avoir demandé à l'écran courant s'il peut être quitté.
Future<void> goGuarded(
  BuildContext context,
  WidgetRef ref,
  String route,
) async {
  final guard = ref.read(leaveGuardProvider);
  if (guard != null && !await guard()) return;
  if (context.mounted) context.go(route);
}

/// Déconnecte le compte après avoir demandé à l'écran courant s'il peut être
/// quitté.
///
/// Se déconnecter ferme tous les écrans : un formulaire en cours de saisie
/// sous l'écran du compte perdait sa saisie sans question. Si le garde refuse,
/// rien ne se passe ; sans garde, la déconnexion part sans confirmation.
Future<void> signOutGuarded(BuildContext context, WidgetRef ref) async {
  try {
    final guard = ref.read(leaveGuardProvider);
    if (guard != null && !await guard()) return;
    if (!context.mounted) return;
    await ref.read(authRepositoryProvider).signOut();
  } catch (error, stackTrace) {
    reportUnexpectedError(
      feature: 'leaveGuard.signOutGuarded',
      error: error,
      stackTrace: stackTrace,
      service: ref.read(errorReportServiceProvider),
    );
    if (!context.mounted) return;
    context.showFailureSnackBar('Déconnexion non effectuée', error);
  }
}
