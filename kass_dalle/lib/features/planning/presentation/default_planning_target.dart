import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/services/error_report_service.dart';
import '../../../core/services/error_reporting.dart';
import '../../../core/utils/context_extensions.dart';
import '../../admin/presentation/admin_providers.dart';
import '../../auth/presentation/auth_providers.dart';
import '../domain/planning_target.dart';
import 'planning_providers.dart';

/// Le message qui annonce le planning par défaut retenu.
String defaultPlanningTargetMessage(
  PlanningTarget target, {
  bool automatic = false,
}) =>
    '« ${target.title} » sera proposé par défaut pour planifier.'
    '${automatic ? ' Modifiable dans Groupes familiaux.' : ''}';

/// La pose automatique du planning par défaut, préparée tant que l'écran qui
/// planifie est ouvert, puis lancée après l'enregistrement du repas — quand
/// cet écran a pu être fermé.
///
/// Rien n'est posé si un défaut valide existe déjà, si le défaut n'est pas
/// encore lu ([currentDefault] en chargement ou en erreur), pour un lecteur,
/// ou sans compte connecté.
class FirstPlanningTargetMemo {
  final AsyncValue<PlanningTarget?> currentDefault;
  final PlanningRepository? repository;
  final ScaffoldMessengerState? messenger;
  final ColorScheme scheme;
  final ErrorReportService? errorReportService;

  /// Le compte peut planifier (éditeur ou administrateur) : un lecteur n'a
  /// rien à retenir, et la règle Firestore refuserait l'écriture.
  final bool canPlan;

  /// Le compte possède au moins un groupe où il planifie. Sans groupe, le
  /// défaut posé (« Mon planning ») ne change rien à l'écran : il est
  /// enregistré sans message.
  final bool hasGroups;

  FirstPlanningTargetMemo({
    required this.currentDefault,
    required this.repository,
    required this.messenger,
    required this.scheme,
    this.errorReportService,
    this.canPlan = true,
    this.hasGroups = true,
  });

  /// Lit ce qu'il faut sur [context] et [ref], avant toute fermeture.
  factory FirstPlanningTargetMemo.capture(
    BuildContext context,
    WidgetRef ref,
  ) => FirstPlanningTargetMemo(
    currentDefault: ref.read(defaultPlanningTargetProvider),
    repository: ref.read(planningRepositoryProvider),
    messenger: ScaffoldMessenger.maybeOf(context),
    scheme: Theme.of(context).colorScheme,
    errorReportService: ref.read(errorReportServiceProvider),
    canPlan: ref.read(canEditProvider),
    hasGroups: ref.read(ownedPlanningGroupsProvider).value?.isNotEmpty ?? false,
  );

  /// Vrai si [chosen] deviendra le défaut une fois confirmé.
  bool get applies =>
      canPlan &&
      repository != null &&
      currentDefault.hasValue &&
      !currentDefault.hasError &&
      currentDefault.value == null;

  /// Enregistre [chosen] comme planning par défaut, si aucun défaut valide
  /// n'existe, puis l'annonce. Un échec est rapporté sans message : le repas
  /// reste enregistré, et la pose est retentée au choix suivant.
  Future<void> store(PlanningTarget chosen) async {
    if (!applies) return;
    try {
      await repository!.saveDefaultPlanningTarget(
        defaultPlanningTargetKey(chosen),
      );
    } catch (error, stackTrace) {
      reportUnexpectedError(
        feature: 'planning.defaultTarget.autoStore',
        error: error,
        stackTrace: stackTrace,
        context: {'group_id': ?chosen.groupId},
        service: errorReportService,
      );
      return;
    }
    if (!hasGroups) return;
    messenger?.showSuccessMessage(
      defaultPlanningTargetMessage(chosen, automatic: true),
      scheme: scheme,
    );
  }
}
