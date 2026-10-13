import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/presentation/adaptive_sheet.dart';
import '../../../core/router/app_router.dart';
import '../../../core/widgets/app_states.dart';
import '../../groups/presentation/group_providers.dart';
import '../domain/planning_target.dart';
import 'planning_providers.dart';

/// « Nouveau planning » : ouvre l'écran de génération sur le planning
/// choisi.
///
/// Sans groupe dont l'utilisateur est le propriétaire, l'écran s'ouvre sur
/// « Mon planning », comme avant. Sinon, ou tant que ses groupes ne sont pas
/// lus, la liste « Planifier pour… » demande lequel.
Future<void> openNewPlanning(BuildContext context, WidgetRef ref) async {
  final owned = ref.read(ownedPlanningGroupsProvider);
  if (owned.hasValue && owned.value!.isEmpty) {
    await context.push(AppRoutes.batchPlanning);
    return;
  }
  final target = await showPlanningTargetSheet(context);
  if (target == null || !context.mounted) return;
  await context.push(batchPlanningLocation(groupId: target.groupId));
}

/// L'adresse de « Nouveau planning » pour un planning : `/planning/batch`,
/// suivie de `?group=<id>` pour celui d'un groupe.
String batchPlanningLocation({String? groupId}) => groupId == null
    ? AppRoutes.batchPlanning
    : Uri(
        path: AppRoutes.batchPlanning,
        queryParameters: {kPlanningGroupParam: groupId},
      ).toString();

/// La liste « Planifier pour… » : feuille du bas sur un téléphone, boîte de
/// dialogue de 480 px au plus sur grand écran. Rend le planning choisi, ou
/// `null` si elle est fermée sans choix.
Future<PlanningTarget?> showPlanningTargetSheet(BuildContext context) =>
    showAdaptiveSheet<PlanningTarget>(
      context,
      maxWidth: 480,
      child: const PlanningTargetList(),
    );

/// Le contenu de « Planifier pour… » : « Mon planning », puis chaque groupe
/// dont l'utilisateur est le propriétaire.
class PlanningTargetList extends ConsumerWidget {
  const PlanningTargetList({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final owned = ref.watch(ownedPlanningGroupsProvider);
    final Widget body;
    if (owned.hasError && !owned.hasValue) {
      body = AppErrorState(
        error: owned.error,
        title: 'Vos groupes n\'ont pas pu être lus',
        compact: true,
        onRetry: () => ref.invalidate(myGroupsProvider),
      );
    } else if (!owned.hasValue) {
      body = const Padding(
        padding: EdgeInsets.all(24),
        child: AppLoadingState(),
      );
    } else {
      final targets = [
        const PlanningTarget.personal(),
        for (final g in owned.value!) PlanningTarget.ofGroup(g),
      ];
      body = Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final target in targets)
            ListTile(
              leading: Icon(
                target.isGroup
                    ? Icons.groups_outlined
                    : Icons.calendar_today_outlined,
              ),
              title: Text(target.title),
              subtitle: target.subtitle == null ? null : Text(target.subtitle!),
              onTap: () => Navigator.of(context).pop(target),
            ),
        ],
      );
    }
    return SafeArea(
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 20, 24, 8),
              child: Text(
                'Planifier pour…',
                style: theme.textTheme.titleMedium,
              ),
            ),
            body,
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
              child: Align(
                alignment: Alignment.centerRight,
                child: TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Text('Annuler'),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
