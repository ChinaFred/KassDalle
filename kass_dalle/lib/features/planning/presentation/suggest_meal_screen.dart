import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../../../core/presentation/leave_guard.dart';
import '../../../core/router/app_router.dart';
import '../../../core/theme/app_icon_size.dart';
import '../../../core/utils/context_extensions.dart';
import '../../../core/utils/platform_utils.dart';
import '../../../core/widgets/app_shortcuts.dart';
import '../../auth/domain/user_profile.dart';
import '../../auth/presentation/auth_providers.dart';
import '../../groups/domain/family_group.dart';
import '../../recipes/domain/recipe.dart';
import '../../recipes/domain/recipe_filter.dart';
import '../data/meal_suggestion_repository.dart';
import '../domain/meal_suggestion.dart';
import 'advanced_dish_search_screen.dart';
import 'meal_suggestion_providers.dart';

/// « Suggérer pour… » sur une fiche recette : l'action, ou `null` si
/// l'utilisateur n'est membre d'aucun groupe actif dont il n'est pas le
/// propriétaire.
VoidCallback? suggestRecipeAction(
  BuildContext context,
  WidgetRef ref,
  Recipe recipe,
) {
  final groups = ref.watch(suggestableGroupsProvider);
  if (groups.isEmpty || recipe.id.isEmpty) return null;
  return () => openSuggestMeal(context, groups: groups, recipe: recipe);
}

/// Ce que la route `/planning/suggest` reçoit en `extra` : des objets, pas des
/// paramètres d'adresse. Sans eux (rechargement de la page), la route renvoie
/// au planning.
class SuggestMealArgs {
  final List<FamilyGroup> groups;
  final FamilyGroup? group;
  final DateTime? day;
  final Recipe? recipe;

  const SuggestMealArgs({
    required this.groups,
    this.group,
    this.day,
    this.recipe,
  });
}

/// Ouvre l'écran « Suggérer un plat ».
///
/// Depuis un jour du planning d'un groupe : [group] et [day] sont fixés, le
/// sous-titre les rappelle. Depuis une fiche recette : [recipe] est choisie,
/// l'écran demande le groupe (s'il y en a plusieurs) et le jour. Le message de
/// succès s'affiche ici, une fois l'écran refermé.
Future<void> openSuggestMeal(
  BuildContext context, {
  required List<FamilyGroup> groups,
  FamilyGroup? group,
  DateTime? day,
  Recipe? recipe,
}) async {
  if (groups.isEmpty && group == null) return;
  final ownerName = await context.push<String>(
    AppRoutes.suggestMeal,
    extra: SuggestMealArgs(
      groups: group != null ? [group] : groups,
      group: group,
      day: day,
      recipe: recipe,
    ),
  );
  if (ownerName == null || !context.mounted) return;
  context.showSuccessSnackBar('Suggestion envoyée à $ownerName.');
}

/// L'écran plein : le plat (une recette de la liste ou un nom libre tapé), le
/// mot facultatif, et l'envoi. Rend, par `pop`, le prénom du propriétaire une
/// fois la suggestion envoyée.
class SuggestMealScreen extends ConsumerStatefulWidget {
  final SuggestMealArgs args;

  const SuggestMealScreen({super.key, required this.args});

  @override
  ConsumerState<SuggestMealScreen> createState() => _SuggestMealScreenState();
}

class _SuggestMealScreenState extends ConsumerState<SuggestMealScreen> {
  late final List<FamilyGroup> _groups = widget.args.groups;
  late FamilyGroup? _group =
      widget.args.group ?? (_groups.length == 1 ? _groups.single : null);
  late DateTime? _day = widget.args.day;

  /// La recette choisie dans la liste ; `null` pour un nom libre.
  late Recipe? _picked = widget.args.recipe;
  late final _dishCtrl = TextEditingController(
    text: widget.args.recipe?.titre ?? '',
  );
  final _noteCtrl = TextEditingController();
  bool _sending = false;

  /// Vrai une fois la suggestion envoyée : l'écran se ferme sans demander de
  /// confirmation.
  bool _leaving = false;
  String? _error;

  static final _dayFormat = DateFormat('EEEE d MMMM', 'fr');

  late final LeaveGuardNotifier _leaveGuardNotifier;
  late final LeaveGuard _leaveGuard = _confirmLeave;

  @override
  void initState() {
    super.initState();
    _leaveGuardNotifier = ref.read(leaveGuardProvider.notifier);
    // Le garde couvre la navigation du bas et le menu latéral, que `PopScope`
    // ne voit pas. Posé après la première image : Riverpod refuse de modifier
    // un provider pendant la construction de l'arbre.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _leaveGuardNotifier.set(_leaveGuard);
    });
  }

  bool get _fixedGroupAndDay => widget.args.group != null && _day != null;

  @override
  void dispose() {
    final notifier = _leaveGuardNotifier;
    final guard = _leaveGuard;
    Future.microtask(() => notifier.clearIf(guard));
    _dishCtrl.dispose();
    _noteCtrl.dispose();
    super.dispose();
  }

  String get _dishTitle => _dishCtrl.text.trim();

  bool get _freeNameTooLong =>
      _picked == null && _dishTitle.length > kSuggestionFreeTitleMax;

  /// Pourquoi « Envoyer » est inactif, ou `null` quand l'envoi est possible.
  String? get _blockReason {
    if (_group == null) return 'Choisissez un groupe.';
    if (_day == null) return 'Choisissez un jour.';
    if (_dishTitle.isEmpty) {
      return 'Tapez un plat ou choisissez une recette.';
    }
    if (_freeNameTooLong) {
      return 'Le nom ne doit pas dépasser $kSuggestionFreeTitleMax caractères.';
    }
    return null;
  }

  bool get _canSend => !_sending && _blockReason == null;

  /// Une saisie qui se perdrait en quittant : un plat tapé ou changé, ou un mot.
  bool get _dirty =>
      _dishTitle != (widget.args.recipe?.titre ?? '') ||
      _noteCtrl.text.trim().isNotEmpty;

  /// Le prénom du propriétaire de [group]. [listen] : suivi dans `build`,
  /// lu une fois dans un geste.
  String _ownerName(FamilyGroup? group, {bool listen = true}) {
    if (group == null) return 'le propriétaire';
    final provider = memberNameProvider(group.ownerId);
    return (listen ? ref.watch(provider) : ref.read(provider)) ??
        UserProfile.fallbackName;
  }

  void _onDishChanged(String value) {
    setState(() {
      // Retoucher le texte d'une recette choisie la ramène à un nom libre.
      if (_picked != null && value.trim() != _picked!.titre) _picked = null;
      _error = null;
    });
  }

  void _pickRecipe(Recipe recipe) {
    FocusScope.of(context).unfocus();
    setState(() {
      _picked = recipe;
      _dishCtrl.text = recipe.titre;
      _error = null;
    });
  }

  /// Ouvre la recherche avancée, avec le texte déjà saisi. Elle rend une
  /// recette choisie ou un nom libre ; la flèche de retour ne change rien.
  Future<void> _openAdvancedSearch() async {
    final pick = await context.push<AdvancedDishPick>(
      AppRoutes.suggestMealSearch,
      extra: AdvancedDishSearchArgs(
        initialQuery: _dishTitle,
        pickedId: _picked?.id,
      ),
    );
    if (pick == null || !mounted) return;
    final recipe = pick.recipe;
    if (recipe != null) {
      _pickRecipe(recipe);
      return;
    }
    setState(() {
      _picked = null;
      _dishCtrl.text = pick.freeName!;
      _error = null;
    });
  }

  void _useFreeName() {
    FocusScope.of(context).unfocus();
    setState(() => _picked = null);
  }

  Future<void> _pickDay() async {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final picked = await showDatePicker(
      context: context,
      initialDate: _day ?? today,
      firstDate: today,
      // Les règles refusent un jour plus lointain que soixante jours.
      lastDate: lastSuggestionDay(today),
      helpText: 'Jour du repas',
    );
    if (picked == null || !mounted) return;
    setState(() => _day = DateTime(picked.year, picked.month, picked.day));
  }

  Future<void> _send() async {
    if (!_canSend) return;
    final uid = ref.read(appUserProvider).value?.uid;
    final group = _group!;
    if (uid == null) return;
    final ownerName = _ownerName(group, listen: false);
    setState(() {
      _sending = true;
      _error = null;
    });
    try {
      await ref
          .read(mealSuggestionRepositoryProvider)
          .suggest(
            MealSuggestionDraft(
              groupId: group.id,
              groupOwnerId: group.ownerId,
              day: _day!,
              recipeId: _picked?.id,
              title: _picked?.titre ?? _dishTitle,
              note: _noteCtrl.text,
            ),
            uid,
          );
      if (!mounted) return;
      // `PopScope` lit `_leaving` à la reconstruction : on ferme à l'image
      // suivante.
      setState(() => _leaving = true);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) Navigator.of(context).pop(ownerName);
      });
    } on SuggestionLimitReached {
      if (!mounted) return;
      const message =
          'Vous avez déjà fait $kSuggestionsPerAuthorPerDay suggestions '
          'pour ce jour.';
      setState(() {
        _sending = false;
        _error = message;
      });
      context.showErrorSnackBar(message);
    } catch (_) {
      // Remontée au rapport par le repository ; la saisie reste en place.
      if (!mounted) return;
      const message = 'Suggestion non envoyée. Réessayez.';
      setState(() {
        _sending = false;
        _error = message;
      });
      context.showErrorSnackBar(message);
    }
  }

  /// Vrai quand l'écran peut se fermer : rien à perdre, ou abandon confirmé.
  Future<bool> _confirmLeave() async {
    if (!_dirty || _leaving) return true;
    final leave = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Abandonner la suggestion ?'),
        content: const Text('Ce que vous avez saisi ne sera pas envoyé.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Rester'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('Abandonner'),
          ),
        ],
      ),
    );
    return leave ?? false;
  }

  /// Icône seule sur téléphone, icône et texte sur grand écran. Alignée sur le
  /// champ (56 de haut).
  Widget _advancedSearchButton() {
    final wide =
        MediaQuery.sizeOf(context).width >= PlatformUtils.wideBreakpoint;
    final onPressed = _sending ? null : _openAdvancedSearch;
    return wide
        ? ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 56),
            child: FilledButton.tonalIcon(
              onPressed: onPressed,
              icon: const Icon(Icons.manage_search),
              label: const Text('Recherche avancée'),
            ),
          )
        : SizedBox.square(
            dimension: 56,
            child: IconButton.filledTonal(
              tooltip: 'Recherche avancée',
              onPressed: onPressed,
              icon: const Icon(Icons.manage_search),
            ),
          );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final group = _group;
    final day = _day;
    final ownerName = _ownerName(group);
    final recipesAsync = ref.watch(suggestableRecipesProvider);
    // Les livres privés des membres de mes groupes : titre seul, après la
    // liste habituelle, sans doublon.
    final own = recipesAsync.value ?? const <Recipe>[];
    final known = {for (final r in own) r.id};
    final recipes = [
      ...own,
      ...?ref
          .watch(suggestablePrivateTitlesProvider)
          .value
          ?.where((r) => !known.contains(r.id)),
    ];
    final matches = filterPickerRecipes(recipes, query: _dishCtrl.text);
    final freeName = _dishTitle;
    final showFreeTile = freeName.isNotEmpty && !_freeNameTooLong;
    final picked = _picked;
    final blockReason = _blockReason;
    final subtitle = [
      if (group != null && (_fixedGroupAndDay || _groups.length == 1))
        group.name,
      if (day != null && _fixedGroupAndDay) _dayFormat.format(day),
    ].join(' · ');
    final muted = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    final errorStyle = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.error,
    );

    // Ctrl/Cmd+S par les raccourcis communs, Ctrl/Cmd+Entrée en plus.
    return AppShortcuts(
      onSave: _send,
      child: CallbackShortcuts(
        bindings: {
          const SingleActivator(LogicalKeyboardKey.enter, control: true): _send,
          const SingleActivator(LogicalKeyboardKey.enter, meta: true): _send,
        },
        child: PopScope(
          canPop: !_dirty || _leaving,
          onPopInvokedWithResult: (didPop, _) {
            if (didPop) return;
            _confirmLeave().then((leave) {
              if (leave && context.mounted) Navigator.of(context).pop();
            });
          },
          child: Scaffold(
            appBar: AppBar(
              title: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('Suggérer un plat'),
                  if (subtitle.isNotEmpty)
                    Text(
                      subtitle,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                ],
              ),
            ),
            body: Align(
              alignment: Alignment.topCenter,
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 640),
                child: Column(
                  children: [
                    Expanded(
                      child: CustomScrollView(
                        keyboardDismissBehavior:
                            ScrollViewKeyboardDismissBehavior.onDrag,
                        slivers: [
                          SliverPadding(
                            padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
                            sliver: SliverList.list(
                              children: [
                                if (!_fixedGroupAndDay && _groups.length > 1)
                                  Padding(
                                    padding: const EdgeInsets.only(bottom: 8),
                                    child: DropdownButtonFormField<String>(
                                      initialValue: group?.id,
                                      decoration: const InputDecoration(
                                        labelText: 'Groupe',
                                        border: OutlineInputBorder(),
                                      ),
                                      items: [
                                        for (final g in _groups)
                                          DropdownMenuItem(
                                            value: g.id,
                                            child: Text(g.name),
                                          ),
                                      ],
                                      onChanged: _sending
                                          ? null
                                          : (id) => setState(
                                              () => _group = _groups.firstWhere(
                                                (g) => g.id == id,
                                              ),
                                            ),
                                    ),
                                  ),
                                if (!_fixedGroupAndDay)
                                  ListTile(
                                    contentPadding: EdgeInsets.zero,
                                    leading: const Icon(Icons.event_outlined),
                                    title: const Text('Jour'),
                                    subtitle: Text(
                                      day == null
                                          ? 'Choisir un jour'
                                          : _dayFormat.format(day),
                                    ),
                                    trailing: const Icon(Icons.chevron_right),
                                    onTap: _sending ? null : _pickDay,
                                  ),
                                Row(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Expanded(
                                      child: TextField(
                                        controller: _dishCtrl,
                                        enabled: !_sending,
                                        autofocus: widget.args.recipe == null,
                                        textCapitalization:
                                            TextCapitalization.sentences,
                                        textInputAction: TextInputAction.search,
                                        decoration: InputDecoration(
                                          labelText: 'Quel plat ?',
                                          hintText:
                                              'Une recette, ou un nom libre : des '
                                              'frites…',
                                          prefixIcon: const Icon(Icons.search),
                                          border: const OutlineInputBorder(),
                                          suffixIcon: _dishCtrl.text.isEmpty
                                              ? null
                                              : IconButton(
                                                  tooltip: 'Effacer',
                                                  icon: const Icon(Icons.clear),
                                                  onPressed: _sending
                                                      ? null
                                                      : () {
                                                          _dishCtrl.clear();
                                                          _onDishChanged('');
                                                        },
                                                ),
                                        ),
                                        onChanged: _onDishChanged,
                                      ),
                                    ),
                                    const SizedBox(width: 8),
                                    _advancedSearchButton(),
                                  ],
                                ),
                                if (_freeNameTooLong)
                                  Padding(
                                    padding: const EdgeInsets.only(top: 4),
                                    child: Text(
                                      'Le nom ne doit pas dépasser '
                                      '$kSuggestionFreeTitleMax caractères.',
                                      style: errorStyle,
                                    ),
                                  ),
                                if (picked != null &&
                                    picked.id.isNotEmpty &&
                                    picked.isPrivate)
                                  Padding(
                                    padding: const EdgeInsets.only(top: 8),
                                    child: Row(
                                      children: [
                                        Icon(
                                          Icons.lock_outline,
                                          size: 16,
                                          color: theme
                                              .colorScheme
                                              .onSurfaceVariant,
                                        ),
                                        const SizedBox(width: 6),
                                        Expanded(
                                          child: Text(
                                            'Recette privée : $ownerName ne '
                                            'verra que son titre.',
                                            style: muted,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                const SizedBox(height: 16),
                                TextField(
                                  controller: _noteCtrl,
                                  enabled: !_sending,
                                  maxLength: kSuggestionNoteMax,
                                  minLines: 1,
                                  maxLines: 3,
                                  textCapitalization:
                                      TextCapitalization.sentences,
                                  decoration: InputDecoration(
                                    labelText:
                                        'Un mot pour $ownerName (facultatif)',
                                    hintText: 'Pour l\'anniversaire de Léo',
                                    border: const OutlineInputBorder(),
                                  ),
                                  onChanged: (_) => setState(() {}),
                                ),
                                const SizedBox(height: 8),
                                if (recipesAsync.hasError)
                                  Padding(
                                    padding: const EdgeInsets.only(bottom: 8),
                                    child: Row(
                                      children: [
                                        Expanded(
                                          child: Text(
                                            'Les recettes n\'ont pas pu être '
                                            'lues. Un nom libre reste possible.',
                                            style: errorStyle,
                                          ),
                                        ),
                                        TextButton(
                                          onPressed: () => ref.invalidate(
                                            suggestableRecipesProvider,
                                          ),
                                          child: const Text('Réessayer'),
                                        ),
                                      ],
                                    ),
                                  ),
                                if (showFreeTile)
                                  ListTile(
                                    contentPadding: EdgeInsets.zero,
                                    leading: const CircleAvatar(
                                      child: Icon(
                                        Icons.edit_outlined,
                                        size: AppIconSize.small,
                                      ),
                                    ),
                                    title: Text('Utiliser « $freeName »'),
                                    subtitle: const Text(
                                      'Repas libre (sans recette liée)',
                                    ),
                                    trailing: picked == null
                                        ? const Icon(Icons.check)
                                        : null,
                                    onTap: _sending ? null : _useFreeName,
                                  ),
                              ],
                            ),
                          ),
                          SliverPadding(
                            padding: const EdgeInsets.symmetric(horizontal: 16),
                            sliver: SliverList.builder(
                              itemCount: matches.length,
                              itemBuilder: (_, i) {
                                final r = matches[i];
                                final selected =
                                    picked != null && picked.id == r.id;
                                return ListTile(
                                  contentPadding: EdgeInsets.zero,
                                  title: Text(r.titre),
                                  subtitle: r.isPrivate && r.bookTitre != null
                                      ? Text(r.bookTitre!)
                                      : null,
                                  trailing: selected
                                      ? const Icon(Icons.check_circle)
                                      : r.isPrivate
                                      ? Tooltip(
                                          message: 'Seul le titre est visible',
                                          child: Icon(
                                            Icons.lock_outline,
                                            size: AppIconSize.small,
                                            semanticLabel:
                                                'Seul le titre est visible',
                                            color: theme
                                                .colorScheme
                                                .onSurfaceVariant,
                                          ),
                                        )
                                      : null,
                                  onTap: _sending ? null : () => _pickRecipe(r),
                                );
                              },
                            ),
                          ),
                          const SliverToBoxAdapter(child: SizedBox(height: 16)),
                        ],
                      ),
                    ),
                    Material(
                      elevation: 4,
                      color: theme.colorScheme.surface,
                      child: SafeArea(
                        top: false,
                        child: Padding(
                          padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              if (_error != null)
                                Padding(
                                  padding: const EdgeInsets.only(bottom: 4),
                                  child: Text(_error!, style: errorStyle),
                                )
                              else if (blockReason != null && !_freeNameTooLong)
                                Padding(
                                  padding: const EdgeInsets.only(bottom: 4),
                                  child: Text(blockReason, style: muted),
                                ),
                              FilledButton.icon(
                                onPressed: _canSend ? _send : null,
                                icon: _sending
                                    ? const SizedBox(
                                        width: 16,
                                        height: 16,
                                        child: CircularProgressIndicator(
                                          strokeWidth: 2,
                                          semanticsLabel: 'Envoi en cours',
                                        ),
                                      )
                                    : const Icon(Icons.send_outlined),
                                label: const Text('Envoyer la suggestion'),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
