import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/presentation/adaptive_sheet.dart';
import '../../../core/router/app_router.dart';
import '../../../core/widgets/app_states.dart';
import '../../groups/presentation/group_providers.dart';
import '../domain/planning_target.dart';
import 'default_planning_target.dart';
import 'planning_providers.dart';

/// « Nouveau planning » : ouvre l'écran de génération sur le planning
/// choisi.
///
/// Sans groupe dont l'utilisateur est le propriétaire, l'écran s'ouvre sur
/// « Mon planning », comme avant. Sinon, ou tant que ses groupes ne sont pas
/// lus, la liste « Planifier pour… » demande lequel.
///
/// [start] : le premier jour de la période affichée, transmis dans les deux
/// cas ; le cycle commence ce jour-là (`?start=`). Null : le prochain cycle.
Future<void> openNewPlanning(
  BuildContext context,
  WidgetRef ref, {
  DateTime? start,
}) async {
  final owned = ref.read(ownedPlanningGroupsProvider);
  if (owned.hasValue && owned.value!.isEmpty) {
    await context.push(batchPlanningLocation(start: start));
    return;
  }
  final target = await showPlanningTargetSheet(context);
  if (target == null || !context.mounted) return;
  await context.push(
    batchPlanningLocation(groupId: target.groupId, start: start),
  );
}

/// L'adresse de « Nouveau planning » pour un planning : `/planning/batch`,
/// suivie de `?group=<id>` pour celui d'un groupe, et de `start=AAAA-MM-JJ`
/// pour un cycle qui commence ce jour-là.
String batchPlanningLocation({String? groupId, DateTime? start}) {
  final query = {
    kPlanningGroupParam: ?groupId,
    if (start != null) kPlanningStartParam: planningDayParam(start),
  };
  if (query.isEmpty) return AppRoutes.batchPlanning;
  return Uri(path: AppRoutes.batchPlanning, queryParameters: query).toString();
}

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
/// dont l'utilisateur est le propriétaire. Le planning par défaut passe en
/// tête, marqué « Par défaut ».
class PlanningTargetList extends ConsumerWidget {
  const PlanningTargetList({super.key});

  /// « Par défaut · Planning du groupe · 4 membres », « Par défaut » sur
  /// « Mon planning » quand c'est lui.
  static Widget? _subtitle(PlanningTarget target, {required bool isDefault}) {
    final parts = [if (isDefault) 'Par défaut', ?target.subtitle];
    return parts.isEmpty ? null : Text(parts.join(' · '));
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final owned = ref.watch(ownedPlanningGroupsProvider);
    final defaultTarget = ref.watch(defaultPlanningTargetProvider);
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
      final targets = planningTargetsDefaultFirst(
        ownedGroups: owned.value!,
        defaultTarget: defaultTarget.value,
      );
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
              subtitle: _subtitle(
                target,
                isDefault: target == defaultTarget.value,
              ),
              onTap: () {
                // Sans défaut valide, le planning touché le devient.
                final memo = FirstPlanningTargetMemo.capture(context, ref);
                Navigator.of(context).pop(target);
                unawaited(memo.store(target));
              },
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
