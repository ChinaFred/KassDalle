import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show SystemNavigator;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../core/presentation/leave_guard.dart';
import '../../../core/router/app_router.dart';
import '../../../core/presentation/stylus_pad_text_field.dart';
import '../../../core/services/error_reporting.dart';
import '../../../core/theme/app_icon_size.dart';
import '../../../core/utils/context_extensions.dart';
import '../../../core/utils/platform_utils.dart';
import '../../../core/widgets/app_states.dart';
import '../../auth/presentation/auth_providers.dart';
import '../../recipes/domain/recipe_filter.dart';
import '../../recipes/presentation/url_import/url_import_dialog.dart';
import '../domain/explore_facets.dart';
import '../domain/search_models.dart';
import 'explore_filter_panel.dart';
import 'generated_recipe_screen.dart';
import 'search_providers.dart';
import 'search_widgets.dart';

/// L'écran Explorer (`/search`).
///
/// À l'ouverture, la liste des recettes des sources choisies. Le champ filtre
/// cette liste à chaque frappe, sur l'appareil, sans IA. L'IA ne part que sur
/// un bouton : « Demander à l'IA » (classement, éditeurs et administrateurs)
/// et « Imaginer 3 recettes » (création, mêmes rôles). « Chercher sur Google »
/// ouvre le texte tel quel, sans appel d'IA.
class SearchScreen extends ConsumerStatefulWidget {
  const SearchScreen({super.key});

  @override
  ConsumerState<SearchScreen> createState() => _SearchScreenState();
}

class _SearchScreenState extends ConsumerState<SearchScreen> {
  final _controller = TextEditingController();
  final _focusNode = FocusNode();
  final _scrollController = ScrollController();

  /// Aide posée sous le champ quand un bouton d'IA est pressé sans texte.
  String? _fieldHelp;

  // Garde de sortie : des idées de l'IA non enregistrées se perdent en
  // quittant l'écran. La navigation du bas et le menu latéral appellent
  // `context.go`, que `PopScope` ne voit pas (voir `leave_guard.dart`).
  late final LeaveGuardNotifier _leaveGuardNotifier;
  late final LeaveGuard _leaveGuard = _confirmLeave;
  bool _leaveGuardSet = false;

  @override
  void initState() {
    super.initState();
    _leaveGuardNotifier = ref.read(leaveGuardProvider.notifier);
    WidgetsBinding.instance.addPostFrameCallback((_) => _consumeFocusRequest());
  }

  @override
  void dispose() {
    // Différé : un provider ne se modifie pas pendant le démontage de l'arbre.
    final notifier = _leaveGuardNotifier;
    final guard = _leaveGuard;
    Future.microtask(() => notifier.clearIf(guard));
    _controller.dispose();
    _focusNode.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  bool get _hasUnsavedIdeas => switch (ref.read(aiIdeasProvider)) {
    AiIdeasSuccess(:final hasUnsaved) => hasUnsaved,
    _ => false,
  };

  /// Vrai quand l'écran peut être quitté : pas d'idée non enregistrée, ou
  /// l'utilisateur accepte de les perdre.
  Future<bool> _confirmLeave() async {
    if (!_hasUnsavedIdeas) return true;
    final leave = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Quitter sans enregistrer ?'),
        content: const Text(
          'Les recettes imaginées par l\'IA qui ne sont pas enregistrées '
          'seront perdues.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Rester'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Quitter'),
          ),
        ],
      ),
    );
    return leave == true;
  }

  Future<void> _leaveAfterConfirmation() async {
    if (!await _confirmLeave() || !mounted) return;
    ref.read(aiIdeasProvider.notifier).close();
    final router = GoRouter.of(context);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (router.canPop()) {
        router.pop();
      } else if (PlatformUtils.isAndroidApp) {
        // Rien dessous : le retour sans garde aurait quitté l'application.
        unawaited(SystemNavigator.pop());
      }
    });
  }

  /// Pose ou retire le garde selon qu'il reste des idées non enregistrées.
  /// Après le rendu : un provider ne se modifie pas pendant `build`.
  void _syncLeaveGuard(bool dirty) {
    if (dirty == _leaveGuardSet) return;
    _leaveGuardSet = dirty;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (dirty) {
        _leaveGuardNotifier.set(_leaveGuard);
      } else {
        _leaveGuardNotifier.clearIf(_leaveGuard);
      }
    });
  }

  /// Ctrl/Cmd+K : le shell demande le focus du champ.
  void _consumeFocusRequest() {
    if (!mounted) return;
    if (!ref.read(exploreSearchFocusRequestProvider)) return;
    ref.read(exploreSearchFocusRequestProvider.notifier).consume();
    _focusNode.requestFocus();
  }

  String get _query => _controller.text.trim();

  void _updatePrefs(ExplorePreferences next) =>
      ref.read(explorePreferencesProvider.notifier).apply(next);

  /// Un bouton d'IA sans texte : rien ne part, le champ prend le focus et
  /// dit quoi faire.
  bool _requireText(String help) {
    if (_query.isNotEmpty) return true;
    setState(() => _fieldHelp = help);
    _focusNode.requestFocus();
    return false;
  }

  void _askAi(ExploreCorpus corpus, ExplorePreferences prefs) {
    if (!_requireText('Écrivez votre envie pour que l\'IA cherche.')) return;
    FocusScope.of(context).unfocus();
    final aiCorpus = applyRecipeFilter(
      corpus.recipes,
      filter: prefs.filter,
      context: _filterContext(corpus, prefs.filter),
      sort: prefs.sort,
    ).recipes;
    final request = AiRankingRequest(
      query: _query,
      filterSignature: prefs.filter.signature,
      sources: prefs.sources,
      corpus: aiCorpus,
    );
    unawaited(
      ref.read(aiRankingProvider.notifier).rank(request, corpus.myRatings),
    );
    _scrollToTop();
  }

  void _imagine(ExploreCorpus corpus) {
    if (!_requireText(
      'Écrivez votre envie pour que l\'IA imagine des recettes.',
    )) {
      return;
    }
    FocusScope.of(context).unfocus();
    unawaited(ref.read(aiIdeasProvider.notifier).imagine(_query, corpus));
    _scrollToTop();
  }

  Future<void> _searchGoogle() async {
    if (!_requireText('Écrivez ce que vous cherchez sur Google.')) return;
    final uri = googleRecipeSearchUri(_query);
    try {
      final opened = await launchUrl(uri, mode: LaunchMode.externalApplication);
      if (!opened && mounted) {
        context.showErrorSnackBar('Impossible d\'ouvrir Google.');
      }
    } catch (e, stackTrace) {
      reportUnexpectedError(
        feature: 'searchScreen.searchGoogle',
        error: e,
        stackTrace: stackTrace,
      );
      if (mounted) context.showErrorSnackBar('Impossible d\'ouvrir Google.');
    }
  }

  void _scrollToTop() {
    if (!_scrollController.hasClients) return;
    unawaited(
      _scrollController.animateTo(
        0,
        duration: const Duration(milliseconds: 250),
        curve: Curves.easeOut,
      ),
    );
  }

  Future<void> _openGeneratedSuggestion(GeneratedRecipeSuggestion suggestion) {
    final notifier = ref.read(aiIdeasProvider.notifier);
    return Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => GeneratedRecipeScreen(
          recipe: suggestion.recipe,
          onSave: (recipe) async {
            final id = await notifier.saveGeneratedRecipe(recipe);
            notifier.markSaved(suggestion, id);
            return id;
          },
        ),
      ),
    );
  }

  RecipeFilterContext _filterContext(
    ExploreCorpus corpus,
    RecipeFilter filter,
  ) => RecipeFilterContext.forFilter(filter, myRatings: corpus.myRatings);

  /// « Aller plus loin » : trois chemins hors de la bibliothèque.
  Future<void> _openGoFurther(ExploreCorpus corpus, bool canEdit) {
    return showModalBottomSheet<void>(
      context: context,
      useSafeArea: true,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (canEdit)
              ListTile(
                leading: const Icon(Icons.auto_awesome),
                title: const Text('Imaginer 3 recettes'),
                subtitle: const Text(
                  'L\'IA rédige trois recettes sur votre envie, à relire avant '
                  'de les enregistrer en brouillon.',
                ),
                enabled: ref.read(aiIdeasProvider) is! AiIdeasLoading,
                onTap: () {
                  Navigator.pop(ctx);
                  _imagine(corpus);
                },
              ),
            ListTile(
              leading: const Icon(Icons.public),
              title: const Text('Chercher sur Google'),
              subtitle: const Text(
                'Ouvre Google avec votre texte, sans passer par l\'IA.',
              ),
              onTap: () {
                Navigator.pop(ctx);
                unawaited(_searchGoogle());
              },
            ),
            if (canEdit)
              ListTile(
                leading: const Icon(Icons.link),
                title: const Text('Importer depuis un lien'),
                subtitle: const Text(
                  'Une recette d\'une page web arrive dans vos brouillons.',
                ),
                onTap: () {
                  Navigator.pop(ctx);
                  unawaited(showUrlImportDialog(context));
                },
              ),
          ],
        ),
      ),
    );
  }

  /// La feuille plein écran des filtres, sur téléphone.
  Future<void> _openFilterSheet(ExploreCorpus corpus) {
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (ctx) => Padding(
        // « Sans l'ingrédient… » reste au-dessus du clavier.
        padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(ctx).bottom),
        child: _FilterSheet(
          corpus: corpus,
          query: _query,
          showDrafts: ref.read(canEditProvider),
          onChanged: _updatePrefs,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    ref.listen<bool>(exploreSearchFocusRequestProvider, (_, next) {
      if (next) _consumeFocusRequest();
    });
    final prefsAsync = ref.watch(explorePreferencesProvider);
    final ideas = ref.watch(aiIdeasProvider);
    final dirty = ideas is AiIdeasSuccess && ideas.hasUnsaved;
    _syncLeaveGuard(dirty);

    return PopScope(
      canPop: !dirty,
      onPopInvokedWithResult: (didPop, result) {
        if (didPop) return;
        _leaveAfterConfirmation();
      },
      child: Scaffold(
        appBar: AppBar(title: const Text('Explorer')),
        body: prefsAsync.when(
          loading: () =>
              const AppLoadingState(label: 'Chargement des filtres…'),
          // Le dépôt rend les valeurs par défaut sur une lecture en échec :
          // cette branche ne sert qu'à une erreur inattendue.
          error: (error, _) => AppErrorState(
            error: error,
            onRetry: () => ref.invalidate(explorePreferencesProvider),
          ),
          data: (prefs) => _buildForPrefs(prefs),
        ),
      ),
    );
  }

  Widget _buildForPrefs(ExplorePreferences saved) {
    // Le lecteur ne voit pas « Mes brouillons » : ses brouillons n'entrent
    // pas dans le corpus, quelle que soit la préférence enregistrée.
    final prefs = ref.watch(canEditProvider)
        ? saved
        : saved.copyWith(sources: saved.sources.copyWith(includeDrafts: false));
    final corpusAsync = ref.watch(exploreCorpusProvider(prefs.sources));
    return corpusAsync.when(
      skipLoadingOnReload: true,
      loading: () => const AppLoadingState(label: 'Chargement des recettes…'),
      error: (error, _) => AppErrorState(
        error: error,
        title: 'Impossible de charger les recettes',
        onRetry: () => ref.invalidate(exploreCorpusProvider(prefs.sources)),
      ),
      data: (corpus) => _buildLoaded(prefs, corpus),
    );
  }

  Widget _buildLoaded(ExplorePreferences prefs, ExploreCorpus corpus) {
    final canEdit = ref.watch(canEditProvider);
    final filterContext = _filterContext(corpus, prefs.filter);
    final facets = exploreFacets(
      corpus.recipes,
      myUid: corpus.myUid,
      context: filterContext,
    );
    final outcome = applyRecipeFilter(
      corpus.recipes,
      query: _query,
      filter: prefs.filter,
      context: filterContext,
      sort: prefs.sort,
    );
    // Le corpus de « Demander à l'IA » : les filtres, sans le texte.
    final aiCorpusSize = _query.isEmpty
        ? outcome.recipes.length
        : applyRecipeFilter(
            corpus.recipes,
            filter: prefs.filter,
            context: filterContext,
          ).recipes.length;

    final isWide =
        MediaQuery.sizeOf(context).width >= PlatformUtils.wideBreakpoint;
    // Pas de second appel pendant le premier, ni de classement sans corpus.
    final rankingBusy = ref.watch(aiRankingProvider) is AiRankingLoading;
    final ideasBusy = ref.watch(aiIdeasProvider) is AiIdeasLoading;
    final VoidCallback? askAi = rankingBusy || aiCorpusSize == 0
        ? null
        : () => _askAi(corpus, prefs);
    final VoidCallback? imagine = ideasBusy ? null : () => _imagine(corpus);
    final emptyLibrary =
        corpus.recipes.isEmpty && _query.isEmpty && prefs.filter.isEmpty;

    final list = _ResultList(
      scrollController: _scrollController,
      outcome: outcome,
      prefs: prefs,
      corpus: corpus,
      query: _query,
      canEdit: canEdit,
      onClearAll: () =>
          _updatePrefs(prefs.copyWith(filter: prefs.filter.cleared)),
      onRelaunch: askAi,
      onImagine: imagine,
      onOpenIdea: _openGeneratedSuggestion,
      emptyLibrary: emptyLibrary,
      onImport: canEdit ? () => showUrlImportDialog(context) : null,
    );

    final field = _SearchField(
      controller: _controller,
      focusNode: _focusNode,
      help: _fieldHelp,
      onChanged: () => setState(() => _fieldHelp = null),
    );

    if (isWide) {
      return Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(
            width: 300,
            child: ExploreFilterPanel(
              prefs: prefs,
              facets: facets,
              myUid: corpus.myUid,
              showDrafts: canEdit,
              onChanged: _updatePrefs,
            ),
          ),
          const VerticalDivider(width: 1),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                field,
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                  child: Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      if (canEdit)
                        FilledButton.icon(
                          onPressed: askAi,
                          icon: const Icon(
                            Icons.smart_toy_outlined,
                            size: AppIconSize.small,
                          ),
                          label: Text(
                            'Demander à l\'IA · ${recipeCountLabel(aiCorpusSize).toLowerCase()}',
                          ),
                        ),
                      if (canEdit)
                        OutlinedButton.icon(
                          onPressed: imagine,
                          icon: const Icon(
                            Icons.auto_awesome,
                            size: AppIconSize.small,
                          ),
                          label: const Text('Imaginer 3 recettes'),
                        ),
                      OutlinedButton.icon(
                        onPressed: _searchGoogle,
                        icon: const Icon(Icons.public, size: AppIconSize.small),
                        label: const Text('Chercher sur Google'),
                      ),
                      if (canEdit)
                        OutlinedButton.icon(
                          onPressed: () => showUrlImportDialog(context),
                          icon: const Icon(Icons.link, size: AppIconSize.small),
                          label: const Text('Importer depuis un lien'),
                        ),
                    ],
                  ),
                ),
                _StatusLine(
                  outcome: outcome,
                  hasFilters: !prefs.filter.isEmpty,
                  onClearAll: () => _updatePrefs(
                    prefs.copyWith(filter: prefs.filter.cleared),
                  ),
                ),
                Expanded(child: list),
              ],
            ),
          ),
        ],
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        field,
        _ChipBar(
          prefs: prefs,
          facets: facets,
          myUid: corpus.myUid,
          showDrafts: canEdit,
          onOpenFilters: () => _openFilterSheet(corpus),
          onChanged: _updatePrefs,
        ),
        _StatusLine(
          outcome: outcome,
          hasFilters: !prefs.filter.isEmpty,
          onClearAll: () =>
              _updatePrefs(prefs.copyWith(filter: prefs.filter.cleared)),
        ),
        Expanded(child: list),
        _BottomActions(
          canEdit: canEdit,
          aiCorpusSize: aiCorpusSize,
          onAskAi: askAi,
          onGoFurther: () => _openGoFurther(corpus, canEdit),
          onSearchGoogle: _searchGoogle,
        ),
      ],
    );
  }
}

// ── Champ de recherche ───────────────────────────────────────────────────────

class _SearchField extends StatelessWidget {
  final TextEditingController controller;
  final FocusNode focusNode;
  final String? help;
  final VoidCallback onChanged;

  const _SearchField({
    required this.controller,
    required this.focusNode,
    required this.help,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
      child: ListenableBuilder(
        listenable: controller,
        builder: (context, _) => StylusPadTextField(
          controller: controller,
          focusNode: focusNode,
          padTitle: 'Titre, ingrédient, envie…',
          // Entrée ferme le clavier ; rien ne part.
          textInputAction: TextInputAction.done,
          onSubmitted: (_) => FocusScope.of(context).unfocus(),
          onChanged: (_) => onChanged(),
          decoration: InputDecoration(
            hintText: 'Titre, ingrédient, envie…',
            helperText: help,
            helperMaxLines: 2,
            prefixIcon: const Icon(Icons.search),
            suffixIcon: controller.text.isEmpty
                ? null
                : IconButton(
                    tooltip: 'Effacer la recherche',
                    icon: const Icon(Icons.close),
                    onPressed: () {
                      controller.clear();
                      onChanged();
                    },
                  ),
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(14)),
          ),
        ),
      ),
    );
  }
}

// ── Ligne d'état : compteur et recettes écartées ─────────────────────────────

class _StatusLine extends StatelessWidget {
  final RecipeFilterOutcome outcome;
  final bool hasFilters;
  final VoidCallback onClearAll;

  const _StatusLine({
    required this.outcome,
    required this.hasFilters,
    required this.onClearAll,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 8, 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  recipeCountLabel(outcome.recipes.length),
                  style: theme.textTheme.titleSmall,
                ),
                for (final e in outcome.missingData.entries)
                  Text(missingDataLine(e.key, e.value), style: muted),
                if (outcome.estimatedTimeExcluded > 0)
                  Text(
                    estimatedExcludedLine(outcome.estimatedTimeExcluded),
                    style: muted,
                  ),
              ],
            ),
          ),
          if (hasFilters)
            TextButton(
              onPressed: onClearAll,
              child: const Text('Effacer tout'),
            ),
        ],
      ),
    );
  }
}

// ── Téléphone : puces défilantes et bouton « Filtres · N » ────────────────────

class _ChipBar extends ConsumerWidget {
  final ExplorePreferences prefs;
  final ExploreFacets facets;
  final String myUid;
  final bool showDrafts;
  final VoidCallback onOpenFilters;
  final ValueChanged<ExplorePreferences> onChanged;

  const _ChipBar({
    required this.prefs,
    required this.facets,
    required this.myUid,
    required this.showDrafts,
    required this.onOpenFilters,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final filter = prefs.filter;
    final sources = prefs.sources;
    String authorLabel(String uid) =>
        uid == myUid ? 'Moi' : (ref.watch(memberNameProvider(uid)) ?? '…');
    // Pas de hauteur fixe : avec un texte agrandi, les puces grandissent.
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      child: Row(
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: ActionChip(
              avatar: const Icon(Icons.tune, size: AppIconSize.inline),
              label: Text(
                filter.isEmpty ? 'Filtres' : 'Filtres · ${filter.count}',
              ),
              onPressed: onOpenFilters,
            ),
          ),
          for (final d in filter.activeDimensions)
            for (final key in filter.keysOf(d))
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4),
                child: InputChip(
                  label: Text(
                    activeValueLabel(d, key, facets, authorLabel: authorLabel),
                  ),
                  selected: true,
                  showCheckmark: false,
                  deleteButtonTooltipMessage: 'Retirer',
                  onDeleted: () =>
                      onChanged(prefs.copyWith(filter: filter.toggle(d, key))),
                ),
              ),
          for (final (label, selected, next) in [
            (
              'Mes recettes',
              sources.myRecipes,
              sources.copyWith(myRecipes: !sources.myRecipes),
            ),
            (
              'Ma famille',
              sources.familyRecipes,
              sources.copyWith(familyRecipes: !sources.familyRecipes),
            ),
            if (showDrafts)
              (
                'Mes brouillons',
                sources.includeDrafts,
                sources.copyWith(includeDrafts: !sources.includeDrafts),
              ),
          ])
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4),
              child: FilterChip(
                label: Text(label),
                selected: selected,
                onSelected: (_) => onChanged(prefs.copyWith(sources: next)),
              ),
            ),
        ],
      ),
    );
  }
}

/// La feuille plein écran des filtres : le panneau, puis « Effacer tout » et
/// « Voir N recettes ».
class _FilterSheet extends ConsumerWidget {
  final ExploreCorpus corpus;
  final String query;
  final bool showDrafts;
  final ValueChanged<ExplorePreferences> onChanged;

  const _FilterSheet({
    required this.corpus,
    required this.query,
    required this.showDrafts,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final saved =
        ref.watch(explorePreferencesProvider).value ??
        ExplorePreferences.defaults;
    // Même règle que l'écran : pas de brouillons pour un lecteur.
    final prefs = showDrafts
        ? saved
        : saved.copyWith(sources: saved.sources.copyWith(includeDrafts: false));
    // Les sources peuvent changer depuis la feuille : le corpus suit.
    final current =
        ref.watch(exploreCorpusProvider(prefs.sources)).value ?? corpus;
    final filterContext = RecipeFilterContext.forFilter(
      prefs.filter,
      myRatings: current.myRatings,
    );
    final count = applyRecipeFilter(
      current.recipes,
      query: query,
      filter: prefs.filter,
      context: filterContext,
    ).recipes.length;
    final facets = exploreFacets(
      current.recipes,
      myUid: current.myUid,
      context: filterContext,
    );
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 8, 0),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  'Filtres',
                  style: Theme.of(context).textTheme.titleLarge,
                ),
              ),
              IconButton(
                tooltip: 'Fermer',
                icon: const Icon(Icons.close),
                onPressed: () => Navigator.pop(context),
              ),
            ],
          ),
        ),
        Expanded(
          child: ExploreFilterPanel(
            prefs: prefs,
            facets: facets,
            myUid: current.myUid,
            showDrafts: showDrafts,
            onChanged: onChanged,
          ),
        ),
        const Divider(height: 1),
        SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Wrap(
              alignment: WrapAlignment.end,
              spacing: 8,
              runSpacing: 8,
              children: [
                TextButton(
                  onPressed: prefs.filter.isEmpty
                      ? null
                      : () => onChanged(
                          prefs.copyWith(filter: prefs.filter.cleared),
                        ),
                  child: const Text('Effacer tout'),
                ),
                FilledButton(
                  onPressed: () => Navigator.pop(context),
                  child: Text('Voir ${recipeCountLabel(count).toLowerCase()}'),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

/// Barre fixe en bas, au-dessus du clavier : « Demander à l'IA » et « Aller
/// plus loin ». Avec un texte agrandi, elle passe sur deux lignes.
class _BottomActions extends StatelessWidget {
  final bool canEdit;
  final int aiCorpusSize;

  /// Nul pendant un classement en cours ou sans recette à classer.
  final VoidCallback? onAskAi;
  final VoidCallback onGoFurther;
  final VoidCallback onSearchGoogle;

  const _BottomActions({
    required this.canEdit,
    required this.aiCorpusSize,
    required this.onAskAi,
    required this.onGoFurther,
    required this.onSearchGoogle,
  });

  @override
  Widget build(BuildContext context) {
    final stacked = MediaQuery.textScalerOf(context).scale(10) > 15;
    final ask = FilledButton.icon(
      onPressed: onAskAi,
      icon: const Icon(Icons.smart_toy_outlined, size: AppIconSize.small),
      label: Text(
        'Demander à l\'IA · ${recipeCountLabel(aiCorpusSize).toLowerCase()}',
        textAlign: TextAlign.center,
      ),
    );
    final further = OutlinedButton.icon(
      onPressed: onGoFurther,
      icon: const Icon(Icons.explore_outlined, size: AppIconSize.small),
      label: const Text('Aller plus loin', textAlign: TextAlign.center),
    );
    return Material(
      elevation: 3,
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
          // Le lecteur n'a que Google hors de la bibliothèque : le bouton
          // vient directement, sans feuille intermédiaire.
          child: !canEdit
              ? OutlinedButton.icon(
                  onPressed: onSearchGoogle,
                  icon: const Icon(Icons.public, size: AppIconSize.small),
                  label: const Text(
                    'Chercher sur Google',
                    textAlign: TextAlign.center,
                  ),
                )
              : stacked
              ? Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  mainAxisSize: MainAxisSize.min,
                  children: [ask, const SizedBox(height: 8), further],
                )
              : Row(
                  children: [
                    Expanded(flex: 3, child: ask),
                    const SizedBox(width: 8),
                    Expanded(flex: 2, child: further),
                  ],
                ),
        ),
      ),
    );
  }
}

// ── Liste : sections IA puis recettes ────────────────────────────────────────

class _ResultList extends ConsumerWidget {
  final ScrollController scrollController;
  final RecipeFilterOutcome outcome;
  final ExplorePreferences prefs;
  final ExploreCorpus corpus;
  final String query;
  final bool canEdit;
  final VoidCallback onClearAll;

  /// Nuls pendant un appel du même genre déjà en cours.
  final VoidCallback? onRelaunch;
  final VoidCallback? onImagine;
  final ValueChanged<GeneratedRecipeSuggestion> onOpenIdea;

  /// Vrai quand les sources ne rendent aucune recette, sans texte ni filtre.
  final bool emptyLibrary;

  /// « Importer depuis un lien », pour un éditeur ; nul pour un lecteur.
  final VoidCallback? onImport;

  const _ResultList({
    required this.scrollController,
    required this.outcome,
    required this.prefs,
    required this.corpus,
    required this.query,
    required this.canEdit,
    required this.onClearAll,
    required this.onRelaunch,
    required this.onImagine,
    required this.onOpenIdea,
    required this.emptyLibrary,
    required this.onImport,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ranking = ref.watch(aiRankingProvider);
    final ideas = ref.watch(aiIdeasProvider);
    final recipes = outcome.recipes;

    final head = <Widget>[
      ..._rankingSection(context, ref, ranking),
      ..._ideasSection(context, ref, ideas),
      if (ranking is! AiRankingIdle || ideas is! AiIdeasIdle)
        const SearchSectionHeader(title: 'Vos recettes'),
    ];

    if (recipes.isEmpty) {
      final noSource = !prefs.sources.myRecipes && !prefs.sources.familyRecipes;
      return ListView(
        key: const PageStorageKey('explore-results'),
        controller: scrollController,
        children: [
          ...head,
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 24),
            child: noSource
                ? const AppEmptyState(
                    icon: Icons.search_off_rounded,
                    title: 'Aucune source choisie',
                    message: 'Cochez « Mes recettes » ou « Ma famille ».',
                  )
                : emptyLibrary
                ? AppEmptyState(
                    icon: Icons.menu_book_outlined,
                    title: 'Aucune recette pour l\'instant',
                    message: onImport == null
                        ? null
                        : 'Importez une recette depuis une page web pour '
                              'commencer.',
                    action: onImport == null
                        ? null
                        : FilledButton.tonalIcon(
                            onPressed: onImport,
                            icon: const Icon(Icons.link),
                            label: const Text('Importer depuis un lien'),
                          ),
                  )
                : AppEmptyState(
                    icon: Icons.search_off_rounded,
                    title: 'Aucune recette ne correspond',
                    message: 'Modifiez le texte ou les filtres.',
                    action: prefs.filter.isEmpty
                        ? null
                        : FilledButton.tonal(
                            onPressed: onClearAll,
                            child: const Text('Effacer tout'),
                          ),
                  ),
          ),
        ],
      );
    }

    return ListView.builder(
      key: const PageStorageKey('explore-results'),
      controller: scrollController,
      padding: const EdgeInsets.only(bottom: 8),
      itemCount: head.length + recipes.length,
      itemBuilder: (context, i) {
        if (i < head.length) return head[i];
        return SearchResultTile(
          result: RecipeSearchResult(recipe: recipes[i - head.length]),
        );
      },
    );
  }

  Widget _closeButton(VoidCallback onPressed) =>
      TextButton(onPressed: onPressed, child: const Text('Effacer'));

  List<Widget> _rankingSection(
    BuildContext context,
    WidgetRef ref,
    AiRankingState state,
  ) {
    final notifier = ref.read(aiRankingProvider.notifier);
    final request = switch (state) {
      AiRankingIdle() => null,
      AiRankingLoading(:final request) => request,
      AiRankingSuccess(:final request) => request,
      AiRankingError(:final request) => request,
    };
    if (request == null) return const [];

    final stale = request.isStale(
      query: query,
      filterSignature: prefs.filter.signature,
      sources: prefs.sources,
    );

    return [
      _SectionHeader(
        icon: Icons.smart_toy_outlined,
        title: 'Choisies par l\'IA',
        subtitle: '« ${request.query} »',
        trailing: _closeButton(notifier.close),
      ),
      if (stale && state is! AiRankingLoading)
        _Notice(
          text: 'Recherche ou filtres modifiés depuis la demande.',
          actionLabel: 'Relancer',
          onAction: onRelaunch,
        ),
      switch (state) {
        AiRankingLoading() => Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          child: Row(
            children: [
              const SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  'L\'IA lit ${recipeCountLabel(request.corpus.length).toLowerCase()}…',
                ),
              ),
            ],
          ),
        ),
        AiRankingError(:final error) => Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: AppErrorState(
            error: error,
            compact: true,
            // Relance la même demande, pas une remise à zéro.
            onRetry: () => unawaited(notifier.rank(request, corpus.myRatings)),
          ),
        ),
        AiRankingSuccess(
          :final results,
          :final suggestion,
          :final preferenceInsight,
        ) =>
          Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (preferenceInsight != null)
                _InsightCard(text: preferenceInsight),
              if (results.isNotEmpty)
                for (final r in results) SearchResultTile(result: r)
              else ...[
                _SuggestionCard(
                  text:
                      suggestion ??
                      'L\'IA n\'a retenu aucune recette pour cette demande.',
                ),
                if (canEdit)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(12, 4, 12, 0),
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: FilledButton.tonalIcon(
                        onPressed: onImagine,
                        icon: const Icon(
                          Icons.auto_awesome,
                          size: AppIconSize.small,
                        ),
                        label: const Text('Imaginer 3 recettes'),
                      ),
                    ),
                  ),
              ],
            ],
          ),
        AiRankingIdle() => const SizedBox.shrink(),
      },
    ];
  }

  List<Widget> _ideasSection(
    BuildContext context,
    WidgetRef ref,
    AiIdeasState state,
  ) {
    final notifier = ref.read(aiIdeasProvider.notifier);
    final asked = switch (state) {
      AiIdeasIdle() => null,
      AiIdeasLoading(:final query) => query,
      AiIdeasSuccess(:final query) => query,
      AiIdeasError(:final query) => query,
    };
    if (asked == null) return const [];
    return [
      _SectionHeader(
        icon: Icons.auto_awesome,
        title: 'Idées de l\'IA',
        subtitle: '« $asked » — à relire avant de les enregistrer',
        trailing: _closeButton(notifier.close),
      ),
      ...switch (state) {
        AiIdeasLoading() => const [
          Padding(
            padding: EdgeInsets.fromLTRB(16, 0, 16, 4),
            child: Text('L\'IA rédige 3 recettes…'),
          ),
          GeneratedRecipePlaceholderTile(),
          GeneratedRecipePlaceholderTile(),
          GeneratedRecipePlaceholderTile(),
        ],
        AiIdeasSuccess(:final ideas, :final saved) => [
          for (final idea in ideas)
            GeneratedRecipeSuggestionTile(
              suggestion: idea,
              saved: saved.containsKey(idea),
              // Déjà enregistrée : la tuile ouvre le brouillon, pas un
              // second enregistrement.
              onTap: saved[idea] == null
                  ? () => onOpenIdea(idea)
                  : () => context.push('${AppRoutes.drafts}/${saved[idea]}'),
            ),
        ],
        AiIdeasError(:final error) => [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: AppErrorState(
              error: error,
              compact: true,
              onRetry: () => unawaited(notifier.imagine(asked, corpus)),
            ),
          ),
        ],
        AiIdeasIdle() => const <Widget>[],
      },
    ];
  }
}

class _SectionHeader extends StatelessWidget {
  final IconData icon;
  final String title;
  final String? subtitle;
  final Widget trailing;

  const _SectionHeader({
    required this.icon,
    required this.title,
    required this.trailing,
    this.subtitle,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 8, 4),
      child: Row(
        children: [
          Icon(icon, size: AppIconSize.small, color: theme.colorScheme.primary),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
                if (subtitle != null)
                  Text(
                    subtitle!,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
              ],
            ),
          ),
          trailing,
        ],
      ),
    );
  }
}

class _Notice extends StatelessWidget {
  final String text;
  final String actionLabel;
  final VoidCallback? onAction;

  const _Notice({
    required this.text,
    required this.actionLabel,
    required this.onAction,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      margin: const EdgeInsets.fromLTRB(12, 4, 12, 4),
      color: theme.colorScheme.surfaceContainerHighest,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 4, 4, 4),
        child: Row(
          children: [
            Icon(
              Icons.info_outline,
              size: AppIconSize.small,
              color: theme.colorScheme.onSurfaceVariant,
            ),
            const SizedBox(width: 8),
            Expanded(child: Text(text)),
            TextButton(onPressed: onAction, child: Text(actionLabel)),
          ],
        ),
      ),
    );
  }
}

class _SuggestionCard extends StatelessWidget {
  final String text;
  const _SuggestionCard({required this.text});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final fg = theme.colorScheme.onSecondaryContainer;
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      color: theme.colorScheme.secondaryContainer,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(Icons.lightbulb_outline, size: AppIconSize.small, color: fg),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                text,
                style: theme.textTheme.bodyMedium?.copyWith(color: fg),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _InsightCard extends StatelessWidget {
  final String text;
  const _InsightCard({required this.text});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final fg = theme.colorScheme.onTertiaryContainer;
    return Card(
      margin: const EdgeInsets.fromLTRB(12, 4, 12, 4),
      color: theme.colorScheme.tertiaryContainer,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(Icons.smart_toy_outlined, size: AppIconSize.small, color: fg),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                text,
                style: theme.textTheme.bodySmall?.copyWith(color: fg),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
