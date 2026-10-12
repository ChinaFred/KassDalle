import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart' show SchedulerBinding;
import 'package:flutter/services.dart'
    show Clipboard, ClipboardData, SystemNavigator;
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
import '../../recipes/domain/recipe.dart';
import '../../recipes/domain/recipe_filter.dart';
import '../../recipes/domain/url_import.dart';
import '../../recipes/presentation/url_import/url_import_dialog.dart';
import '../domain/explore_facets.dart';
import '../domain/search_models.dart';
import '../domain/web_search.dart';
import 'explore_filter_panel.dart';
import 'generated_recipe_screen.dart';
import 'google_search_suggestions.dart';
import 'search_providers.dart';
import 'search_widgets.dart';
import 'web_page_opener.dart';

/// L'écran Explorer (`/search`).
///
/// À l'ouverture, la liste des recettes des sources choisies. Le champ filtre
/// cette liste à chaque frappe, sur l'appareil, sans IA, et la range en
/// sections : dans le titre, par cuisine, type ou thème, dans les ingrédients
/// principaux. L'IA ne part que sur un bouton : « Chercher avec l'IA »
/// (classement, éditeurs et administrateurs) et « Imaginer 3 recettes »
/// (création, mêmes rôles). « Chercher sur le web » (tous les rôles) affiche
/// jusqu'à huit pages de recettes trouvées par Google, à ouvrir ou à
/// importer ; « Voir sur Google » ouvre le texte tel quel. Au retour du
/// navigateur, un éditeur voit un bandeau qui propose d'importer la recette.
class SearchScreen extends ConsumerStatefulWidget {
  const SearchScreen({super.key});

  @override
  ConsumerState<SearchScreen> createState() => _SearchScreenState();
}

class _SearchScreenState extends ConsumerState<SearchScreen>
    with WidgetsBindingObserver {
  final _controller = TextEditingController();
  final _focusNode = FocusNode();
  final _scrollController = ScrollController();

  /// Aide posée sous le champ quand un bouton d'IA est pressé sans texte.
  String? _fieldHelp;

  /// Sections de la recherche ouvertes ou fermées à la main, pour le texte
  /// [_sectionsQuery]. Remises à leur état par défaut quand le texte change.
  final Map<RecipeQuerySection, bool> _sectionOpen = {};
  String _sectionsQuery = '';

  // Bandeau « Vous avez trouvé une recette ? Importez-la. » : armé quand
  // « Voir sur Google » ou une page « Sur le web » a ouvert le navigateur,
  // montré au retour dans l'application. En mémoire seulement : il disparaît
  // avec l'écran.
  late final AppLifecycleListener _lifecycle;
  bool _awaitingGoogleReturn = false;
  bool _importBannerVisible = false;

  /// Adresse lue dans le presse-papiers au retour (Android et Windows), ou
  /// celle de la carte « Sur le web » ouverte.
  Uri? _bannerLink;

  /// Adresse de la carte « Sur le web » ouverte : posée dans le bandeau au
  /// retour, sans lire le presse-papiers.
  Uri? _pendingBannerLink;

  /// Vrai quand le bandeau est apparu au retour dans l'application : sa
  /// phrase est alors annoncée. Faux quand il est posé à l'ouverture du
  /// navigateur intégré d'iOS : rien n'est annoncé pendant que la page
  /// couvre l'écran.
  bool _bannerAnnounced = false;

  /// Page « Sur le web » ouverte en dernier : sa carte est ramenée en vue au
  /// retour si le bandeau la recouvre.
  Uri? _openedWebLink;

  /// Clavier ouvert, lu sur la vue elle-même : le `Scaffold` du shell, qui
  /// porte l'écran dans son corps, retire `viewInsets` du `MediaQuery`.
  bool _keyboardOpen = false;

  /// Une clé par carte « Sur le web », pour la ramener en vue.
  final Map<Uri, GlobalKey> _webCardKeys = {};

  /// Pages « Sur le web » dont l'import a été envoyé depuis leur carte.
  final Set<Uri> _importedWebLinks = {};

  /// En-tête de la section « Sur le web », pour y faire défiler la liste.
  final _webSectionKey = GlobalKey();

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
    _lifecycle = AppLifecycleListener(onResume: _onResume);
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) => _consumeFocusRequest());
  }

  bool _viewKeyboardOpen() => View.of(context).viewInsets.bottom > 0;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _keyboardOpen = _viewKeyboardOpen();
  }

  /// Le clavier s'ouvre ou se ferme : le bandeau d'import se masque ou
  /// revient.
  @override
  void didChangeMetrics() {
    if (!mounted) return;
    final open = _viewKeyboardOpen();
    if (open != _keyboardOpen) setState(() => _keyboardOpen = open);
  }

  @override
  void dispose() {
    // Différé : un provider ne se modifie pas pendant le démontage de l'arbre.
    final notifier = _leaveGuardNotifier;
    final guard = _leaveGuard;
    Future.microtask(() => notifier.clearIf(guard));
    _lifecycle.dispose();
    WidgetsBinding.instance.removeObserver(this);
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

  /// « Voir sur Google » : la recherche de la section « Sur le web » ([query])
  /// ou, à défaut, le texte du champ, ouverte dans Google.
  Future<void> _searchGoogle({String? query}) async {
    final asked = query ?? _query;
    if (asked.isEmpty &&
        !_requireText('Écrivez ce que vous cherchez sur Google.')) {
      return;
    }
    final uri = googleRecipeSearchUri(asked);
    try {
      final mode = await openWebPage(uri);
      if (!mounted) return;
      if (mode == null) {
        context.showErrorSnackBar('Impossible d\'ouvrir Google.');
        return;
      }
      // Le bandeau d'import attend le retour ; une nouvelle recherche le
      // réarme. Un lecteur n'importe pas : rien à armer.
      if (ref.read(canEditProvider)) {
        setState(() {
          _awaitingGoogleReturn = true;
          _importBannerVisible = false;
          _bannerLink = null;
          _pendingBannerLink = null;
          _openedWebLink = null;
        });
        _revealBannerNowOnIos(mode);
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

  /// Retour dans l'application après « Voir sur Google » ou l'ouverture
  /// d'une page « Sur le web » : le bandeau d'import apparaît. Une page
  /// ouverte depuis sa carte y pose son adresse. Sinon, sur Android et
  /// Windows, le presse-papiers est lu aussitôt ; sur le web et iOS, il ne
  /// l'est qu'à l'appui sur « Coller le lien » — le navigateur demande une
  /// permission, iOS affiche une alerte.
  void _onResume() => _revealBanner(announce: true);

  /// iOS : SFSafariViewController s'ouvre dans l'application, qui ne quitte
  /// pas le premier plan ; aucun retour n'est signalé. Le bandeau est posé
  /// tout de suite, sans annonce, et se voit à la fermeture de la page.
  ///
  /// Sa phrase n'est pas annoncée à la fermeture non plus, et c'est assumé :
  /// ni le cycle de vie, ni url_launcher (dont l'appel rend la main au
  /// premier chargement de la page, pas à sa fermeture) ne signalent cette
  /// fermeture. Le bandeau reste lisible par le lecteur d'écran comme le
  /// reste de l'écran.
  void _revealBannerNowOnIos(LaunchMode mode) {
    if (mode == LaunchMode.inAppBrowserView &&
        PlatformUtils.hostPlatform == TargetPlatform.iOS) {
      _revealBanner(announce: false);
    }
  }

  /// Montre le bandeau attendu ; [announce] : sa phrase est annoncée.
  void _revealBanner({required bool announce}) {
    if (!_awaitingGoogleReturn || !mounted) return;
    _awaitingGoogleReturn = false;
    final pending = _pendingBannerLink;
    _pendingBannerLink = null;
    if (!ref.read(canEditProvider)) return;
    setState(() {
      _importBannerVisible = true;
      _bannerAnnounced = announce;
      _bannerLink = pending;
    });
    if (pending == null &&
        (PlatformUtils.isAndroidApp || PlatformUtils.isWindowsApp)) {
      unawaited(_readClipboardIntoBanner());
    }
    // Après le rendu : le bandeau a pris sa place sous la liste.
    WidgetsBinding.instance.addPostFrameCallback((_) => _revealOpenedCard());
  }

  /// Ramène en vue la carte ouverte si le bandeau la recouvre ; ne bouge
  /// pas la liste si elle est déjà visible.
  void _revealOpenedCard() {
    final link = _openedWebLink;
    if (!mounted || link == null) return;
    final target = _webCardKeys[link]?.currentContext;
    if (target == null) return;
    unawaited(
      Scrollable.ensureVisible(
        target,
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeOut,
        alignmentPolicy: ScrollPositionAlignmentPolicy.keepVisibleAtEnd,
      ),
    );
  }

  /// « Chercher sur le web » : un appel par appui, jamais à la frappe.
  void _searchWeb() {
    if (!_requireText('Écrivez ce que vous cherchez sur le web.')) return;
    FocusScope.of(context).unfocus();
    unawaited(ref.read(webSearchProvider.notifier).search(_query));
    // Après le rendu : l'en-tête de la section n'existe qu'une fois l'état
    // passé en chargement.
    WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToWebSection());
  }

  void _scrollToWebSection() {
    if (!mounted) return;
    final target = _webSectionKey.currentContext;
    if (target == null) {
      _scrollToTop();
      return;
    }
    unawaited(
      Scrollable.ensureVisible(
        target,
        duration: const Duration(milliseconds: 250),
        curve: Curves.easeOut,
      ),
    );
  }

  /// « Ouvrir », ou la carte touchée : la page dans le navigateur intégré
  /// sur téléphone, dans le navigateur ailleurs (voir [openWebPage]). Pour
  /// un éditeur, le bandeau d'import l'attend au retour, adresse posée.
  Future<void> _openWebResult(WebRecipeResult result) async {
    try {
      final mode = await openWebPage(result.url);
      if (!mounted) return;
      if (mode == null) {
        context.showErrorSnackBar('Impossible d\'ouvrir ${result.site}.');
        return;
      }
      _armWebReturn(result);
      _revealBannerNowOnIos(mode);
    } catch (e, stackTrace) {
      reportUnexpectedError(
        feature: 'search.web.open',
        error: e,
        stackTrace: stackTrace,
        context: {'host': result.url.host},
      );
      if (mounted) {
        context.showErrorSnackBar('Impossible d\'ouvrir ${result.site}.');
      }
    }
  }

  /// Pour un éditeur, le bandeau d'import attend le retour du navigateur,
  /// avec l'adresse de [result]. Appelé après « Ouvrir », et sur le web
  /// quand le lien du titre a été suivi.
  void _armWebReturn(WebRecipeResult result) {
    if (!mounted || !ref.read(canEditProvider)) return;
    setState(() {
      _awaitingGoogleReturn = true;
      _importBannerVisible = false;
      _bannerLink = null;
      _pendingBannerLink = result.url;
      _openedWebLink = result.url;
    });
  }

  /// « Importer » : la boîte d'import, adresse posée. Rien ne part avant
  /// « Importer » dans la boîte.
  Future<void> _importWebResult(WebRecipeResult result) async {
    final queued = await showUrlImportDialog(
      context,
      initialUrl: result.url.toString(),
    );
    if (queued && mounted) {
      setState(() => _importedWebLinks.add(result.url));
    }
  }

  Future<void> _copyWebLink(WebRecipeResult result) async {
    try {
      await Clipboard.setData(ClipboardData(text: result.url.toString()));
      if (mounted) context.showSuccessSnackBar('Lien copié.');
    } catch (e, stackTrace) {
      reportUnexpectedError(
        feature: 'search.web.copy',
        error: e,
        stackTrace: stackTrace,
      );
      if (mounted) context.showErrorSnackBar('Impossible de copier le lien.');
    }
  }

  /// La première adresse web du presse-papiers, ou `null` : vide, sans
  /// adresse, ou lecture refusée.
  Future<Uri?> _clipboardLink(String trigger) async {
    try {
      final data = await Clipboard.getData(Clipboard.kTextPlain);
      return firstWebLink(data?.text);
    } catch (error, stackTrace) {
      reportUnexpectedError(
        feature: 'searchScreen.importBanner.clipboard',
        error: error,
        stackTrace: stackTrace,
        context: {'trigger': trigger},
      );
      return null;
    }
  }

  Future<void> _readClipboardIntoBanner() async {
    final link = await _clipboardLink('resume');
    if (!mounted || !_importBannerVisible) return;
    setState(() => _bannerLink = link);
  }

  /// « Importer ce lien » ou « Coller le lien » : la boîte d'import s'ouvre,
  /// adresse posée s'il y en a une. Rien ne part avant « Importer ».
  Future<void> _importFromBanner() async {
    final link = _bannerLink ?? await _clipboardLink('paste');
    if (!mounted) return;
    final queued = await showUrlImportDialog(
      context,
      initialUrl: link?.toString(),
    );
    // « Annuler » laisse le bandeau ; un import envoyé le retire.
    if (queued && mounted) {
      setState(() {
        _importBannerVisible = false;
        _bannerLink = null;
      });
    }
  }

  void _closeImportBanner() => setState(() {
    _importBannerVisible = false;
    _bannerLink = null;
  });

  /// Le texte a changé : les sections reprennent leur état par défaut.
  void _onQueryChanged() => setState(() {
    _fieldHelp = null;
    if (_query != _sectionsQuery) {
      _sectionsQuery = _query;
      _sectionOpen.clear();
    }
  });

  /// Ouverte par défaut, sauf « Dans les ingrédients principaux » quand une
  /// section au-dessus a des résultats.
  bool _isSectionOpen(RecipeQuerySection section, RecipeFilterOutcome outcome) {
    final manual = _sectionOpen[section];
    if (manual != null) return manual;
    if (section != RecipeQuerySection.ingredients) return true;
    return !outcome.sections.containsKey(RecipeQuerySection.title) &&
        !outcome.sections.containsKey(RecipeQuerySection.tags);
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
    final webState = ref.read(webSearchProvider);
    final remainingLine = remainingSearchesLine(webState.remaining);
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
              title: const Text('Chercher sur le web'),
              subtitle: Text(
                [
                  'Jusqu\'à 8 pages de recettes, affichées ici.',
                  ?remainingLine,
                ].join(' '),
              ),
              enabled: webState is! WebSearchLoading,
              onTap: () {
                Navigator.pop(ctx);
                _searchWeb();
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
    // Le corpus de « Chercher avec l'IA » : les filtres, sans le texte.
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
    // Inactif seulement pendant une recherche en cours.
    final webState = ref.watch(webSearchProvider);
    final webBusy = webState is WebSearchLoading;
    final VoidCallback? searchWeb = webBusy ? null : _searchWeb;
    // Plus aucune recherche aujourd'hui : le bouton reste actif, une
    // recherche déjà en cache sert encore, mais la phrase le dit.
    final webExhaustedLine = webState.remaining == 0
        ? remainingSearchesLine(0)
        : null;
    final emptyLibrary =
        corpus.recipes.isEmpty && _query.isEmpty && prefs.filter.isEmpty;

    // Le bandeau d'import se pose sous la liste, hors d'elle, sur toutes les
    // tailles d'écran : il ne réduit la zone visible que par le bas, et rien
    // ne bouge au-dessus de lui. Sur téléphone, il tient sur une ligne ;
    // clavier ouvert, il est masqué pour laisser la liste visible.
    // Variantes du bandeau, de la préférée à la plus petite : la première
    // qui laisse sa place à la liste s'affiche (voir [_ListWithBanner]).
    // Grand écran : complète, puis compacte ; téléphone : compacte.
    _ImportBanner bannerVariant({required bool compact}) => _ImportBanner(
      link: _bannerLink,
      compact: compact,
      announce: _bannerAnnounced,
      onImport: () => unawaited(_importFromBanner()),
      onClose: _closeImportBanner,
    );
    final banners = canEdit && _importBannerVisible && !_keyboardOpen
        ? [
            if (isWide) bannerVariant(compact: false),
            bannerVariant(compact: true),
          ]
        : const <Widget>[];

    final list = _ResultList(
      scrollController: _scrollController,
      webCardKey: (url) => _webCardKeys.putIfAbsent(url, GlobalKey.new),
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
      webSectionKey: _webSectionKey,
      onSearchWeb: searchWeb,
      onOpenWebResult: (r) => unawaited(_openWebResult(r)),
      onWebLinkFollowed: _armWebReturn,
      onImportWebResult: (r) => unawaited(_importWebResult(r)),
      onCopyWebLink: (r) => unawaited(_copyWebLink(r)),
      importedWebLinks: _importedWebLinks,
      onSeeOnGoogle: (q) => unawaited(_searchGoogle(query: q)),
      emptyLibrary: emptyLibrary,
      onImport: canEdit ? () => showUrlImportDialog(context) : null,
      isSectionOpen: (section) => _isSectionOpen(section, outcome),
      onToggleSection: (section) => setState(
        () => _sectionOpen[section] = !_isSectionOpen(section, outcome),
      ),
    );

    final field = _SearchField(
      controller: _controller,
      focusNode: _focusNode,
      help: _fieldHelp,
      onChanged: _onQueryChanged,
    );

    final titleOnlyWords = titleOnlyQueryWords(_query);

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
                            'Chercher avec l\'IA · ${recipeCountLabel(aiCorpusSize).toLowerCase()}',
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
                        onPressed: searchWeb,
                        icon: const Icon(Icons.public, size: AppIconSize.small),
                        label: const Text('Chercher sur le web'),
                      ),
                      // En fin de rangée, en bouton texte : un import n'est
                      // pas une recherche.
                      if (canEdit)
                        TextButton.icon(
                          onPressed: () => showUrlImportDialog(context),
                          icon: const Icon(Icons.link, size: AppIconSize.small),
                          label: const Text('Importer depuis un lien'),
                        ),
                    ],
                  ),
                ),
                if (webExhaustedLine != null)
                  _WebExhaustedLine(text: webExhaustedLine),
                _StatusLine(
                  outcome: outcome,
                  titleOnlyWords: titleOnlyWords,
                  hasFilters: !prefs.filter.isEmpty,
                  onClearAll: () => _updatePrefs(
                    prefs.copyWith(filter: prefs.filter.cleared),
                  ),
                ),
                Expanded(
                  child: _ListWithBanner(list: list, banners: banners),
                ),
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
          titleOnlyWords: titleOnlyWords,
          hasFilters: !prefs.filter.isEmpty,
          onClearAll: () =>
              _updatePrefs(prefs.copyWith(filter: prefs.filter.cleared)),
        ),
        Expanded(
          child: _ListWithBanner(list: list, banners: banners),
        ),
        _BottomActions(
          canEdit: canEdit,
          aiCorpusSize: aiCorpusSize,
          onAskAi: askAi,
          onGoFurther: () => _openGoFurther(corpus, canEdit),
          onSearchWeb: searchWeb,
          webExhaustedLine: webExhaustedLine,
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

  /// Mots tapés cherchés dans les titres seuls (petits ingrédients).
  final List<String> titleOnlyWords;
  final bool hasFilters;
  final VoidCallback onClearAll;

  const _StatusLine({
    required this.outcome,
    required this.titleOnlyWords,
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
                if (titleOnlyWords.isNotEmpty)
                  Text(titleOnlyWordsLine(titleOnlyWords), style: muted),
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

/// Barre fixe en bas, au-dessus du clavier : « Chercher avec l'IA » et
/// « Aller plus loin ». Avec un texte agrandi, elle passe sur deux lignes.
class _BottomActions extends StatelessWidget {
  final bool canEdit;
  final int aiCorpusSize;

  /// Nul pendant un classement en cours ou sans recette à classer.
  final VoidCallback? onAskAi;
  final VoidCallback onGoFurther;

  /// Nul pendant une recherche web en cours.
  final VoidCallback? onSearchWeb;

  /// « Il ne vous reste aucune recherche aujourd'hui. », sous le bouton du
  /// lecteur ; nul tant qu'il en reste. L'éditeur la lit dans « Aller plus
  /// loin ».
  final String? webExhaustedLine;

  const _BottomActions({
    required this.canEdit,
    required this.aiCorpusSize,
    required this.onAskAi,
    required this.onGoFurther,
    required this.onSearchWeb,
    this.webExhaustedLine,
  });

  @override
  Widget build(BuildContext context) {
    final stacked = MediaQuery.textScalerOf(context).scale(10) > 15;
    final ask = FilledButton.icon(
      onPressed: onAskAi,
      icon: const Icon(Icons.smart_toy_outlined, size: AppIconSize.small),
      label: Text(
        'Chercher avec l\'IA · ${recipeCountLabel(aiCorpusSize).toLowerCase()}',
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
          // Le lecteur n'a que le web hors de la bibliothèque : le bouton
          // vient directement, sans feuille intermédiaire.
          child: !canEdit
              ? Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    FilledButton.icon(
                      onPressed: onSearchWeb,
                      icon: const Icon(Icons.public, size: AppIconSize.small),
                      label: const Text(
                        'Chercher sur le web',
                        textAlign: TextAlign.center,
                      ),
                    ),
                    if (webExhaustedLine case final line?)
                      _WebExhaustedLine(text: line, centered: true),
                  ],
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

/// « Il ne vous reste aucune recherche aujourd'hui. », sous le bouton.
class _WebExhaustedLine extends StatelessWidget {
  final String text;
  final bool centered;

  const _WebExhaustedLine({required this.text, this.centered = false});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: centered
          ? const EdgeInsets.only(top: 4)
          : const EdgeInsets.fromLTRB(16, 0, 16, 8),
      child: Text(
        text,
        textAlign: centered ? TextAlign.center : TextAlign.start,
        style: theme.textTheme.bodySmall?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }
}

// ── Liste : sections IA puis recettes ────────────────────────────────────────

class _ResultList extends ConsumerWidget {
  final ScrollController scrollController;

  /// La clé de la carte « Sur le web » d'une adresse, pour la ramener en vue.
  final GlobalKey Function(Uri url) webCardKey;
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

  /// Section « Sur le web » : son en-tête, la relance (nulle pendant une
  /// recherche en cours), et les gestes d'une carte.
  final GlobalKey webSectionKey;
  final VoidCallback? onSearchWeb;
  final ValueChanged<WebRecipeResult> onOpenWebResult;

  /// Sur le web, le lien du titre d'une carte a été suivi.
  final ValueChanged<WebRecipeResult> onWebLinkFollowed;
  final ValueChanged<WebRecipeResult> onImportWebResult;
  final ValueChanged<WebRecipeResult> onCopyWebLink;
  final Set<Uri> importedWebLinks;
  final ValueChanged<String> onSeeOnGoogle;

  /// Vrai quand les sources ne rendent aucune recette, sans texte ni filtre.
  final bool emptyLibrary;

  /// « Importer depuis un lien », pour un éditeur ; nul pour un lecteur.
  final VoidCallback? onImport;

  /// Avec du texte : l'état ouvert ou fermé de chaque section, et son
  /// basculement.
  final bool Function(RecipeQuerySection) isSectionOpen;
  final ValueChanged<RecipeQuerySection> onToggleSection;

  const _ResultList({
    required this.scrollController,
    required this.webCardKey,
    required this.outcome,
    required this.prefs,
    required this.corpus,
    required this.query,
    required this.canEdit,
    required this.onClearAll,
    required this.onRelaunch,
    required this.onImagine,
    required this.onOpenIdea,
    required this.webSectionKey,
    required this.onSearchWeb,
    required this.onOpenWebResult,
    required this.onWebLinkFollowed,
    required this.onImportWebResult,
    required this.onCopyWebLink,
    required this.importedWebLinks,
    required this.onSeeOnGoogle,
    required this.emptyLibrary,
    required this.onImport,
    required this.isSectionOpen,
    required this.onToggleSection,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ranking = ref.watch(aiRankingProvider);
    final ideas = ref.watch(aiIdeasProvider);
    final web = ref.watch(webSearchProvider);
    final recipes = outcome.recipes;
    final sectioned = outcome.sections.isNotEmpty;

    final head = <Widget>[
      ..._rankingSection(context, ref, ranking),
      ..._ideasSection(context, ref, ideas),
      ..._webSection(context, ref, web),
      // Avec du texte, les sections nomment déjà ce qui suit.
      if (!sectioned &&
          (ranking is! AiRankingIdle ||
              ideas is! AiIdeasIdle ||
              web is! WebSearchIdle))
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

    // Une ligne par en-tête de section et par tuile. Sans texte, des
    // tuiles seules. Une section fermée ne garde que son en-tête.
    final rows = <({RecipeQuerySection? header, Recipe? recipe})>[];
    if (sectioned) {
      for (final MapEntry(key: section, value: inSection)
          in outcome.sections.entries) {
        rows.add((header: section, recipe: null));
        if (isSectionOpen(section)) {
          rows.addAll(inSection.map((r) => (header: null, recipe: r)));
        }
      }
    } else {
      rows.addAll(recipes.map((r) => (header: null, recipe: r)));
    }

    return ListView.builder(
      key: const PageStorageKey('explore-results'),
      controller: scrollController,
      padding: const EdgeInsets.only(bottom: 8),
      itemCount: head.length + rows.length,
      itemBuilder: (context, i) {
        if (i < head.length) return head[i];
        final row = rows[i - head.length];
        if (row.header case final section?) {
          return QuerySectionHeader(
            title: section.label,
            count: outcome.sections[section]!.length,
            open: isSectionOpen(section),
            onToggle: () => onToggleSection(section),
          );
        }
        final recipe = row.recipe!;
        return SearchResultTile(
          result: RecipeSearchResult(recipe: recipe),
          matchedIngredients: outcome.matchedIngredients[recipe.id] ?? const [],
        );
      },
    );
  }

  /// La section « Sur le web » : en-tête, état, cartes, bloc de Google, pied.
  List<Widget> _webSection(
    BuildContext context,
    WidgetRef ref,
    WebSearchState state,
  ) {
    final asked = webSearchQueryOf(state);
    if (asked == null) return const [];
    final notifier = ref.read(webSearchProvider.notifier);
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );

    final subtitle = switch (state) {
      WebSearchSuccess(:final response) when response.fromCache =>
        '« $asked » · Recherche déjà faite, non décomptée.',
      WebSearchSuccess(:final remaining) => [
        '« $asked »',
        ?remainingSearchesLine(remaining),
      ].join(' · '),
      _ => '« $asked »',
    };
    final stale = query.trim() != asked && state is! WebSearchLoading;

    Widget seeOnGoogle() => TextButton.icon(
      onPressed: () => onSeeOnGoogle(asked),
      icon: const Icon(Icons.open_in_new, size: AppIconSize.small),
      label: const Text('Voir sur Google'),
    );

    // Rien, marges comprises, quand Google n'a pas rendu son bloc.
    List<Widget> suggestions(WebSearchResponse response) => [
      if (response.searchEntryPointHtml case final html?)
        GoogleSearchSuggestions(html: html, queries: response.webSearchQueries),
    ];

    Widget footer() => Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 8, 4),
      child: Wrap(
        crossAxisAlignment: WrapCrossAlignment.center,
        spacing: 8,
        children: [
          Text('Vidéos et réseaux sociaux exclus.', style: muted),
          seeOnGoogle(),
        ],
      ),
    );

    return [
      KeyedSubtree(
        key: webSectionKey,
        child: _SectionHeader(
          icon: Icons.public,
          title: 'Sur le web',
          subtitle: subtitle,
          trailing: _closeButton(notifier.close),
        ),
      ),
      if (stale)
        _Notice(
          text: 'Recherche modifiée depuis la demande.',
          actionLabel: 'Relancer',
          onAction: onSearchWeb,
        ),
      ...switch (state) {
        WebSearchLoading() => [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
            child: Row(
              children: [
                const SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Semantics(
                    liveRegion: true,
                    child: const Text('Recherche de pages de recettes…'),
                  ),
                ),
              ],
            ),
          ),
          const WebResultPlaceholderTile(),
          const WebResultPlaceholderTile(),
          const WebResultPlaceholderTile(),
        ],
        WebSearchSuccess(:final response) when response.results.isEmpty => [
          const _WebEmptyNotice(),
          ...suggestions(response),
          footer(),
        ],
        WebSearchSuccess(:final response) => [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
            child: Semantics(
              liveRegion: true,
              child: Text(
                webPagesFoundLabel(response.results.length),
                style: muted,
              ),
            ),
          ),
          for (final r in response.results)
            WebResultTile(
              key: webCardKey(r.url),
              result: r,
              canImport: canEdit,
              imported: importedWebLinks.contains(r.url),
              onOpen: () => onOpenWebResult(r),
              onLinkFollowed: () => onWebLinkFollowed(r),
              onImport: canEdit ? () => onImportWebResult(r) : null,
              onCopyLink: () => onCopyWebLink(r),
            ),
          ...suggestions(response),
          footer(),
        ],
        WebSearchError(:final error) => [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: switch (error) {
              // Le serveur a écrit le message ; la même requête serait
              // refusée de nouveau.
              WebSearchQueryRefused(:final message) => AppErrorState(
                error: error,
                compact: true,
                title: 'Recherche refusée',
                advice: message,
              ),
              WebSearchEngineUnavailable(:final message) => AppErrorState(
                error: error,
                compact: true,
                title: 'Moteur de recherche indisponible',
                advice: message,
                onRetry: () => unawaited(notifier.search(asked)),
              ),
              // Hors ligne : « Connexion perdue », par `describeError`.
              _ => AppErrorState(
                error: error,
                compact: true,
                onRetry: () => unawaited(notifier.search(asked)),
              ),
            },
          ),
          footer(),
        ],
        WebSearchQuotaReached(:final limit) => [
          _WebLimitCard(
            text: limit == null
                ? 'Vous avez fait toutes vos recherches web d\'aujourd\'hui. '
                      'Le compteur repart demain.'
                : 'Vous avez fait vos $limit recherches web d\'aujourd\'hui. '
                      'Le compteur repart demain.',
            onSeeOnGoogle: () => onSeeOnGoogle(asked),
          ),
        ],
        WebSearchBudgetReached() => [
          _WebLimitCard(
            text:
                'Le budget d\'IA du jour est atteint. La recherche web revient '
                'demain.',
            onSeeOnGoogle: () => onSeeOnGoogle(asked),
          ),
        ],
        WebSearchIdle() => const <Widget>[],
      },
    ];
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

/// Plafond du jour atteint — recherches du compte ou budget d'IA : ce n'est
/// pas une panne, rien à réessayer avant demain.
class _WebLimitCard extends StatelessWidget {
  final String text;
  final VoidCallback onSeeOnGoogle;

  const _WebLimitCard({required this.text, required this.onSeeOnGoogle});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final fg = theme.colorScheme.onSecondaryContainer;
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      color: theme.colorScheme.secondaryContainer,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 8, 4),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(
                  Icons.hourglass_bottom,
                  size: AppIconSize.small,
                  color: fg,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Semantics(
                    liveRegion: true,
                    child: Text(
                      text,
                      style: theme.textTheme.bodyMedium?.copyWith(color: fg),
                    ),
                  ),
                ),
              ],
            ),
            Align(
              alignment: Alignment.centerRight,
              child: TextButton.icon(
                onPressed: onSeeOnGoogle,
                icon: const Icon(Icons.open_in_new, size: AppIconSize.small),
                label: const Text('Voir sur Google'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Aucune page retenue : un état resserré dans la liste, sans grande icône.
/// « Voir sur Google » est dans le pied de la section, juste dessous.
class _WebEmptyNotice extends StatelessWidget {
  const _WebEmptyNotice();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
      child: Semantics(
        liveRegion: true,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Aucune page de recette trouvée',
              style: theme.textTheme.titleSmall?.copyWith(
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              'Essayez d\'autres mots, ou voyez tous les résultats sur Google.',
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
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

/// Hauteur que la liste garde au moins quand le bandeau d'import s'affiche.
const double importBannerMinListHeight = 120;

/// La liste, et sous elle le bandeau d'import s'il y en a un.
///
/// [banners] : les variantes du bandeau, de la préférée à la plus petite.
/// S'affiche la première dont la hauteur réelle — mesurée par
/// [_FirstThatFits], quelle que soit la taille du texte — laisse au moins
/// [importBannerMinListHeight] à la liste ; aucune si aucune ne tient. Le
/// bandeau n'écrase jamais la liste.
///
/// Une variante non affichée ne reçoit ni focus ni activation
/// (`ExcludeFocus`) : Tab ne s'arrête pas sur un bouton invisible. La liste
/// reste le premier enfant d'un même arbre : son état, défilement compris,
/// survit à l'apparition du bandeau.
class _ListWithBanner extends StatefulWidget {
  final Widget list;
  final List<Widget> banners;

  const _ListWithBanner({required this.list, required this.banners});

  @override
  State<_ListWithBanner> createState() => _ListWithBannerState();
}

class _ListWithBannerState extends State<_ListWithBanner> {
  /// Variante affichée au dernier rendu ; `null` : aucune.
  int? _shown;

  void _onShown(int? index) {
    if (mounted && index != _shown) setState(() => _shown = index);
  }

  @override
  Widget build(BuildContext context) {
    final banners = widget.banners;
    // Sans bandeau, le choix suivant repart de zéro (nouveau rendu).
    if (banners.isEmpty) _shown = null;
    return LayoutBuilder(
      builder: (context, constraints) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(child: widget.list),
          if (banners.isNotEmpty)
            _FirstThatFits(
              maxHeight: constraints.maxHeight - importBannerMinListHeight,
              onShown: _onShown,
              children: [
                for (var i = 0; i < banners.length; i++)
                  ExcludeFocus(excluding: _shown != i, child: banners[i]),
              ],
            ),
        ],
      ),
    );
  }
}

/// Affiche le premier de ses enfants dont la hauteur tient dans
/// [maxHeight], et aucun autre : ceux qui ne sont pas retenus ne prennent
/// ni place, ni peinture, ni toucher, ni sémantique. Le choix est rendu à
/// [onShown] après le rendu, pour le focus.
class _FirstThatFits extends MultiChildRenderObjectWidget {
  final double maxHeight;
  final ValueChanged<int?> onShown;

  const _FirstThatFits({
    required this.maxHeight,
    required this.onShown,
    required super.children,
  });

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderFirstThatFits(maxHeight, onShown);

  @override
  void updateRenderObject(
    BuildContext context,
    _RenderFirstThatFits renderObject,
  ) {
    renderObject
      ..maxHeight = maxHeight
      ..onShown = onShown;
  }
}

class _FirstThatFitsParentData extends ContainerBoxParentData<RenderBox> {}

class _RenderFirstThatFits extends RenderBox
    with
        ContainerRenderObjectMixin<RenderBox, _FirstThatFitsParentData>,
        RenderBoxContainerDefaultsMixin<RenderBox, _FirstThatFitsParentData> {
  _RenderFirstThatFits(this._maxHeight, this.onShown);

  double _maxHeight;
  ValueChanged<int?> onShown;
  RenderBox? _chosen;
  int? _reported;

  set maxHeight(double value) {
    if (value == _maxHeight) return;
    _maxHeight = value;
    markNeedsLayout();
  }

  @override
  void setupParentData(RenderBox child) {
    if (child.parentData is! _FirstThatFitsParentData) {
      child.parentData = _FirstThatFitsParentData();
    }
  }

  @override
  Size computeDryLayout(BoxConstraints constraints) {
    var child = firstChild;
    while (child != null) {
      final size = child.getDryLayout(constraints);
      if (size.height <= _maxHeight) return size;
      child = childAfter(child);
    }
    return constraints.constrain(Size(constraints.maxWidth, 0));
  }

  @override
  void performLayout() {
    RenderBox? chosen;
    int? index;
    var i = 0;
    var child = firstChild;
    while (child != null) {
      child.layout(constraints, parentUsesSize: true);
      (child.parentData! as _FirstThatFitsParentData).offset = Offset.zero;
      if (chosen == null && child.size.height <= _maxHeight) {
        chosen = child;
        index = i;
      }
      i++;
      child = childAfter(child);
    }
    if (chosen != _chosen) markNeedsSemanticsUpdate();
    _chosen = chosen;
    size = chosen?.size ?? constraints.constrain(Size(constraints.maxWidth, 0));
    if (index != _reported) {
      _reported = index;
      final report = onShown;
      SchedulerBinding.instance.addPostFrameCallback((_) => report(index));
    }
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    final chosen = _chosen;
    if (chosen != null) context.paintChild(chosen, offset);
  }

  @override
  bool hitTestChildren(BoxHitTestResult result, {required Offset position}) {
    final chosen = _chosen;
    if (chosen == null) return false;
    return result.addWithPaintOffset(
      offset: Offset.zero,
      position: position,
      hitTest: (result, transformed) =>
          chosen.hitTest(result, position: transformed),
    );
  }

  @override
  void visitChildrenForSemantics(RenderObjectVisitor visitor) {
    final chosen = _chosen;
    if (chosen != null) visitor(chosen);
  }
}

/// Phrase du bandeau d'import, grand écran.
const importBannerSentence = 'Vous avez trouvé une recette ? Importez-la.';

/// Phrase du bandeau d'import, sur une ligne, téléphone.
const importBannerShortSentence = 'Une recette trouvée ?';

/// « Vous avez trouvé une recette ? Importez-la. » : au retour de Google,
/// pour un éditeur ou un administrateur.
///
/// [compact] (téléphone) : une seule ligne — phrase courte tronquée, bouton,
/// croix — pour ne jamais prendre la hauteur de la liste.
class _ImportBanner extends StatelessWidget {
  /// Adresse de la carte ouverte, ou lue dans le presse-papiers ; nulle sur
  /// le web et iOS après « Voir sur Google », ou quand le presse-papiers
  /// n'en contient pas.
  final Uri? link;
  final bool compact;

  /// Vrai : la phrase s'annonce à l'apparition (`liveRegion`).
  final bool announce;
  final VoidCallback onImport;
  final VoidCallback onClose;

  const _ImportBanner({
    required this.link,
    required this.compact,
    required this.announce,
    required this.onImport,
    required this.onClose,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final fg = theme.colorScheme.onSecondaryContainer;
    final link = this.link;
    final buttonLabel = link != null ? 'Importer ce lien' : 'Coller le lien';
    final buttonIcon = link != null ? Icons.link : Icons.content_paste;
    final close = IconButton(
      tooltip: 'Fermer',
      icon: Icon(Icons.close, color: fg),
      onPressed: onClose,
    );

    // Seule la phrase s'annonce à l'apparition du bandeau, pas chaque bouton
    // de la carte ; et pas quand il est posé sous une page qui couvre
    // l'écran (iOS).
    Widget sentence(String text, {int? maxLines}) => Semantics(
      liveRegion: announce,
      child: Text(
        text,
        maxLines: maxLines,
        overflow: maxLines == null ? null : TextOverflow.ellipsis,
        style: theme.textTheme.titleSmall?.copyWith(color: fg),
      ),
    );

    if (compact) {
      return Card(
        margin: const EdgeInsets.fromLTRB(12, 4, 12, 4),
        color: theme.colorScheme.secondaryContainer,
        child: Padding(
          padding: const EdgeInsets.only(left: 12),
          child: Row(
            children: [
              Expanded(
                flex: 3,
                child: sentence(importBannerShortSentence, maxLines: 1),
              ),
              const SizedBox(width: 8),
              Flexible(
                flex: 4,
                child: Tooltip(
                  message: link == null ? buttonLabel : shortLinkLabel(link),
                  child: FilledButton.icon(
                    onPressed: onImport,
                    icon: Icon(buttonIcon, size: AppIconSize.small),
                    label: Text(
                      buttonLabel,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ),
              ),
              close,
            ],
          ),
        ),
      );
    }

    return Card(
      margin: const EdgeInsets.fromLTRB(16, 8, 16, 8),
      color: theme.colorScheme.secondaryContainer,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 4, 4, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      sentence(importBannerSentence),
                      if (link != null)
                        Text(
                          shortLinkLabel(link),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodySmall?.copyWith(color: fg),
                        ),
                    ],
                  ),
                ),
                close,
              ],
            ),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                FilledButton.icon(
                  onPressed: onImport,
                  icon: Icon(buttonIcon, size: AppIconSize.small),
                  label: Text(buttonLabel),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
