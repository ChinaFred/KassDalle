import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../../../core/theme/app_icon_size.dart';
import '../../../core/utils/context_extensions.dart';
import '../../../core/utils/platform_utils.dart';
import '../../../core/widgets/app_states.dart';
import '../../../core/services/error_reporting.dart';
import '../../auth/domain/user_profile.dart';
import '../../auth/presentation/auth_providers.dart';
import '../../groups/domain/family_group.dart';
import '../domain/meal_recipe_location.dart';
import '../domain/meal_suggestion.dart';
import '../domain/planned_meal.dart';
import 'meal_suggestion_providers.dart';
import 'planning_providers.dart';
import 'planning_widgets.dart';

/// Ce que le planning fait d'une suggestion retenue par le propriétaire :
/// la poser dans le planning du groupe, ce jour-là.
typedef PlanSuggestion = Future<void> Function(MealSuggestion suggestion);

/// Les deux listes de la fenêtre : les suggestions reçues (propriétaire) et
/// les suggestions envoyées (membre).
enum SuggestionsMode { received, sent }

final _dayFormat = DateFormat('EEEE d MMMM', 'fr');

String _capitalized(String s) =>
    s.isEmpty ? s : '${s[0].toUpperCase()}${s.substring(1)}';

/// Retire [suggestion], avec « Annuler » dans le message de succès. Un échec
/// se dit à l'écran ; le repository l'a déjà remonté au rapport.
Future<void> removeSuggestionWithUndo(
  BuildContext context,
  WidgetRef ref,
  MealSuggestion suggestion,
) async {
  final repo = ref.read(mealSuggestionRepositoryProvider);
  final messenger = ScaffoldMessenger.of(context);
  final scheme = Theme.of(context).colorScheme;
  try {
    await repo.remove(suggestion);
  } catch (_) {
    // Remonté au rapport par le repository.
    if (context.mounted) {
      context.showErrorSnackBar('La suggestion n\'a pas pu être retirée.');
    }
    return;
  }
  if (!context.mounted) return;
  context.showSuccessSnackBar(
    'Suggestion retirée.',
    action: SnackBarAction(
      label: 'Annuler',
      onPressed: () async {
        try {
          await repo.restore(suggestion);
        } catch (_) {
          // Remonté au rapport par le repository.
          messenger.showSnackBar(
            SnackBar(
              backgroundColor: scheme.errorContainer,
              content: Text(
                'La suggestion n\'a pas pu être remise.',
                style: TextStyle(color: scheme.onErrorContainer),
              ),
            ),
          );
        }
      },
    ),
  );
}

/// Le bouton de la barre du planning : « Suggestions des membres » avec le
/// nombre de suggestions des jours à venir pour le propriétaire d'un groupe
/// actif qui compte un autre membre, « Mes suggestions » pour un membre.
/// Rien pour qui n'est ni l'un ni l'autre.
class MealSuggestionsButton extends ConsumerWidget {
  final PlanSuggestion onPlan;

  const MealSuggestionsButton({super.key, required this.onPlan});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final owner = ref.watch(suggestionOwnerGroupsProvider).isNotEmpty;
    final member = ref.watch(suggestableGroupsProvider).isNotEmpty;
    if (!owner && !member) return const SizedBox.shrink();
    final count = owner ? ref.watch(upcomingReceivedCountProvider) : 0;
    return IconButton(
      tooltip: owner ? 'Suggestions des membres' : 'Mes suggestions',
      onPressed: () => showMealSuggestionsWindow(context, onPlan: onPlan),
      icon: Semantics(
        label: owner ? suggestionCountLabel(count) : null,
        child: Badge.count(
          count: count,
          isLabelVisible: count > 0,
          child: const Icon(Icons.lightbulb_outline),
        ),
      ),
    );
  }
}

/// Ouvre la fenêtre des suggestions : feuille à 75 % sur un téléphone,
/// boîte de dialogue de 640 px sur 80 % de la hauteur sur grand écran.
/// [focusDay] et [groupId] : ouverte sur ce jour et ce groupe (repère d'un
/// jour du planning).
Future<void> showMealSuggestionsWindow(
  BuildContext context, {
  required PlanSuggestion onPlan,
  DateTime? focusDay,
  String? groupId,
}) {
  final size = MediaQuery.sizeOf(context);
  if (size.width >= PlatformUtils.wideBreakpoint) {
    return showDialog<void>(
      context: context,
      builder: (_) => Dialog(
        child: SizedBox(
          width: 640,
          height: size.height * 0.8,
          child: MealSuggestionsView(
            onPlan: onPlan,
            focusDay: focusDay,
            groupId: groupId,
            showClose: true,
          ),
        ),
      ),
    );
  }
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
    ),
    builder: (_) => DraggableScrollableSheet(
      initialChildSize: 0.75,
      minChildSize: 0.4,
      maxChildSize: 0.95,
      expand: false,
      builder: (_, controller) => MealSuggestionsView(
        onPlan: onPlan,
        focusDay: focusDay,
        groupId: groupId,
        scrollController: controller,
      ),
    ),
  );
}

/// Une ligne de la liste paresseuse de la fenêtre.
sealed class _Row {
  const _Row();
}

class _DayRow extends _Row {
  final DateTime day;
  final bool past;
  const _DayRow(this.day, {required this.past});
}

class _SuggestionRow extends _Row {
  final MealSuggestion suggestion;
  final bool past;
  const _SuggestionRow(this.suggestion, {required this.past});
}

class _PastToggleRow extends _Row {
  final int count;
  const _PastToggleRow(this.count);
}

class _EarlierDaysRow extends _Row {
  const _EarlierDaysRow();
}

class _OlderRow extends _Row {
  const _OlderRow();
}

/// Le contenu de la fenêtre des suggestions.
class MealSuggestionsView extends ConsumerStatefulWidget {
  final PlanSuggestion onPlan;
  final DateTime? focusDay;
  final String? groupId;
  final ScrollController? scrollController;
  final bool showClose;

  const MealSuggestionsView({
    super.key,
    required this.onPlan,
    this.focusDay,
    this.groupId,
    this.scrollController,
    this.showClose = false,
  });

  @override
  ConsumerState<MealSuggestionsView> createState() =>
      _MealSuggestionsViewState();
}

class _MealSuggestionsViewState extends ConsumerState<MealSuggestionsView> {
  SuggestionsMode? _mode;
  late String? _groupFilter = widget.groupId;
  late DateTime? _focusDay = widget.focusDay;
  bool _pastExpanded = false;

  /// Suggestions de plus de [kSuggestionHistoryDays] jours, lues à la
  /// demande ; `null` tant qu'on ne les a pas demandées.
  List<MealSuggestion>? _older;
  bool _olderLoading = false;
  bool _olderFailed = false;

  final Set<String> _expandedNotes = {};
  final Set<String> _planning = {};

  /// Recettes reçues lisibles par le propriétaire : vrai si la fiche
  /// s'ouvre, faux si elle n'est pas partagée avec lui.
  final Map<String, bool> _readable = {};
  final Set<String> _readablePending = {};

  SuggestionsMode _modeFor(bool owner, bool member) {
    final chosen = _mode;
    if (chosen == SuggestionsMode.received && owner) return chosen!;
    if (chosen == SuggestionsMode.sent && member) return chosen!;
    return owner ? SuggestionsMode.received : SuggestionsMode.sent;
  }

  Future<void> _loadOlder(SuggestionsMode mode) async {
    final uid = ref.read(appUserProvider).value?.uid;
    if (uid == null) return;
    setState(() {
      _olderLoading = true;
      _olderFailed = false;
    });
    try {
      final older = await ref
          .read(mealSuggestionRepositoryProvider)
          .loadOlder(uid, received: mode == SuggestionsMode.received);
      if (!mounted) return;
      setState(() {
        _older = older;
        _olderLoading = false;
      });
    } catch (_) {
      // Remonté au rapport par le repository.
      if (!mounted) return;
      setState(() {
        _olderLoading = false;
        _olderFailed = true;
      });
    }
  }

  /// Résout, par une lecture groupée, la lisibilité des recettes reçues :
  /// une recette privée s'affiche par son titre, « Recette non partagée ».
  void _resolveReadable(Iterable<MealSuggestion> suggestions) {
    final ids =
        {
          for (final s in suggestions)
            if (s.recipeId != null) s.recipeId!,
        }..removeWhere(
          (id) => _readable.containsKey(id) || _readablePending.contains(id),
        );
    if (ids.isEmpty) return;
    final repo = ref.read(planningRepositoryProvider);
    if (repo == null) return;
    _readablePending.addAll(ids);
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      try {
        final readable = await repo.readableRecipeIds(ids);
        if (!mounted) return;
        setState(() {
          for (final id in ids) {
            _readable[id] = readable.contains(id);
          }
          _readablePending.removeAll(ids);
        });
      } catch (e, stackTrace) {
        reportUnexpectedError(
          feature: 'meal_suggestions.resolve_recipes',
          error: e,
          stackTrace: stackTrace,
          context: {'recipe_count': ids.length},
        );
        if (!mounted) return;
        // Illisible faute de réponse : affichée sans lien, comme non partagée.
        setState(() {
          for (final id in ids) {
            _readable[id] = false;
          }
          _readablePending.removeAll(ids);
        });
      }
    });
  }

  Future<void> _plan(MealSuggestion s) async {
    if (_planning.contains(s.id)) return;
    setState(() => _planning.add(s.id));
    try {
      await widget.onPlan(s);
    } finally {
      if (mounted) setState(() => _planning.remove(s.id));
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final ownerGroups = ref.watch(suggestionOwnerGroupsProvider);
    final memberGroups = ref.watch(suggestableGroupsProvider);
    final owner = ownerGroups.isNotEmpty;
    final member = memberGroups.isNotEmpty;
    final mode = _modeFor(owner, member);
    final received = mode == SuggestionsMode.received;
    final groups = received ? ownerGroups : memberGroups;
    final groupsById = {for (final g in groups) g.id: g};
    if (_groupFilter != null && !groupsById.containsKey(_groupFilter)) {
      _groupFilter = null;
    }
    final async = ref.watch(
      received ? receivedSuggestionsProvider : sentSuggestionsProvider,
    );
    final otherCount = received
        ? (ref.watch(sentSuggestionsProvider).value?.length ?? 0)
        : ref.watch(upcomingReceivedCountProvider);
    final ownCount = async.value?.length ?? 0;

    // Les repas des plannings de groupe : « Déjà prévu », « Au planning ».
    final meals = <PlannedMeal>[
      for (final g in groups)
        if (_groupFilter == null || _groupFilter == g.id)
          ...?ref
              .watch(
                groupPlannedMealsProvider((groupId: g.id, ownerUid: g.ownerId)),
              )
              .value,
    ];

    final title = received ? 'Suggestions des membres' : 'Mes suggestions';

    Widget body;
    if (!async.hasValue && !async.hasError) {
      body = const AppLoadingState();
    } else if (async.hasError && !async.hasValue) {
      body = AppErrorState(
        error: async.error,
        title: 'Les suggestions n\'ont pas pu être lues',
        onRetry: () => ref.invalidate(
          received ? receivedSuggestionsProvider : sentSuggestionsProvider,
        ),
      );
    } else {
      body = _buildList(
        theme,
        suggestions: [
          for (final s in async.value!)
            if (groupsById.containsKey(s.groupId) &&
                (_groupFilter == null || _groupFilter == s.groupId))
              s,
        ],
        older: [
          for (final s in _older ?? const <MealSuggestion>[])
            if (groupsById.containsKey(s.groupId) &&
                (_groupFilter == null || _groupFilter == s.groupId))
              s,
        ],
        mode: mode,
        groupsById: groupsById,
        meals: meals,
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 16, 8, 4),
          child: Row(
            children: [
              Expanded(child: Text(title, style: theme.textTheme.titleLarge)),
              if (widget.showClose)
                TextButton(
                  onPressed: () => Navigator.of(context).maybePop(),
                  child: const Text('Fermer'),
                ),
            ],
          ),
        ),
        if (owner && member)
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 4, 24, 4),
            child: SegmentedButton<SuggestionsMode>(
              segments: [
                ButtonSegment(
                  value: SuggestionsMode.received,
                  label: Text('Reçues (${received ? ownCount : otherCount})'),
                ),
                ButtonSegment(
                  value: SuggestionsMode.sent,
                  label: Text('Envoyées (${received ? otherCount : ownCount})'),
                ),
              ],
              selected: {mode},
              onSelectionChanged: (next) => setState(() {
                _mode = next.single;
                _groupFilter = null;
                _focusDay = null;
                _older = null;
                _olderFailed = false;
                _pastExpanded = false;
              }),
            ),
          ),
        if (groups.length > 1)
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 4),
            child: Row(
              children: [
                ChoiceChip(
                  label: const Text('Tous'),
                  selected: _groupFilter == null,
                  onSelected: (_) => setState(() => _groupFilter = null),
                ),
                for (final g in groups) ...[
                  const SizedBox(width: 8),
                  ChoiceChip(
                    label: Text(g.name),
                    selected: _groupFilter == g.id,
                    onSelected: (_) => setState(() => _groupFilter = g.id),
                  ),
                ],
              ],
            ),
          ),
        const Divider(height: 1),
        Expanded(child: body),
      ],
    );
  }

  Widget _buildList(
    ThemeData theme, {
    required List<MealSuggestion> suggestions,
    required List<MealSuggestion> older,
    required SuggestionsMode mode,
    required Map<String, FamilyGroup> groupsById,
    required List<PlannedMeal> meals,
  }) {
    final received = mode == SuggestionsMode.received;
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    if (received) _resolveReadable([...suggestions, ...older]);

    final upcoming = suggestionsByDay(
      suggestions.where((s) => !s.day.isBefore(today)),
    );
    final past = suggestionsByDay(
      suggestions.where((s) => s.day.isBefore(today)),
    );
    final olderByDay = suggestionsByDay(older);

    if (upcoming.isEmpty && past.isEmpty && olderByDay.isEmpty) {
      return ListView(
        controller: widget.scrollController,
        children: [
          AppEmptyState(
            icon: Icons.lightbulb_outline,
            title: received
                ? 'Aucune suggestion pour l\'instant.'
                : 'Vous n\'avez fait aucune suggestion.',
            message: received
                ? 'Les membres de vos groupes peuvent suggérer un plat sur un '
                      'jour du planning du groupe.'
                : 'Suggérez un plat depuis un jour du planning d\'un groupe, '
                      'ou depuis une fiche recette.',
          ),
          if (_older == null && !_olderLoading)
            Center(
              child: TextButton(
                onPressed: () => _loadOlder(mode),
                child: const Text('Voir les plus anciennes'),
              ),
            ),
        ],
      );
    }

    final focus = _focusDay;
    final rows = <_Row>[];
    var earlierHidden = false;
    for (final entry in upcoming.entries) {
      if (focus != null && entry.key.isBefore(focus)) {
        earlierHidden = true;
        continue;
      }
      rows.add(_DayRow(entry.key, past: false));
      for (final s in entry.value) {
        rows.add(_SuggestionRow(s, past: false));
      }
    }
    if (earlierHidden) rows.insert(0, const _EarlierDaysRow());
    final pastCount = past.values.fold<int>(0, (n, l) => n + l.length);
    if (pastCount > 0 || _older == null || older.isNotEmpty) {
      rows.add(_PastToggleRow(pastCount + older.length));
    }
    if (_pastExpanded) {
      // Les jours passés, du plus récent au plus ancien.
      for (final day in [
        ...past.keys.toList().reversed,
        ...olderByDay.keys.toList().reversed,
      ]) {
        rows.add(_DayRow(day, past: true));
        for (final s in past[day] ?? olderByDay[day]!) {
          rows.add(_SuggestionRow(s, past: true));
        }
      }
      rows.add(const _OlderRow());
    }

    return ListView.builder(
      controller: widget.scrollController,
      padding: const EdgeInsets.only(bottom: 24),
      itemCount: rows.length,
      itemBuilder: (context, i) => switch (rows[i]) {
        _DayRow(:final day, :final past) => _dayHeader(
          theme,
          day,
          past: past,
          meals: meals,
          groupsById: groupsById,
        ),
        _SuggestionRow(:final suggestion, :final past) => _suggestionTile(
          theme,
          suggestion,
          past: past,
          mode: mode,
          groupsById: groupsById,
          meals: meals,
          now: now,
        ),
        _PastToggleRow(:final count) => ListTile(
          title: Text('Jours passés ($count)'),
          trailing: Icon(_pastExpanded ? Icons.expand_less : Icons.expand_more),
          onTap: () => setState(() => _pastExpanded = !_pastExpanded),
        ),
        _EarlierDaysRow() => Align(
          alignment: Alignment.centerLeft,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
            child: TextButton.icon(
              onPressed: () => setState(() => _focusDay = null),
              icon: const Icon(Icons.expand_less),
              label: const Text('Afficher aussi les jours précédents'),
            ),
          ),
        ),
        _OlderRow() => _olderRow(mode),
      },
    );
  }

  Widget _olderRow(SuggestionsMode mode) {
    if (_olderLoading) {
      return const Padding(
        padding: EdgeInsets.all(16),
        child: Center(child: CircularProgressIndicator()),
      );
    }
    if (_olderFailed) {
      return AppErrorState(
        error: null,
        compact: true,
        title: 'Les suggestions plus anciennes n\'ont pas pu être lues',
        onRetry: () => _loadOlder(mode),
      );
    }
    if (_older != null) return const SizedBox.shrink();
    return Center(
      child: TextButton(
        onPressed: () => _loadOlder(mode),
        child: const Text('Voir les plus anciennes'),
      ),
    );
  }

  Widget _dayHeader(
    ThemeData theme,
    DateTime day, {
    required bool past,
    required List<PlannedMeal> meals,
    required Map<String, FamilyGroup> groupsById,
  }) {
    final several = _groupFilter == null && groupsById.length > 1;
    final planned = [
      for (final m in meals)
        if (m.plannedAt.year == day.year &&
            m.plannedAt.month == day.month &&
            m.plannedAt.day == day.day)
          several
              ? '${m.recipeTitre} (${groupsById[m.groupId]?.name ?? 'Groupe'})'
              : m.recipeTitre,
    ];
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            _capitalized(_dayFormat.format(day)),
            style: theme.textTheme.titleSmall?.copyWith(
              fontWeight: FontWeight.w600,
              color: past ? theme.colorScheme.onSurfaceVariant : null,
            ),
          ),
          if (!past)
            Text(
              planned.isEmpty
                  ? 'Rien de prévu ce jour-là'
                  : 'Déjà prévu : ${planned.join(', ')}',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
        ],
      ),
    );
  }

  Widget _suggestionTile(
    ThemeData theme,
    MealSuggestion s, {
    required bool past,
    required SuggestionsMode mode,
    required Map<String, FamilyGroup> groupsById,
    required List<PlannedMeal> meals,
    required DateTime now,
  }) {
    final received = mode == SuggestionsMode.received;
    final recipeId = s.recipeId;
    // L'auteur a choisi sa recette : il la lit. Le propriétaire attend la
    // résolution.
    final readable =
        recipeId != null && (!received || _readable[recipeId] == true);
    final locked = recipeId != null && received && _readable[recipeId] == false;
    final planned = plannedMatchFor(s, meals) != null;
    final group = groupsById[s.groupId];
    final several = _groupFilter == null && groupsById.length > 1;
    // Le prénom de l'auteur se suit dans un `Consumer` : la ligne est
    // construite par la liste paresseuse, hors du `build` de la fenêtre.
    String meta(String? authorName) => [
      received
          ? 'Proposé par ${authorName ?? UserProfile.fallbackName}'
          : 'Pour ${group?.name ?? 'le groupe'}',
      if (received && several && group != null) group.name,
      suggestionAgeLabel(s.createdAt, now),
    ].join(' · ');
    final note = s.note;
    final expanded = _expandedNotes.contains(s.id);

    return ListTile(
      leading: recipeId == null
          ? null
          : Icon(
              locked ? Icons.lock_outline : Icons.menu_book_outlined,
              size: AppIconSize.small,
            ),
      title: Text(s.title),
      onTap: readable
          ? () => context.push(recipeLocationFor(recipeId: recipeId))
          : null,
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (locked) const PlanningRecipeNotSharedLine(),
          if (received)
            Consumer(
              builder: (_, ref, _) =>
                  Text(meta(ref.watch(memberNameProvider(s.authorUid)))),
            )
          else
            Text(meta(null)),
          if (note != null)
            InkWell(
              onTap: () => setState(() {
                if (!_expandedNotes.remove(s.id)) _expandedNotes.add(s.id);
              }),
              child: Text(
                '« $note »',
                maxLines: expanded ? null : 3,
                overflow: expanded ? null : TextOverflow.ellipsis,
                style: theme.textTheme.bodyMedium?.copyWith(
                  fontStyle: FontStyle.italic,
                ),
              ),
            ),
          if (planned)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: const SuggestionPlannedMark(),
            )
          else if (received && !past)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: FilledButton.tonalIcon(
                onPressed: _planning.contains(s.id) ? null : () => _plan(s),
                icon: const Icon(Icons.event_available_outlined),
                label: const Text('Planifier ce jour-là'),
              ),
            ),
        ],
      ),
      trailing: received
          ? null
          : IconButton(
              tooltip: 'Retirer ma suggestion',
              icon: const Icon(Icons.delete_outline),
              onPressed: () => removeSuggestionWithUndo(context, ref, s),
            ),
    );
  }
}

/// « Au planning », avec une coche : le planning du groupe reprend déjà la
/// suggestion ce jour-là.
class SuggestionPlannedMark extends StatelessWidget {
  const SuggestionPlannedMark({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(
          Icons.check_circle_outline,
          size: AppIconSize.badge,
          color: theme.colorScheme.primary,
        ),
        const SizedBox(width: 4),
        Text(
          'Au planning',
          style: theme.textTheme.labelMedium?.copyWith(
            color: theme.colorScheme.primary,
          ),
        ),
      ],
    );
  }
}

/// La suggestion de l'utilisateur sur un jour du planning d'un groupe, sous
/// les repas du groupe : « Votre suggestion : Lasagnes », le mot entre
/// guillemets, et « Retirer ma suggestion ».
class MySuggestionTile extends ConsumerWidget {
  final MealSuggestion suggestion;

  /// Le planning du groupe reprend déjà la suggestion ce jour-là.
  final bool planned;

  const MySuggestionTile({
    super.key,
    required this.suggestion,
    this.planned = false,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    final note = suggestion.note;
    return ListTile(
      dense: true,
      leading: Icon(Icons.lightbulb_outline, color: muted),
      title: Text(
        'Votre suggestion : ${suggestion.title}',
        style: theme.textTheme.bodyMedium?.copyWith(color: muted),
      ),
      subtitle: (note == null && !planned)
          ? null
          : Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                if (note != null)
                  Text(
                    '« $note »',
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                  ),
                if (planned) const SuggestionPlannedMark(),
              ],
            ),
      trailing: IconButton(
        tooltip: 'Retirer ma suggestion',
        icon: const Icon(Icons.delete_outline),
        constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
        onPressed: () => removeSuggestionWithUndo(context, ref, suggestion),
      ),
    );
  }
}

/// Le repère du propriétaire sur un jour du planning d'un groupe :
/// « 2 suggestions ». Un appui ouvre la fenêtre sur ce jour.
class SuggestionsDayMarker extends StatelessWidget {
  final int count;
  final String? groupName;
  final VoidCallback onTap;

  const SuggestionsDayMarker({
    super.key,
    required this.count,
    required this.onTap,
    this.groupName,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = theme.colorScheme.tertiary;
    final label = [suggestionCountLabel(count), ?groupName].join(' · ');
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
        child: Row(
          children: [
            Icon(
              Icons.lightbulb_outline,
              size: AppIconSize.inline,
              color: color,
            ),
            const SizedBox(width: 6),
            Flexible(
              child: Text(
                label,
                style: theme.textTheme.labelLarge?.copyWith(color: color),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
