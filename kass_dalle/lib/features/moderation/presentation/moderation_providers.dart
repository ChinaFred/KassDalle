import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../auth/presentation/auth_providers.dart';
import '../data/image_moderation_service.dart';
import '../data/moderation_repository.dart';
import '../domain/moderation_entry.dart';

final moderationRepositoryProvider = Provider<ModerationRepository>((ref) {
  return ModerationRepository();
});

final imageModerationServiceProvider = Provider<ImageModerationService>((ref) {
  return ImageModerationService();
});

/// Filtre d'état de l'écran d'administration. `null` = tous les états.
///
/// « Tous » est le défaut, et c'est délibéré : une page qui s'ouvrirait sur les
/// seuls rejets cacherait ce que la modération laisse passer, qui est au moins
/// aussi important.
class ModerationStatusFilterNotifier extends Notifier<String?> {
  @override
  String? build() => null;

  void set(String? status) => state = status;
}

final moderationStatusFilterProvider =
    NotifierProvider<ModerationStatusFilterNotifier, String?>(
      ModerationStatusFilterNotifier.new,
    );

/// Fenêtre de temps du journal, en jours. `null` = depuis le début.
class ModerationDaysFilterNotifier extends Notifier<int?> {
  @override
  int? build() => 30;

  void set(int? days) => state = days;
}

final moderationDaysFilterProvider =
    NotifierProvider<ModerationDaysFilterNotifier, int?>(
      ModerationDaysFilterNotifier.new,
    );

/// Le journal, tel que l'écran le montre.
final moderationJournalProvider = StreamProvider<List<ModerationEntry>>((ref) {
  final status = ref.watch(moderationStatusFilterProvider);
  final days = ref.watch(moderationDaysFilterProvider);
  final since = days == null
      ? null
      : DateTime.now().subtract(Duration(days: days));
  return ref
      .watch(moderationRepositoryProvider)
      .watchJournal(status: status, since: since);
});

/// Nombre d'images en attente de décision — la source du badge.
///
/// Réservé aux administrateurs : un lecteur n'a pas le droit de lire le
/// journal, et l'abonnement échouerait sur les règles. Rendre zéro plutôt que
/// d'échouer garde le badge silencieux au lieu de faire remonter une erreur de
/// permission parfaitement attendue.
final pendingModerationCountProvider = StreamProvider<int>((ref) {
  final isAdmin = ref.watch(isAdminProvider);
  if (!isAdmin) return Stream.value(0);
  return ref.watch(moderationRepositoryProvider).watchPendingCount();
});
