import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../domain/move_meals_request.dart';
import '../../auth/presentation/auth_providers.dart';
import '../../groups/domain/family_group.dart';
import '../../groups/presentation/group_providers.dart';
import '../../../core/widgets/app_states.dart';

/// Demande les paramètres de « Déplacer mes repas vers un groupe » : le
/// groupe cible, parmi les groupes actifs dont l'utilisateur est
/// propriétaire, et la période. Rend `null` si l'utilisateur annule.
Future<MoveMealsRequest?> showMoveMealsToGroupDialog(BuildContext context) {
  return showDialog<MoveMealsRequest>(
    context: context,
    builder: (_) => const MoveMealsToGroupDialog(),
  );
}

class MoveMealsToGroupDialog extends ConsumerStatefulWidget {
  /// Période proposée à l'ouverture ; aucune par défaut.
  final DateTimeRange? initialRange;

  const MoveMealsToGroupDialog({super.key, this.initialRange});

  @override
  ConsumerState<MoveMealsToGroupDialog> createState() =>
      _MoveMealsToGroupDialogState();
}

class _MoveMealsToGroupDialogState
    extends ConsumerState<MoveMealsToGroupDialog> {
  String? _groupId;
  DateTimeRange? _range;

  @override
  void initState() {
    super.initState();
    _range = widget.initialRange;
  }

  Future<void> _pickRange() async {
    final now = DateTime.now();
    final picked = await showDateRangePicker(
      context: context,
      firstDate: DateTime(now.year - 2),
      lastDate: DateTime(now.year + 2, 12, 31),
      initialDateRange: _range,
      helpText: 'Période à déplacer',
      saveText: 'Choisir',
    );
    if (picked != null && mounted) setState(() => _range = picked);
  }

  @override
  Widget build(BuildContext context) {
    final uid = ref.watch(appUserProvider).value?.uid;
    final groupsAsync = ref.watch(myGroupsProvider);
    final pausedAsync = ref.watch(maskedGroupIdsProvider);

    Widget body;
    List<FamilyGroup> groups = const [];
    if ((groupsAsync.hasError && !groupsAsync.hasValue) ||
        (pausedAsync.hasError && !pausedAsync.hasValue)) {
      body = AppErrorState(
        error: groupsAsync.error ?? pausedAsync.error,
        title: 'Vos groupes n\'ont pas pu être lus',
        compact: true,
        onRetry: () {
          ref.invalidate(myGroupsProvider);
          ref.invalidate(maskedGroupIdsProvider);
        },
      );
    } else if (uid == null || !groupsAsync.hasValue || !pausedAsync.hasValue) {
      body = const AppLoadingState(label: 'Lecture de vos groupes…');
    } else {
      groups = ownedActiveGroups(groupsAsync.value!, pausedAsync.value!, uid);
      if (_groupId != null && !groups.any((g) => g.id == _groupId)) {
        _groupId = null;
      }
      // Un seul groupe possible : il est choisi d'office.
      if (_groupId == null && groups.length == 1) _groupId = groups.single.id;
      body = groups.isEmpty
          ? const AppEmptyState(
              icon: Icons.groups_outlined,
              title: 'Aucun groupe à vous',
              message:
                  'Créez un groupe familial depuis l\'écran Groupes, puis '
                  'revenez ici.',
            )
          : _form(context, groups);
    }

    final request = _request(groups);
    return AlertDialog(
      scrollable: true,
      title: const Text('Déplacer mes repas vers un groupe'),
      content: SizedBox(width: 420, child: body),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Annuler'),
        ),
        FilledButton(
          onPressed: request == null
              ? null
              : () => Navigator.of(context).pop(request),
          child: const Text('Continuer'),
        ),
      ],
    );
  }

  MoveMealsRequest? _request(List<FamilyGroup> groups) {
    final range = _range;
    final id = _groupId;
    if (range == null || id == null) return null;
    final group = groups.where((g) => g.id == id).firstOrNull;
    if (group == null) return null;
    final request = MoveMealsRequest(
      groupId: group.id,
      groupName: group.name,
      from: range.start,
      to: range.end,
    );
    return request.isValid ? request : null;
  }

  Widget _form(BuildContext context, List<FamilyGroup> groups) {
    final theme = Theme.of(context);
    final range = _range;
    final tooLong =
        range != null &&
        MoveMealsRequest(
              groupId: '',
              groupName: '',
              from: range.start,
              to: range.end,
            ).dayCount >
            MoveMealsRequest.maxDays;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Text(
          'Les repas de « Mon planning » de la période passent dans le '
          'planning du groupe, et quittent votre planning personnel.',
        ),
        const SizedBox(height: 16),
        DropdownButtonFormField<String>(
          initialValue: _groupId,
          isExpanded: true,
          decoration: const InputDecoration(labelText: 'Groupe'),
          items: [
            for (final g in groups)
              DropdownMenuItem(value: g.id, child: Text(g.name)),
          ],
          onChanged: (id) => setState(() => _groupId = id),
        ),
        const SizedBox(height: 16),
        Text('Période', style: theme.textTheme.labelLarge),
        const SizedBox(height: 8),
        OutlinedButton.icon(
          onPressed: _pickRange,
          icon: const Icon(Icons.date_range_outlined),
          label: Text(
            range == null
                ? 'Choisir la période'
                : formatShortPeriod(range.start, range.end),
          ),
        ),
        if (tooLong) ...[
          const SizedBox(height: 8),
          Text(
            'Choisissez une période de ${MoveMealsRequest.maxDays} jours au '
            'plus.',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.error,
            ),
          ),
        ],
      ],
    );
  }
}
