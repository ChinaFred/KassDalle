import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../../core/presentation/adaptive_sheet.dart';
import '../../../core/utils/context_extensions.dart';
import '../../../core/utils/platform_utils.dart';
import '../../../core/widgets/app_shortcuts.dart';
import '../../auth/domain/user_profile.dart';
import '../../auth/presentation/auth_providers.dart';
import '../../groups/domain/family_group.dart';
import '../../recipes/domain/recipe.dart';
import '../data/meal_suggestion_repository.dart';
import '../domain/meal_suggestion.dart';
import 'meal_suggestion_providers.dart';
import 'recipe_picker_sheet.dart';

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
  return () => showSuggestMealSheet(context, groups: groups, recipe: recipe);
}

/// Ouvre la feuille « Suggérer un plat ».
///
/// Depuis un jour du planning d'un groupe : [group] et [day] sont fixés, le
/// sous-titre les rappelle. Depuis une fiche recette : [recipe] est choisie,
/// la feuille demande le groupe (s'il y en a plusieurs) et le jour. Le
/// message de succès s'affiche ici, une fois la feuille fermée.
Future<void> showSuggestMealSheet(
  BuildContext context, {
  required List<FamilyGroup> groups,
  FamilyGroup? group,
  DateTime? day,
  Recipe? recipe,
}) async {
  if (groups.isEmpty && group == null) return;
  final ownerName = await showAdaptiveSheet<String>(
    context,
    maxWidth: 480,
    child: SuggestMealSheet(
      groups: group != null ? [group] : groups,
      initialGroup: group,
      initialDay: day,
      initialRecipe: recipe,
      fixedGroupAndDay: group != null && day != null,
    ),
  );
  if (ownerName == null || !context.mounted) return;
  context.showSuccessSnackBar('Suggestion envoyée à $ownerName.');
}

/// Le contenu de la feuille : le plat, le mot facultatif, et l'envoi. Rend,
/// par `Navigator.pop`, le prénom du propriétaire une fois la suggestion
/// envoyée.
class SuggestMealSheet extends ConsumerStatefulWidget {
  final List<FamilyGroup> groups;
  final FamilyGroup? initialGroup;
  final DateTime? initialDay;
  final Recipe? initialRecipe;

  /// Groupe et jour viennent du planning : ni l'un ni l'autre ne se change.
  final bool fixedGroupAndDay;

  const SuggestMealSheet({
    super.key,
    required this.groups,
    this.initialGroup,
    this.initialDay,
    this.initialRecipe,
    this.fixedGroupAndDay = false,
  });

  @override
  ConsumerState<SuggestMealSheet> createState() => _SuggestMealSheetState();
}

class _SuggestMealSheetState extends ConsumerState<SuggestMealSheet> {
  late FamilyGroup? _group =
      widget.initialGroup ??
      (widget.groups.length == 1 ? widget.groups.single : null);
  late DateTime? _day = widget.initialDay;

  /// Le plat choisi : une recette (identifiant non vide) ou un nom libre.
  late Recipe? _dish = widget.initialRecipe;
  final _noteCtrl = TextEditingController();
  bool _sending = false;
  String? _error;

  static final _dayFormat = DateFormat('EEEE d MMMM', 'fr');

  @override
  void dispose() {
    _noteCtrl.dispose();
    super.dispose();
  }

  bool get _isFreeName => _dish != null && _dish!.id.isEmpty;

  bool get _freeNameTooLong =>
      _isFreeName && _dish!.titre.trim().length > kSuggestionFreeTitleMax;

  bool get _canSend =>
      !_sending &&
      _group != null &&
      _day != null &&
      _dish != null &&
      _dish!.titre.trim().isNotEmpty &&
      !_freeNameTooLong;

  /// Le prénom du propriétaire de [group]. [listen] : suivi dans `build`,
  /// lu une fois dans un geste.
  String _ownerName(FamilyGroup? group, {bool listen = true}) {
    if (group == null) return 'le propriétaire';
    final provider = memberNameProvider(group.ownerId);
    return (listen ? ref.watch(provider) : ref.read(provider)) ??
        UserProfile.fallbackName;
  }

  Future<void> _pickDish() async {
    final recipesAsync = ref.read(suggestableRecipesProvider);
    List<Recipe> recipes;
    try {
      recipes = await ref.read(suggestableRecipesProvider.future);
      // Les livres privés des membres de mes groupes : titre seul. Une
      // recette déjà proposée par la liste habituelle passe en premier.
      final known = {for (final r in recipes) r.id};
      final privateTitles = await ref.read(
        suggestablePrivateTitlesProvider.future,
      );
      recipes = [
        ...recipes,
        ...privateTitles.where((r) => !known.contains(r.id)),
      ];
    } catch (_) {
      // Déjà remonté au rapport par le provider : on laisse choisir un nom
      // libre, et on dit que les recettes manquent.
      recipes = recipesAsync.value ?? const [];
      if (mounted) {
        setState(
          () => _error = 'Les recettes n\'ont pas pu être lues. Réessayez.',
        );
      }
    }
    if (!mounted) return;
    final picked = await showModalBottomSheet<Recipe>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (_) => RecipePickerSheet(
        recipes: recipes,
        hintText: 'Rechercher ou saisir un nom libre…',
        freeNameAlways: true,
        // Aucun appel d'IA dans une suggestion.
        onGenerateIdeas: null,
        onConceiveIdea: null,
      ),
    );
    if (picked == null || !mounted) return;
    setState(() {
      _dish = picked;
      _error = null;
    });
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
    final dish = _dish!;
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
              recipeId: dish.id.isEmpty ? null : dish.id,
              title: dish.titre,
              note: _noteCtrl.text,
            ),
            uid,
          );
      if (mounted) Navigator.of(context).pop(ownerName);
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

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final group = _group;
    final day = _day;
    final ownerName = _ownerName(group);
    final dish = _dish;
    final subtitle = [
      if (group != null &&
          (widget.fixedGroupAndDay || widget.groups.length == 1))
        group.name,
      if (day != null && widget.fixedGroupAndDay) _dayFormat.format(day),
    ].join(' · ');

    // Ctrl/Cmd+S par les raccourcis communs, Ctrl/Cmd+Entrée en plus. Échap
    // ferme déjà la feuille comme la boîte de dialogue.
    final wide =
        MediaQuery.sizeOf(context).width >= PlatformUtils.wideBreakpoint;
    return AppShortcuts(
      onSave: _send,
      child: CallbackShortcuts(
        bindings: {
          const SingleActivator(LogicalKeyboardKey.enter, control: true): _send,
          const SingleActivator(LogicalKeyboardKey.enter, meta: true): _send,
        },
        child: Focus(
          autofocus: true,
          child: Padding(
            // Sur un téléphone, le bouton reste au-dessus du clavier ; la boîte
            // de dialogue d'un grand écran se place seule.
            padding: EdgeInsets.only(
              bottom: wide ? 0 : MediaQuery.viewInsetsOf(context).bottom,
            ),
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(24, 20, 24, 16),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text('Suggérer un plat', style: theme.textTheme.titleLarge),
                  if (subtitle.isNotEmpty) ...[
                    const SizedBox(height: 4),
                    Text(
                      subtitle,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                  const SizedBox(height: 12),
                  if (!widget.fixedGroupAndDay && widget.groups.length > 1)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: DropdownButtonFormField<String>(
                        initialValue: group?.id,
                        decoration: const InputDecoration(
                          labelText: 'Groupe',
                          border: OutlineInputBorder(),
                        ),
                        items: [
                          for (final g in widget.groups)
                            DropdownMenuItem(value: g.id, child: Text(g.name)),
                        ],
                        onChanged: _sending
                            ? null
                            : (id) => setState(
                                () => _group = widget.groups.firstWhere(
                                  (g) => g.id == id,
                                ),
                              ),
                      ),
                    ),
                  if (!widget.fixedGroupAndDay)
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
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(Icons.restaurant_menu_outlined),
                    title: const Text('Plat'),
                    subtitle: Text(
                      dish == null ? 'Choisir une recette' : dish.titre,
                    ),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: _sending ? null : _pickDish,
                  ),
                  if (dish != null && dish.id.isNotEmpty && dish.isPrivate)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: Row(
                        children: [
                          Icon(
                            Icons.lock_outline,
                            size: 16,
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                          const SizedBox(width: 6),
                          Expanded(
                            child: Text(
                              'Recette privée : $ownerName ne verra que son '
                              'titre.',
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: theme.colorScheme.onSurfaceVariant,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  if (_freeNameTooLong)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: Text(
                        'Le nom ne doit pas dépasser $kSuggestionFreeTitleMax '
                        'caractères.',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.error,
                        ),
                      ),
                    ),
                  const SizedBox(height: 8),
                  TextField(
                    controller: _noteCtrl,
                    enabled: !_sending,
                    maxLength: kSuggestionNoteMax,
                    minLines: 1,
                    maxLines: 3,
                    textCapitalization: TextCapitalization.sentences,
                    decoration: InputDecoration(
                      labelText: 'Un mot pour $ownerName (facultatif)',
                      hintText: 'Pour l\'anniversaire de Léo',
                      border: const OutlineInputBorder(),
                    ),
                  ),
                  if (_error != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: Text(
                        _error!,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.error,
                        ),
                      ),
                    ),
                  const SizedBox(height: 12),
                  Wrap(
                    alignment: WrapAlignment.end,
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      TextButton(
                        onPressed: _sending
                            ? null
                            : () => Navigator.of(context).maybePop(),
                        child: const Text('Annuler'),
                      ),
                      FilledButton.icon(
                        onPressed: _canSend ? _send : null,
                        icon: _sending
                            ? const SizedBox(
                                width: 16,
                                height: 16,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              )
                            : const Icon(Icons.send_outlined),
                        label: const Text('Envoyer la suggestion'),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
