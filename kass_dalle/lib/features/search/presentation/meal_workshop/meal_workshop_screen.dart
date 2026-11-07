import 'dart:async';

import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../../core/presentation/leave_guard.dart';
import '../../../../core/router/app_router.dart' show planningLocation;
import '../../../../core/presentation/stylus_pad_text_field.dart';
import '../../../../core/services/error_reporting.dart';
import '../../../../core/theme/app_icons.dart';
import '../../../../core/utils/context_extensions.dart';
import '../../../../core/utils/platform_utils.dart';
import '../../../../core/widgets/app_states.dart';
import '../../../admin/presentation/admin_providers.dart'
    show errorReportServiceProvider;
import '../../../planning/domain/meal_component.dart' show MealComponentRole;
import '../../../planning/domain/meal_composition.dart' show kMaxCoursesPerMenu;
import '../../../planning/domain/meal_kind.dart';
import '../../../recipes/domain/recipe.dart' show Recipe;
import '../../../recipes/presentation/detail/portions_input_dialog.dart';
import '../../data/meal_workshop_functions.dart';
import '../../domain/meal_workshop_freeze.dart';
import '../../domain/meal_workshop_menu.dart';
import '../../domain/meal_workshop_pose.dart';
import 'meal_workshop_pose_sheet.dart';
import 'meal_workshop_providers.dart';
import 'meal_workshop_widgets.dart';

/// « Composer un repas avec l'IA » : l'atelier repas, depuis Explorer.
///
/// Une conversation bornée (20 tours, 1 500 caractères par message, 30 tours
/// par jour) pour composer un plat et ses accompagnements (« Plat », le mode
/// par défaut) ou un repas complet (« Menu »), et un menu structuré que le
/// serveur contrôle et que l'écran redessine à chaque tour. Le mode est fixé
/// pour la durée d'une conversation : le changer en cours de route en ouvre
/// une nouvelle, après confirmation.
///
/// Rien n'est enregistré avant « Figer le repas » : la conversation, le menu
/// et le périmètre vivent en mémoire et disparaissent avec l'écran. Le
/// figement rédige chaque plat sans recette liée (un appel par plat) et crée
/// un brouillon dans le livre choisi ; une recette existante liée n'est ni
/// copiée ni modifiée. Le périmètre est celui des filtres d'Explorer à
/// l'ouverture, sans le texte, figé pour la conversation.
///
/// « Poser dans le planning » (palier 2) : après un figement, le repas
/// devient un repas planifié avec ses services, pour les parts du menu, dans
/// « Mon planning » ou le planning d'un groupe possédé — par le dépôt du
/// planning, sans appel d'IA. Chaque pose crée un repas de plus qui pointe
/// les mêmes brouillons.
class MealWorkshopScreen extends ConsumerStatefulWidget {
  /// Le texte du champ d'Explorer, posé dans le champ de l'atelier, non
  /// envoyé.
  final String initialMessage;

  const MealWorkshopScreen({super.key, this.initialMessage = ''});

  @override
  ConsumerState<MealWorkshopScreen> createState() => _MealWorkshopScreenState();
}

sealed class _Entry {
  const _Entry();
}

class _UserEntry extends _Entry {
  final String text;
  const _UserEntry(this.text);
}

class _AssistantEntry extends _Entry {
  final WorkshopTurnResult result;
  final int changedCount;
  final bool unchanged;
  const _AssistantEntry(this.result, this.changedCount, this.unchanged);
}

class _ErrorEntry extends _Entry {
  final WorkshopFailure failure;
  const _ErrorEntry(this.failure);
}

/// Ce que la boîte « Figer le repas » rend : le livre, et une décision par
/// doublon de titre (clé : index du service).
class _FreezeChoice {
  final MealWorkshopBook book;
  final Map<int, DuplicateDecision> decisions;
  const _FreezeChoice({required this.book, required this.decisions});
}

/// Pourquoi le figement n'appelle plus l'IA pour les services restants.
enum _FreezeStop { budget, permission }

/// Le bouton du pied du panneau : « Figer le repas » ou « Poser dans le
/// planning ».
enum _FooterButton { freeze, pose }

class _MealWorkshopScreenState extends ConsumerState<MealWorkshopScreen>
    with WidgetsBindingObserver {
  late final TextEditingController _input = TextEditingController(
    text: widget.initialMessage,
  );
  final FocusNode _inputFocus = FocusNode();
  final ScrollController _scroll = ScrollController();

  /// Le contexte figé à la première lecture : un changement de filtres
  /// pendant la conversation n'a pas d'effet.
  MealWorkshopContext? _workshop;

  final List<_Entry> _entries = [];

  /// Les tours envoyés au serveur : `{role, text}`, dans l'ordre.
  final List<Map<String, String>> _history = [];

  WorkshopMenu? _menu;
  Set<int> _changed = const {};
  bool _lastTruncated = false;
  int _lastOffKind = 0;
  int _portions = kWorkshopDefaultPortions;

  /// Plat ou menu. Non persisté ; « Plat » à l'ouverture.
  MealKind _kind = MealKind.plat;
  bool _sending = false;
  String _conversationId = newWorkshopConversationId();

  /// Le compteur du jour ; `null` tant qu'il est inconnu.
  WorkshopQuota? _quota;
  int _inputLength = 0;

  /// Clavier ouvert, lu sur la vue elle-même : le `Scaffold` du shell, qui
  /// porte l'écran dans son corps, retire `viewInsets` du `MediaQuery`
  /// (même procédé que `search_screen.dart`).
  bool _keyboardOpen = false;

  // ── Figement ──────────────────────────────────────────────────────────────

  /// Une ligne par service dès qu'un figement a commencé ; `null` avant.
  List<FreezeLineState>? _freezeLines;

  /// Vrai pendant les appels du figement.
  bool _freezing = false;

  /// Vrai dès qu'un figement s'est déroulé : le champ est fermé.
  bool _frozen = false;
  ({String id, String titre})? _book;

  /// Le livre choisi dans la boîte ; [_book] est trouvé ou créé à la
  /// première recette à enregistrer, jamais pour un figement sans plat à
  /// rédiger.
  MealWorkshopBook? _bookChoice;

  /// La feuille du téléphone est ouverte.
  bool _sheetOpen = false;

  /// Un jeton par ouverture de feuille. « Figer » depuis la feuille la ferme
  /// et en rouvre une verrouillée : la fermeture de la première ne doit ni
  /// remettre [_sheetOpen] à faux ni montrer [_pendingReport] pendant que la
  /// seconde est ouverte.
  int _sheetToken = 0;

  /// Le compte rendu d'un figement fini pendant que la feuille était
  /// ouverte : montré à sa fermeture, sinon il passerait sous elle.
  ({bool success, String message})? _pendingReport;

  // ── Poser dans le planning ────────────────────────────────────────────────

  /// Les poses faites depuis ce figement, dans l'ordre : chacune a créé un
  /// repas planifié qui pointe les mêmes brouillons.
  final List<WorkshopPoseResult> _poses = [];

  /// Vrai entre l'appui sur « Poser » et la fermeture de la boîte (relecture
  /// des recettes liées comprise) : pas de double pose.
  bool _posing = false;

  /// Le repas a été posé au moins une fois : le panneau est figé pour de
  /// bon, l'écran se quitte librement.
  bool get _posed => _poses.isNotEmpty;

  /// Incrémenté quand l'état du panneau change : la feuille du téléphone,
  /// route modale au-dessus de l'écran, se redessine en l'écoutant.
  final ValueNotifier<int> _revision = ValueNotifier<int>(0);

  late final LeaveGuardNotifier _leaveGuardNotifier;
  LeaveGuard? _previousGuard;

  int get _userTurns => _history.where((t) => t['role'] == 'user').length;
  String get _portionsLabel => workshopPortionsLabel(_portions);
  bool get _isDish => _kind == MealKind.plat;

  /// « plat » ou « menu », pour les libellés qui nomment ce qu'on compose.
  String get _thing => _isDish ? 'plat' : 'menu';
  bool get _turnsExhausted => _userTurns >= kWorkshopMaxTurns;
  bool get _dayExhausted => _quota?.exhausted ?? false;
  bool get _hasConversation => _history.isNotEmpty;
  bool get _inputTooLong => _inputLength > kWorkshopMaxMessageChars;
  bool get _canSend =>
      !_sending &&
      !_freezing &&
      !_frozen &&
      _workshop != null &&
      !_turnsExhausted &&
      !_dayExhausted &&
      _input.text.trim().isNotEmpty &&
      !_inputTooLong;

  /// « Figer le repas » : dès qu'un service porte un titre sans recette
  /// liée, hors tour et hors figement.
  bool get _canFreeze =>
      !_sending &&
      !_freezing &&
      !_frozen &&
      _workshop != null &&
      (_menu?.canFreeze ?? false);

  /// Plats à rédiger sans brouillon, après ou pendant un figement.
  int get _notWritten {
    final menu = _menu;
    final lines = _freezeLines;
    if (menu == null || lines == null) return 0;
    return freezeNotWrittenCount(menu, lines);
  }

  @override
  void initState() {
    super.initState();
    _inputLength = _input.text.length;
    _input.addListener(_onInputChanged);
    _leaveGuardNotifier = ref.read(leaveGuardProvider.notifier);
    _previousGuard = ref.read(leaveGuardProvider);
    WidgetsBinding.instance.addObserver(this);
    // Après le rendu : un provider ne se modifie pas pendant la construction.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _leaveGuardNotifier.set(_leaveGuard);
    });
  }

  bool _viewKeyboardOpen() => View.of(context).viewInsets.bottom > 0;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _keyboardOpen = _viewKeyboardOpen();
  }

  /// Le clavier s'ouvre ou se ferme : sur téléphone, l'accueil de la
  /// conversation vide se masque ou revient.
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
    final previous = _previousGuard;
    Future.microtask(() => notifier.restoreIf(guard, previous));
    WidgetsBinding.instance.removeObserver(this);
    _input
      ..removeListener(_onInputChanged)
      ..dispose();
    _inputFocus.dispose();
    _scroll.dispose();
    _revision.dispose();
    super.dispose();
  }

  void _onInputChanged() {
    final length = _input.text.length;
    if (length != _inputLength) setState(() => _inputLength = length);
  }

  // ── Garde de sortie ───────────────────────────────────────────────────────

  /// Vrai quand l'écran peut être quitté librement : sans tour, après un
  /// figement dont tous les plats ont un brouillon, ou après une pose dans
  /// le planning (ce qui compte est enregistré).
  bool get _canLeaveFreely {
    if (_freezing) return false;
    if (_posed) return true;
    if (_freezeLines != null) return _notWritten == 0;
    return !_hasConversation;
  }

  /// Vrai quand l'écran peut être quitté : librement, ou après confirmation.
  Future<bool> _leaveGuard() async {
    if (_canLeaveFreely) return true;
    final String title;
    final String content;
    if (_freezing) {
      title = 'Figement en cours. Quitter ?';
      content =
          'Les brouillons déjà créés restent. Le plat en cours de rédaction '
          'et les suivants ne seront pas enregistrés.';
    } else if (_freezeLines != null) {
      title = leaveAfterPartialFreezeTitle(_notWritten);
      content =
          'Les brouillons créés restent. ${_isDish ? 'Le plat' : 'Le menu'} '
          'et la conversation seront perdus.';
    } else {
      title = 'Quitter sans enregistrer ?';
      content = _isDish
          ? 'Le plat et la conversation seront perdus.'
          : 'Le menu et la conversation seront perdus.';
    }
    final leave = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: Text(content),
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
    if (!await _leaveGuard()) return;
    if (!mounted) return;
    // La question a été posée ici : le retour ne la repose pas.
    _leaveGuardNotifier.clearIf(_leaveGuard);
    Navigator.of(context).pop();
  }

  // ── Un tour ───────────────────────────────────────────────────────────────

  Future<void> _send() async {
    final text = _input.text.trim();
    final workshop = _workshop;
    if (!_canSend || workshop == null) return;

    setState(() {
      _sending = true;
      _entries.removeWhere((e) => e is _ErrorEntry);
    });
    _revision.value++;
    _scrollToEnd();

    final turn = _userTurns + 1;
    try {
      final result = await ref
          .read(mealWorkshopFunctionsProvider)
          .turn(
            conversationId: _conversationId,
            kind: _kind,
            history: [for (final t in _history) Map<String, String>.from(t)],
            message: text,
            recipes: workshop.summaries,
            staples: workshop.staplePayload,
            globalConstraints: workshop.globalConstraints,
            portions: _portions,
            menu: _menu,
          );
      if (!mounted) return;
      final changed = changedCourseIndexes(_menu, result.menu);
      final unchanged = sameMenu(_menu, result.menu);
      setState(() {
        _history
          ..add({'role': 'user', 'text': text})
          ..add({'role': 'assistant', 'text': result.reponse});
        _entries
          ..add(_UserEntry(text))
          ..add(_AssistantEntry(result, changed.length, unchanged));
        _menu = result.menu;
        _changed = changed;
        _lastTruncated = result.control.truncated;
        _lastOffKind = result.control.offKindCourses;
        if (result.quota != null) _quota = result.quota;
        _input.clear();
        _sending = false;
      });
      _revision.value++;
      _scrollToEnd();
      _focusInputIfWide();
    } catch (error, stackTrace) {
      final failure = describeWorkshopFailure(error);
      // Un refus attendu (réponse illisible, plafond) reste un événement à
      // tracer : seules les tailles partent, jamais le texte.
      reportUnexpectedError(
        feature: 'mealWorkshop.turn',
        error: error,
        stackTrace: stackTrace,
        context: {
          'kind': failure.kind.name,
          'turn': turn,
          'message_length': text.length,
          'corpus_size': workshop.summaries.length,
        },
        service: ref.read(errorReportServiceProvider),
      );
      if (!mounted) return;
      setState(() {
        _sending = false;
        switch (failure.kind) {
          case WorkshopFailureKind.dailyQuota:
            // Pas de carte : l'aide sous le champ dit le plafond. Le texte
            // reste dans le champ, fermé.
            _quota = WorkshopQuota(
              limit: failure.limit ?? _quota?.limit ?? kWorkshopDailyLimit,
              remaining: 0,
            );
          case WorkshopFailureKind.unreadable:
            // Facturé et compté sans réponse lisible : le compteur le dit.
            if (failure.quota != null) _quota = failure.quota;
            _entries.add(_ErrorEntry(failure));
          case WorkshopFailureKind.aiBudget:
          case WorkshopFailureKind.permissionDenied:
          case WorkshopFailureKind.refused:
          case WorkshopFailureKind.other:
            _entries.add(_ErrorEntry(failure));
        }
      });
      _revision.value++;
      _scrollToEnd();
      _focusInputIfWide();
    }
  }

  /// Rend le focus au champ sur grand écran, après le rendu : un champ
  /// inactif le temps d'un tour le perd, et `autofocus` ne joue qu'au
  /// premier rendu. Sur téléphone, rien : le clavier recouvrirait la
  /// réponse.
  void _focusInputIfWide() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final wide =
          MediaQuery.sizeOf(context).width >= PlatformUtils.wideBreakpoint;
      if (wide) _inputFocus.requestFocus();
    });
  }

  void _scrollToEnd() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scroll.hasClients) return;
      _scroll.animateTo(
        _scroll.position.maxScrollExtent,
        duration: const Duration(milliseconds: 250),
        curve: Curves.easeOut,
      );
    });
  }

  Future<void> _changePortions() async {
    final value = await showPortionsInputDialog(
      context,
      current: _portions,
      minPortions: 1,
      maxPortions: 99,
      title: 'Nombre de parts',
      unit: 'parts',
    );
    if (value == null || !mounted) return;
    setState(() => _portions = value);
    _revision.value++;
  }

  /// Même périmètre, menu vide, parts conservées, nouvel identifiant de
  /// conversation. Le texte du champ reste : un message tapé avant de
  /// repartir n'est pas perdu. [kind] change le mode.
  void _newConversation({MealKind? kind}) {
    setState(() {
      _entries.clear();
      _history.clear();
      _menu = null;
      _changed = const {};
      _lastTruncated = false;
      _lastOffKind = 0;
      _freezeLines = null;
      _frozen = false;
      _book = null;
      _bookChoice = null;
      _poses.clear();
      _conversationId = newWorkshopConversationId();
      if (kind != null) _kind = kind;
    });
    _revision.value++;
    _inputFocus.requestFocus();
  }

  /// La confirmation avant de perdre la conversation en cours, selon son
  /// état : aucune à 20 tours (le champ est fermé, rien ne peut plus se
  /// perdre par un envoi) ni après un figement complet ; après un figement
  /// partiel, les plats non rédigés sont nommés ; sinon, la question
  /// ordinaire. Vrai quand on peut repartir.
  Future<bool> _confirmNewConversation({
    required String title,
    required String action,
  }) async {
    // Après une pose, rien ne se perd plus : le repas est dans le planning.
    if (_posed) return true;
    if (_freezeLines != null) {
      final notWritten = _notWritten;
      if (notWritten == 0) return true;
      return _confirmDiscard(
        title: newConversationAfterPartialFreezeTitle(notWritten),
        content:
            'Les brouillons créés restent. Les plats non rédigés et la '
            'conversation seront perdus.',
        action: action,
      );
    }
    if (_turnsExhausted) return true;
    return _confirmDiscard(
      title: title,
      content:
          'La conversation et le $_thing en cours seront perdus. Rien '
          'n\'était enregistré.',
      action: action,
    );
  }

  Future<void> _newConversationRequested() async {
    final confirmed = await _confirmNewConversation(
      title: 'Nouvelle conversation ?',
      action: 'Nouvelle conversation',
    );
    if (!confirmed || !mounted) return;
    _newConversation();
  }

  /// Le choix Plat | Menu. Sans conversation : bascule libre, la carte d'un
  /// tour échoué disparaît. Avec une conversation : confirmation, puis
  /// nouvelle conversation dans le nouveau mode.
  Future<void> _selectKind(MealKind kind) async {
    if (kind == _kind || _sending || _freezing) return;
    if (!_hasConversation) {
      setState(() {
        _kind = kind;
        _entries.removeWhere((e) => e is _ErrorEntry);
      });
      _revision.value++;
      return;
    }
    final toMenu = kind == MealKind.menu;
    final confirmed = await _confirmNewConversation(
      title: toMenu ? 'Passer en menu ?' : 'Passer en plat ?',
      action: toMenu ? 'Passer en menu' : 'Passer en plat',
    );
    if (!confirmed || !mounted) return;
    _newConversation(kind: kind);
  }

  /// La boîte qui précède la perte d'une conversation : forme de
  /// `planning_screen.dart` (« Repasser en plat ? »).
  Future<bool> _confirmDiscard({
    required String title,
    required String content,
    required String action,
  }) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: Text(content),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Annuler'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(action),
          ),
        ],
      ),
    );
    return confirmed == true;
  }

  // ── Figer le repas ────────────────────────────────────────────────────────

  /// « Figer le repas » : la boîte qui annonce les appels, demande le livre
  /// et tranche les doublons de titre, puis le figement. Depuis la feuille du
  /// téléphone ([fromSheet]), la feuille se rouvre verrouillée le temps des
  /// appels.
  Future<void> _requestFreeze({required bool fromSheet}) async {
    final menu = _menu;
    final workshop = _workshop;
    if (!_canFreeze || menu == null || workshop == null) return;
    final duplicates = workshopTitleDuplicates(
      menu,
      workshop.recipesById.values,
    );
    final choice = await showDialog<_FreezeChoice>(
      context: context,
      builder: (_) => _FreezeDialog(
        menu: menu,
        portions: _portions,
        duplicates: duplicates,
      ),
    );
    if (choice == null || !mounted) return;
    if (fromSheet) {
      Navigator.of(context).pop();
      unawaited(_openSheet(locked: true));
    }
    await _startFreeze(choice, duplicates);
  }

  /// [report] faux : le figement implicite de « Poser dans le planning »
  /// (rien à rédiger), qui n'annonce rien — la boîte suit, ou la ligne
  /// « Recette plus accessible » dit ce qui bloque.
  Future<void> _startFreeze(
    _FreezeChoice choice,
    List<WorkshopTitleDuplicate> duplicates, {
    bool report = true,
  }) async {
    final workshop = _workshop;
    var menu = _menu;
    if (workshop == null || menu == null) return;
    // « Lier la recette existante » : le service devient une recette liée,
    // sous le titre de la recette, avant tout appel.
    for (final d in duplicates) {
      if (choice.decisions[d.courseIndex] == DuplicateDecision.link) {
        menu = menu!.withCourse(
          d.courseIndex,
          menu.courses[d.courseIndex].linkedTo(
            recipeId: d.recipe.id,
            title: d.recipe.titre,
          ),
        );
      }
    }
    setState(() {
      _menu = menu;
      _freezeLines = [for (final _ in menu!.courses) const FreezeWaiting()];
      _freezing = true;
      _entries.removeWhere((e) => e is _ErrorEntry);
    });
    _revision.value++;

    _bookChoice = choice.book;
    _book = null;
    // Sans plat à rédiger (tous les doublons liés) : ni appel d'IA, ni livre
    // créé ; les recettes liées sont seulement relues.
    if (menu!.toWriteCount > 0) {
      try {
        await _ensureBook();
      } catch (error, stackTrace) {
        reportUnexpectedError(
          feature: 'mealWorkshop.freeze.book',
          error: error,
          stackTrace: stackTrace,
          context: {'book': choice.book.name},
          service: ref.read(errorReportServiceProvider),
        );
        if (!mounted) return;
        // Aucun appel n'a eu lieu : le figement n'a pas commencé.
        setState(() {
          _freezeLines = null;
          _freezing = false;
        });
        _revision.value++;
        context.showFailureSnackBar('Repas non figé', error);
        return;
      }
      if (!mounted) return;
    }

    _FreezeStop? stop;
    for (var i = 0; i < menu.courses.length; i++) {
      if (!mounted) return;
      final course = _menu!.courses[i];
      if (stop != null && !course.isLinked) {
        _setLine(
          i,
          stop == _FreezeStop.budget
              ? FreezeBudgetStopped(_budgetMessage ?? '')
              : const FreezePermissionDenied(),
        );
        continue;
      }
      stop = await _runLine(i);
    }
    if (!mounted) return;
    _finishFreeze(report: report);
  }

  String? _budgetMessage;

  void _setLine(int index, FreezeLineState state) {
    final lines = _freezeLines;
    if (lines == null || index >= lines.length) return;
    setState(() => lines[index] = state);
    _revision.value++;
  }

  /// Traite le service [index] : relit une recette liée, ou rédige le plat
  /// et crée son brouillon. Rend la raison d'arrêter les suivants, ou `null`.
  Future<_FreezeStop?> _runLine(int index) async {
    final workshop = _workshop;
    final course = _menu?.courses[index];
    if (workshop == null || course == null) return null;
    final drafts = ref.read(mealWorkshopDraftRepositoryProvider);

    if (course.isLinked) {
      final recipe = await drafts.readLinked(course.recipeId!);
      if (!mounted) return null;
      _setLine(
        index,
        recipe == null
            ? const FreezeLinkedUnreadable()
            : FreezeLinked(course.recipeId!),
      );
      return null;
    }

    _setLine(index, const FreezeWriting());
    try {
      final recipe = await ref
          .read(mealWorkshopFunctionsProvider)
          .writeRecipe(
            conversationId: _conversationId,
            titre: course.title,
            description: course.description,
            sides: [for (final s in course.sides) s.label],
            portions: _portions,
            globalConstraints: workshop.globalConstraints,
          );
      if (!mounted) return null;
      await _saveDraft(index, recipe);
      return null;
    } on WorkshopNoRecipeException catch (error, stackTrace) {
      reportUnexpectedError(
        feature: 'mealWorkshop.freeze.write',
        error: error,
        stackTrace: stackTrace,
        context: {'course': index, 'title_length': course.title.length},
        service: ref.read(errorReportServiceProvider),
      );
      if (!mounted) return null;
      _setLine(index, const FreezeNoRecipe());
      return null;
    } catch (error, stackTrace) {
      final failure = describeWorkshopFailure(error);
      reportUnexpectedError(
        feature: 'mealWorkshop.freeze.write',
        error: error,
        stackTrace: stackTrace,
        context: {
          'course': index,
          'kind': failure.kind.name,
          'title_length': course.title.length,
        },
        service: ref.read(errorReportServiceProvider),
      );
      if (!mounted) return null;
      switch (failure.kind) {
        case WorkshopFailureKind.aiBudget:
          _budgetMessage = failure.message;
          _setLine(index, FreezeBudgetStopped(failure.message));
          context.showErrorSnackBar('Recette non rédigée. ${failure.message}');
          return _FreezeStop.budget;
        case WorkshopFailureKind.permissionDenied:
          _setLine(index, const FreezePermissionDenied());
          return _FreezeStop.permission;
        case WorkshopFailureKind.dailyQuota:
        case WorkshopFailureKind.unreadable:
        case WorkshopFailureKind.refused:
        case WorkshopFailureKind.other:
          _setLine(index, FreezeFailed(error));
          return null;
      }
    }
  }

  /// Crée le brouillon d'une recette rédigée. Un échec garde la recette en
  /// mémoire : « Réessayer » ne refait pas d'appel.
  Future<void> _saveDraft(int index, Recipe recipe) async {
    final workshop = _workshop;
    if (workshop == null) return;
    try {
      // « Rédiger à la place » après un figement sans plat à rédiger : le
      // livre n'existe pas encore.
      final book = await _ensureBook();
      final id = await ref
          .read(mealWorkshopDraftRepositoryProvider)
          .createDraft(
            recipe: recipe,
            uid: workshop.myUid,
            book: book,
            portions: _portions,
          );
      if (!mounted) return;
      _setLine(index, FreezeDraftCreated(id));
    } catch (error, stackTrace) {
      reportUnexpectedError(
        feature: 'mealWorkshop.freeze.save',
        error: error,
        stackTrace: stackTrace,
        context: {'course': index},
        service: ref.read(errorReportServiceProvider),
      );
      if (!mounted) return;
      _setLine(index, FreezeSaveFailed(recipe, error));
    }
  }

  /// Le livre des brouillons, trouvé ou créé à la première recette à
  /// enregistrer, puis gardé pour le figement.
  Future<({String id, String titre})> _ensureBook() async {
    final workshop = _workshop;
    final choice = _bookChoice;
    if (workshop == null || choice == null) {
      throw StateError('Figement sans livre choisi.');
    }
    return _book ??= await ref
        .read(mealWorkshopDraftRepositoryProvider)
        .findOrCreateBook(
          choice,
          uid: workshop.myUid,
          displayName: workshop.displayName,
        );
  }

  /// Fin d'un passage de figement : le champ se ferme, le compte rendu
  /// s'affiche — à la fermeture de la feuille sur téléphone, où le snack du
  /// Scaffold passerait sous elle et expirerait avant qu'on le voie. Sans
  /// [report] (figement implicite d'une pose), aucun compte rendu.
  void _finishFreeze({bool report = true}) {
    final menu = _menu;
    final lines = _freezeLines;
    if (menu == null || lines == null) return;
    setState(() {
      _freezing = false;
      _frozen = true;
    });
    _revision.value++;
    if (!report) return;
    final created = freezeCreatedCount(lines);
    final notWritten = freezeNotWrittenCount(menu, lines);
    final ({bool success, String message}) outcome;
    if (menu.toWriteCount == 0) {
      outcome = (
        success: true,
        message: freezeLinkedOnlyMessage(freezeLinkedCount(lines)),
      );
    } else if (notWritten == 0) {
      outcome = (
        success: true,
        message: freezeDoneMessage(
          created: created,
          bookTitle:
              _book?.titre ??
              _bookChoice?.label ??
              MealWorkshopBook.kassDalle.label,
        ),
      );
    } else {
      outcome = (
        success: false,
        message: freezePartialMessage(notWritten: notWritten, created: created),
      );
    }
    if (_sheetOpen) {
      _pendingReport = outcome;
    } else {
      _showReport(outcome);
    }
  }

  void _showReport(({bool success, String message}) report) {
    if (report.success) {
      context.showSuccessSnackBar(report.message);
    } else {
      context.showErrorSnackBar(report.message);
    }
  }

  /// « Réessayer » sur une ligne : rejoue ce service seul. Une recette
  /// rédigée mais non enregistrée est seulement réenregistrée.
  Future<void> _retryLine(int index) async {
    if (_freezing || _sending || _posed) return;
    final lines = _freezeLines;
    if (lines == null || index >= lines.length) return;
    setState(() => _freezing = true);
    _revision.value++;
    final state = lines[index];
    if (state is FreezeSaveFailed) {
      await _saveDraft(index, state.recipe);
    } else {
      await _runLine(index);
    }
    if (!mounted) return;
    _finishFreeze();
  }

  /// « Rédiger à la place » : la recette liée devenue inaccessible est
  /// remplacée par un plat à rédiger, sous le même titre, puis rédigée.
  Future<void> _writeInstead(int index) async {
    final menu = _menu;
    if (menu == null || _freezing || _posed) return;
    setState(
      () => _menu = menu.withCourse(index, menu.courses[index].unlinked()),
    );
    await _retryLine(index);
  }

  /// « Retirer du repas » : sans confirmation.
  void _removeCourse(int index) {
    final menu = _menu;
    final lines = _freezeLines;
    if (menu == null || lines == null || _freezing || _posed) return;
    setState(() {
      _menu = menu.withoutCourse(index);
      lines.removeAt(index);
    });
    _revision.value++;
  }

  // ── Poser dans le planning ────────────────────────────────────────────────

  /// « Poser dans le planning » / « Poser à une autre date ». Sans figement
  /// (rien à rédiger), chaque recette liée est d'abord relue comme un
  /// figement sans plat à rédiger : aucun appel, aucun livre ; une recette
  /// plus lisible laisse le bouton inactif avec sa raison. Puis la boîte.
  /// Depuis la feuille du téléphone ([fromSheet]), la feuille se ferme
  /// d'abord : la boîte s'ouvre sur l'écran.
  Future<void> _requestPose({required bool fromSheet}) async {
    final workshop = _workshop;
    final menu = _menu;
    if (workshop == null ||
        menu == null ||
        menu.isEmpty ||
        _sending ||
        _freezing ||
        _posing) {
      return;
    }
    if (fromSheet) {
      // Le compte rendu du figement, retenu pendant que la feuille était
      // ouverte, ne passe pas devant « Posé le … » : la pose le remplace.
      _pendingReport = null;
      Navigator.of(context).pop();
    }
    setState(() => _posing = true);
    _revision.value++;
    try {
      if (_freezeLines == null) {
        // Le livre par défaut, « Mes créations Kass'Dalle ✨ », reste choisi :
        // il ne sert que si « Rédiger à la place » rédige ensuite un plat, et
        // le compte rendu de cette rédaction le nomme (`freezeDoneMessage`).
        await _startFreeze(
          const _FreezeChoice(book: MealWorkshopBook.kassDalle, decisions: {}),
          const [],
          report: false,
        );
        if (!mounted) return;
      }
      final lines = _freezeLines;
      final frozenMenu = _menu;
      if (lines == null ||
          frozenMenu == null ||
          workshopPoseBlocker(frozenMenu, lines) != null) {
        return;
      }
      final result = await showWorkshopPoseSheet(
        context,
        menu: frozenMenu,
        lines: List.unmodifiable(lines),
        workshop: workshop,
      );
      if (result == null || !mounted) return;
      setState(() => _poses.add(result));
      context.showSuccessSnackBar(
        posedMessage(result.plannedAt, result.target),
      );
    } finally {
      if (mounted) {
        setState(() => _posing = false);
        _revision.value++;
      }
    }
  }

  /// « Voir le planning » : le planning ouvert sur la période qui contient
  /// le jour de la pose.
  void _openPlanning(WorkshopPoseResult pose) {
    context.push(planningLocation(date: pose.plannedAt));
  }

  // ── Construction ──────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final asyncWorkshop = ref.watch(mealWorkshopContextProvider);
    // Première valeur figée : le corpus ne bouge plus pendant la conversation.
    if (_workshop == null && asyncWorkshop.hasValue) {
      _workshop = asyncWorkshop.value;
      _portions = _workshop!.defaultPortions;
      _quota = _workshop!.quota;
      _focusInputIfWide();
    }
    ref.listen(mealWorkshopContextProvider, (previous, next) {
      if (next.hasError && !next.isLoading) {
        reportUnexpectedError(
          feature: 'mealWorkshop.context',
          error: next.error!,
          stackTrace: next.stackTrace,
          service: ref.read(errorReportServiceProvider),
        );
      }
    });

    final wide =
        MediaQuery.sizeOf(context).width >= PlatformUtils.wideBreakpoint;

    return PopScope(
      canPop: _canLeaveFreely,
      onPopInvokedWithResult: (didPop, result) {
        if (didPop) return;
        _leaveAfterConfirmation();
      },
      child: Scaffold(
        appBar: AppBar(title: const Text('Atelier repas')),
        // Ordre de tabulation : champ, Envoyer, Plat | Menu, parts, services,
        // « Figer le repas » — l'ordre de lecture, pas celui de l'arbre.
        body: FocusTraversalGroup(
          policy: OrderedTraversalPolicy(),
          child: wide
              ? Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Expanded(
                      child: _buildConversation(asyncWorkshop, wide: true),
                    ),
                    const VerticalDivider(width: 1),
                    SizedBox(
                      width: PlatformUtils.sidePanelWidth,
                      child: _buildSidePanel(),
                    ),
                  ],
                )
              : _buildConversation(asyncWorkshop, wide: false),
        ),
      ),
    );
  }

  // ── Conversation ──────────────────────────────────────────────────────────

  Widget _buildConversation(
    AsyncValue<MealWorkshopContext> asyncWorkshop, {
    required bool wide,
  }) {
    return Column(
      children: [
        _buildKindSwitch(),
        Expanded(child: _buildMessages(asyncWorkshop, wide: wide)),
        if (!wide) _buildSummaryBanner(),
        _buildInputBar(wide: wide),
      ],
    );
  }

  /// « Plat | Menu », en tête de la conversation. Copie des segments de
  /// `meal_composer.dart` (`_buildKindSwitch`). Inactif pendant un tour et
  /// pendant un figement.
  Widget _buildKindSwitch() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
      child: Align(
        alignment: Alignment.centerLeft,
        child: FocusTraversalOrder(
          order: const NumericFocusOrder(3),
          child: SegmentedButton<MealKind>(
            segments: const [
              ButtonSegment(
                value: MealKind.plat,
                label: Text('Plat'),
                icon: Icon(Icons.restaurant_outlined),
                tooltip: 'Un seul plat et ses accompagnements',
              ),
              ButtonSegment(
                value: MealKind.menu,
                label: Text('Menu'),
                icon: Icon(Icons.restaurant_menu_outlined),
                tooltip: 'Entrée, plat, fromage, dessert…',
              ),
            ],
            selected: {_kind},
            showSelectedIcon: false,
            onSelectionChanged: _sending || _freezing
                ? null
                : (s) => _selectKind(s.first),
          ),
        ),
      ),
    );
  }

  Widget _buildMessages(
    AsyncValue<MealWorkshopContext> asyncWorkshop, {
    required bool wide,
  }) {
    final head = _buildHeadCard(asyncWorkshop);
    if (_entries.isEmpty && !_sending) {
      // Téléphone, clavier ouvert : la place laissée au-dessus du champ ne
      // tient pas l'accueil, qui se dessinait sur la barre de saisie. La
      // carte du périmètre reste.
      final showWelcome = _workshop != null && (wide || !_keyboardOpen);
      // Une zone qui défile : un petit écran ou un grand facteur de texte ne
      // fait pas déborder l'accueil. La hauteur minimale garde la carte en
      // haut et l'accueil centré dans la place restante (`spaceBetween` et
      // un dernier enfant vide : autant d'espace au-dessus qu'en dessous).
      return LayoutBuilder(
        builder: (context, constraints) => SingleChildScrollView(
          child: ConstrainedBox(
            constraints: BoxConstraints(minHeight: constraints.maxHeight),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 12, 12, 0),
                  child: head,
                ),
                if (showWelcome)
                  AppEmptyState(
                    icon: Icons.forum_outlined,
                    title: 'Dites ce que vous voulez manger',
                    message:
                        'Pour qui, quand, avec quelles envies ou contraintes. '
                        'L\'IA répond et pose un premier $_thing dans '
                        '« ${_isDish ? 'Plat' : 'Menu'} en cours ». Chaque '
                        'message envoyé est un appel à l\'IA.',
                  ),
                const SizedBox.shrink(),
              ],
            ),
          ),
        ),
      );
    }
    return ListView(
      controller: _scroll,
      padding: const EdgeInsets.all(12),
      children: [
        head,
        for (final entry in _entries)
          switch (entry) {
            _UserEntry(:final text) => WorkshopUserBubble(text: text),
            _AssistantEntry(
              :final result,
              :final changedCount,
              :final unchanged,
            ) =>
              WorkshopAssistantBubble(
                result: result,
                kind: _kind,
                changedCount: changedCount,
                unchanged: unchanged,
                onOpenMenu: wide ? null : () => _openSheet(),
              ),
            _ErrorEntry(:final failure) => WorkshopErrorCard(
              failure: failure,
              kind: _kind,
              onRetry: _canSend ? _send : null,
            ),
          },
        if (_sending) const WorkshopPendingRow(),
      ],
    );
  }

  Widget _buildHeadCard(AsyncValue<MealWorkshopContext> asyncWorkshop) {
    final workshop = _workshop;
    if (workshop != null) {
      final n = workshop.summaries.length;
      final m = workshop.staples.length;
      if (n == 0) {
        return const WorkshopSystemCard(
          icon: Icons.info_outline,
          text:
              'Aucune recette de la bibliothèque dans le périmètre : l\'IA ne '
              'proposera que des plats nouveaux.',
        );
      }
      return WorkshopSystemCard(
        icon: Icons.info_outline,
        text:
            'Périmètre : $n ${n > 1 ? 'recettes' : 'recette'} · '
            '$m ${m > 1 ? 'garnitures' : 'garniture'}',
      );
    }
    if (asyncWorkshop.hasError) {
      return AppErrorState(
        compact: true,
        title: 'Atelier non prêt',
        error: asyncWorkshop.error,
        onRetry: () => ref.invalidate(mealWorkshopContextProvider),
      );
    }
    return const WorkshopSystemCard(
      icon: Icons.hourglass_top,
      text: 'Préparation de l\'atelier…',
    );
  }

  /// Téléphone : « Plat · Bar rôti · 4 parts · modifié », « Menu · 3
  /// services · 4 parts · modifié : Dessert », « … · figé » après un
  /// figement.
  Widget _buildSummaryBanner() {
    final theme = Theme.of(context);
    final menu = _menu;
    final String text;
    final suffix = _freezing
        ? ' · figement en cours'
        : _posed
        ? ' · posé'
        : _freezeLines != null
        ? ' · figé'
        : _changed.isEmpty
        ? ''
        : ' · modifié';
    if (menu == null || menu.isEmpty) {
      text = '${_isDish ? 'Plat' : 'Menu'} · vide · $_portionsLabel';
    } else if (_isDish) {
      final dish = menu.courses.firstWhere(
        (c) => c.role == MealComponentRole.plat,
        orElse: () => menu.courses.first,
      );
      text = 'Plat · ${dish.title} · $_portionsLabel$suffix';
    } else {
      final changedLabel = _freezeLines == null && _changed.isNotEmpty
          ? ' : ${_changed.map((i) => menu.courses[i].typeLabel).join(', ')}'
          : '';
      text =
          'Menu · ${menu.courses.length} '
          '${menu.courses.length > 1 ? 'services' : 'service'} · '
          '$_portionsLabel$suffix$changedLabel';
    }
    return Material(
      color: theme.colorScheme.surfaceContainerLow,
      child: ListTile(
        dense: true,
        leading: Icon(
          _isDish ? Icons.restaurant_outlined : Icons.restaurant_menu,
        ),
        title: Text(text, maxLines: 1, overflow: TextOverflow.ellipsis),
        trailing: const Icon(Icons.chevron_right),
        onTap: _openSheet,
      ),
    );
  }

  /// L'aide sous le champ, selon l'état.
  String _helperText(MealWorkshopContext? workshop) {
    // Contexte en chargement : la carte en tête de liste le dit déjà ; le
    // compteur du jour s'ajoute dès qu'il est connu.
    if (workshop == null) {
      return '$kWorkshopMaxTurns tours au plus par conversation';
    }
    final quota = _quota;
    if (quota != null && quota.exhausted) {
      return exhaustedTurnsLine(quota.limit);
    }
    final remaining = quota == null ? null : remainingTurnsLine(quota);
    if (_turnsExhausted) {
      return 'Conversation terminée : $kWorkshopMaxTurns tours. Figez le '
          'repas, ou ouvrez une nouvelle conversation.';
    }
    // Avant le premier tour. Le périmètre, « aucune recette » compris, est
    // dit par la carte en tête de la conversation : il n'est pas répété ici.
    if (!_hasConversation) {
      return [
        '$kWorkshopMaxTurns tours au plus par conversation',
        ?remaining,
      ].join(' · ');
    }
    // Les tours faits : « Tour 3 sur 20 » après le troisième.
    return ['Tour $_userTurns sur $kWorkshopMaxTurns', ?remaining].join(' · ');
  }

  Widget _buildInputBar({required bool wide}) {
    final theme = Theme.of(context);
    final small = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    final workshop = _workshop;

    if (_freezing || _frozen) {
      return SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  _freezing ? 'Figement en cours…' : 'Repas figé.',
                  style: theme.textTheme.bodyMedium,
                ),
              ),
              TextButton(
                onPressed: _freezing ? null : _newConversationRequested,
                child: const Text('Nouvelle conversation'),
              ),
            ],
          ),
        ),
      );
    }

    final counter = '$_inputLength/$kWorkshopMaxMessageChars';
    // Actif pendant le chargement du contexte : on écrit, Envoyer attend.
    // Un champ inactif ignorerait `autofocus`.
    final enabled = !_sending && !_turnsExhausted && !_dayExhausted;

    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Expanded(
                  child: FocusTraversalOrder(
                    order: const NumericFocusOrder(1),
                    child: StylusPadTextField(
                      controller: _input,
                      focusNode: _inputFocus,
                      padTitle: 'Atelier repas',
                      enabled: enabled,
                      // Grand écran : le focus à l'ouverture ; téléphone :
                      // seulement si le champ est vide, pour ne pas ouvrir le
                      // clavier sur un texte à relire.
                      autofocus: wide || widget.initialMessage.isEmpty,
                      minLines: 1,
                      maxLines: 5,
                      // Entrée envoie, Maj+Entrée saute une ligne : la barre
                      // « Modifier la recette » d'une proposition de l'IA.
                      textInputAction: TextInputAction.send,
                      onSubmitted: (_) => _send(),
                      decoration: InputDecoration(
                        hintText: _isDish
                            ? 'ex : un plat de poisson pour 4 ce soir, avec un féculent'
                            : 'ex : un dîner pour 6, du poisson, un dessert aux fruits',
                        hintMaxLines: 2,
                        isDense: true,
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(20),
                        ),
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 14,
                          vertical: 10,
                        ),
                        counterText: counter,
                        errorText: _inputTooLong
                            ? 'Message trop long : $kWorkshopMaxMessageChars '
                                  'caractères au plus.'
                            : null,
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Padding(
                  // Aligné sur le champ, au-dessus de son compteur.
                  padding: const EdgeInsets.only(bottom: 22),
                  child: FocusTraversalOrder(
                    order: const NumericFocusOrder(2),
                    child: IconButton.filled(
                      onPressed: _canSend ? _send : null,
                      icon: const Icon(Icons.send_rounded),
                      tooltip: 'Envoyer',
                      constraints: const BoxConstraints.tightFor(
                        width: 48,
                        height: 48,
                      ),
                    ),
                  ),
                ),
              ],
            ),
            // Côte à côte quand l'aide et le bouton tiennent sur la ligne ;
            // sinon le bouton passe sous l'aide, à gauche ; une aide trop
            // longue pour une ligne prend toute la largeur. Une `Row` laissait à l'aide la largeur restante :
            // à 200 % le bouton remplit la ligne, l'aide se cassait sur des
            // dizaines de lignes et la liste des messages tombait à 0 px.
            OverflowBar(
              alignment: MainAxisAlignment.spaceBetween,
              overflowAlignment: OverflowBarAlignment.start,
              children: [
                Text(_helperText(workshop), style: small),
                // Inactif pendant un tour, comme le bouton parts et le
                // sélecteur Plat | Menu : la ligne garde sa hauteur.
                if (_hasConversation)
                  TextButton(
                    onPressed: _sending ? null : _newConversationRequested,
                    child: const Text('Nouvelle conversation'),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  // ── Le menu en cours ──────────────────────────────────────────────────────

  Widget _buildSidePanel() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _buildMenuHeader(),
        Expanded(
          child: FocusTraversalOrder(
            order: const NumericFocusOrder(5),
            child: ListView(
              padding: const EdgeInsets.only(bottom: 16),
              children: _buildMenuBody(),
            ),
          ),
        ),
        _buildMenuFooter(fromSheet: false),
      ],
    );
  }

  Widget _buildMenuHeader({VoidCallback? onClose}) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 8, 4),
      child: Row(
        children: [
          Expanded(
            child: Text(
              _isDish ? 'Plat en cours' : 'Menu en cours',
              style: theme.textTheme.titleMedium,
            ),
          ),
          Tooltip(
            message: 'Nombre de parts',
            child: FocusTraversalOrder(
              order: const NumericFocusOrder(4),
              child: OutlinedButton(
                onPressed: _sending || _freezing || _frozen
                    ? null
                    : _changePortions,
                child: Text(_portionsLabel),
              ),
            ),
          ),
          if (onClose != null)
            IconButton(
              onPressed: _freezing ? null : onClose,
              icon: const Icon(Icons.close),
              tooltip: 'Fermer',
            ),
        ],
      ),
    );
  }

  List<Widget> _buildMenuBody() {
    final menu = _menu;
    if (menu == null || menu.isEmpty) {
      return [
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 24),
          child: _isDish
              ? const AppEmptyState(
                  icon: Icons.restaurant_outlined,
                  title: 'Pas encore de plat',
                  message:
                      'Le plat s\'affichera ici après votre premier message.',
                )
              : const AppEmptyState(
                  icon: Icons.restaurant_menu,
                  title: 'Pas encore de menu',
                  message:
                      'Le premier menu s\'affichera ici après votre premier '
                      'message.',
                ),
        ),
      ];
    }
    final lines = _freezeLines;
    return [
      for (final (index, course) in menu.courses.indexed)
        WorkshopCourseTile(
          course: course,
          changed: _changed.contains(index),
          menuPortions: _portions,
          workshop: _workshop,
          freezeState: lines != null && index < lines.length
              ? lines[index]
              : null,
          freezeActions: WorkshopFreezeActions(
            onRetry: () => _retryLine(index),
            onWriteInstead: () => _writeInstead(index),
            onRemove: () => _removeCourse(index),
          ),
          busy: _freezing || _posing,
          posed: _posed,
        ),
    ];
  }

  Widget _buildMenuFooter({required bool fromSheet}) {
    final theme = Theme.of(context);
    final small = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    final menu = _menu;
    final lines = _freezeLines;
    // Le compte en tête du pied ; sous un bouton inactif, la raison.
    String? count;
    String? reason;
    // Le bouton : « Figer le repas », ou « Poser dans le planning » dès
    // qu'un figement est fini ou qu'il n'y a rien à rédiger ; aucun pendant
    // un figement.
    _FooterButton? button;
    if (menu == null || menu.isEmpty) {
      reason = _isDish ? 'Pas encore de plat.' : 'Le menu est vide.';
      button = _FooterButton.freeze;
    } else if (lines != null) {
      final created = freezeCreatedCount(lines);
      final linked = freezeLinkedCount(lines);
      // Sans plat à rédiger (tous les doublons liés) : les recettes liées
      // seules, pas « 0 brouillon créé ».
      count = menu.toWriteCount == 0 && created == 0
          ? linkedOnlyLine(linked)
          : freezeFooterLine(created: created, linked: linked);
      if (!_freezing) {
        button = _FooterButton.pose;
        reason = workshopPoseBlocker(menu, lines);
      }
    } else {
      count = menuFooterLine(
        toWrite: menu.toWriteCount,
        linked: menu.linkedCount,
      );
      if (menu.canFreeze) {
        button = _FooterButton.freeze;
      } else {
        // Rien à rédiger : la pose relit les recettes liées, puis la boîte.
        button = _FooterButton.pose;
        reason = workshopPoseBlocker(menu, const []) ?? kNothingToWritePoseLine;
      }
    }
    final canFreeze = _canFreeze;
    final canPose =
        button == _FooterButton.pose &&
        !_sending &&
        !_freezing &&
        !_posing &&
        _workshop != null &&
        menu != null &&
        !menu.isEmpty &&
        workshopPoseBlocker(menu, lines ?? const []) == null;
    return Material(
      color: theme.colorScheme.surfaceContainerLow,
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (count != null) Text(count, style: theme.textTheme.bodyMedium),
              if (_lastTruncated)
                Text(
                  _isDish
                      ? 'Plat limité à $kWorkshopMaxDishCourses services.'
                      : 'Menu limité à $kMaxCoursesPerMenu services.',
                  style: small,
                ),
              if (_isDish && _lastOffKind > 0)
                Text(
                  'Plat seul : $_lastOffKind ${_lastOffKind > 1 ? 'services écartés' : 'service écarté'}.',
                  style: small,
                ),
              for (final pose in _poses)
                Semantics(
                  liveRegion: true,
                  child: Text(
                    posedLine(pose.plannedAt, pose.target),
                    style: theme.textTheme.bodyMedium,
                  ),
                ),
              if (_posed)
                Align(
                  alignment: Alignment.centerLeft,
                  child: FocusTraversalOrder(
                    order: const NumericFocusOrder(6),
                    child: TextButton(
                      onPressed: () => _openPlanning(_poses.last),
                      child: const Text('Voir le planning'),
                    ),
                  ),
                ),
              if (button == _FooterButton.freeze) ...[
                const SizedBox(height: 8),
                FocusTraversalOrder(
                  order: const NumericFocusOrder(7),
                  child: FilledButton.icon(
                    onPressed: canFreeze
                        ? () => _requestFreeze(fromSheet: fromSheet)
                        : null,
                    icon: const Icon(Icons.save_outlined),
                    label: const Text('Figer le repas'),
                  ),
                ),
              ] else if (button == _FooterButton.pose) ...[
                const SizedBox(height: 8),
                FocusTraversalOrder(
                  order: const NumericFocusOrder(7),
                  child: _posed
                      ? OutlinedButton.icon(
                          onPressed: canPose
                              ? () => _requestPose(fromSheet: fromSheet)
                              : null,
                          icon: const Icon(AppIcons.calendarExport),
                          label: const Text('Poser à une autre date'),
                        )
                      : FilledButton.icon(
                          onPressed: canPose
                              ? () => _requestPose(fromSheet: fromSheet)
                              : null,
                          icon: const Icon(AppIcons.calendarExport),
                          label: const Text('Poser dans le planning'),
                        ),
                ),
              ],
              if (button != null && reason != null)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(reason, style: small),
                ),
            ],
          ),
        ),
      ),
    );
  }

  /// Téléphone : la feuille du menu, pleine hauteur. Verrouillée ([locked],
  /// ou dès qu'un figement a eu lieu) : ni appui hors d'elle, ni
  /// glissement, un bouton « Fermer » inactif pendant les appels ; le
  /// retour attend la fin des appels. Une reprise lancée depuis elle ne se
  /// ferme donc pas sous le doigt.
  Future<void> _openSheet({bool locked = false}) {
    FocusManager.instance.primaryFocus?.unfocus();
    final lock = locked || _freezeLines != null;
    final token = ++_sheetToken;
    _sheetOpen = true;
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      showDragHandle: !lock,
      isDismissible: !lock,
      enableDrag: !lock,
      builder: (ctx) => _WorkshopSheet(
        revision: _revision,
        locked: lock,
        isBusy: () => _freezing,
        header: () => _buildMenuHeader(
          onClose: lock ? () => Navigator.of(ctx).pop() : null,
        ),
        menuBody: _buildMenuBody,
        footer: () => _buildMenuFooter(fromSheet: true),
      ),
    ).whenComplete(() {
      // Une feuille plus récente est ouverte : sa fermeture décidera.
      if (token != _sheetToken) return;
      _sheetOpen = false;
      final report = _pendingReport;
      if (report == null || !mounted) return;
      _pendingReport = null;
      _showReport(report);
    });
  }
}

/// La feuille du téléphone : en-tête, services, pied. Les constructeurs
/// lisent l'état de l'écran au moment du rendu ; [revision] change quand
/// l'état change, et la feuille se redessine.
class _WorkshopSheet extends StatelessWidget {
  final ValueListenable<int> revision;
  final bool locked;
  final bool Function() isBusy;
  final Widget Function() header;
  final List<Widget> Function() menuBody;
  final Widget Function() footer;

  const _WorkshopSheet({
    required this.revision,
    required this.locked,
    required this.isBusy,
    required this.header,
    required this.menuBody,
    required this.footer,
  });

  @override
  Widget build(BuildContext context) {
    final height = MediaQuery.sizeOf(context).height;
    return ValueListenableBuilder<int>(
      valueListenable: revision,
      builder: (context, _, _) => PopScope(
        canPop: !locked || !isBusy(),
        child: SizedBox(
          height: height * 0.92,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              header(),
              Expanded(
                child: ListView(
                  padding: const EdgeInsets.only(bottom: 16),
                  children: menuBody(),
                ),
              ),
              footer(),
            ],
          ),
        ),
      ),
    );
  }
}

/// La boîte « Figer le repas » : ce qui va être rédigé, le livre des
/// brouillons, et une décision par doublon de titre. « Figer » reste inactif
/// tant qu'un doublon n'a pas sa réponse.
class _FreezeDialog extends StatefulWidget {
  final WorkshopMenu menu;
  final int portions;
  final List<WorkshopTitleDuplicate> duplicates;

  const _FreezeDialog({
    required this.menu,
    required this.portions,
    required this.duplicates,
  });

  @override
  State<_FreezeDialog> createState() => _FreezeDialogState();
}

class _FreezeDialogState extends State<_FreezeDialog> {
  MealWorkshopBook _book = MealWorkshopBook.kassDalle;
  final Map<int, DuplicateDecision> _decisions = {};

  bool get _allDecided =>
      widget.duplicates.every((d) => _decisions.containsKey(d.courseIndex));

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final small = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    final menu = widget.menu;
    // Un doublon lié ne sera pas rédigé : la phrase compte ce qui part.
    final linkedByDecision = _decisions.values
        .where((d) => d == DuplicateDecision.link)
        .length;
    final toWrite = menu.toWriteCount - linkedByDecision;
    final linked = menu.linkedCount + linkedByDecision;

    return AlertDialog(
      title: const Text('Figer le repas'),
      scrollable: true,
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            freezeDialogSummary(
              toWrite: toWrite,
              linked: linked,
              portions: widget.portions,
            ),
          ),
          for (final line in freezeSidesLines(menu))
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(line, style: small),
            ),
          const SizedBox(height: 16),
          Text('Livre des brouillons', style: theme.textTheme.titleSmall),
          RadioGroup<MealWorkshopBook>(
            groupValue: _book,
            onChanged: (book) {
              if (book != null) setState(() => _book = book);
            },
            child: Column(
              children: [
                for (final book in MealWorkshopBook.values)
                  RadioListTile<MealWorkshopBook>(
                    value: book,
                    title: Text(book.label),
                    contentPadding: EdgeInsets.zero,
                  ),
              ],
            ),
          ),
          if (widget.duplicates.isNotEmpty) ...[
            const SizedBox(height: 16),
            Text(
              'Titres déjà dans votre bibliothèque',
              style: theme.textTheme.titleSmall,
            ),
            for (final d in widget.duplicates) ...[
              const SizedBox(height: 8),
              Text(d.line),
              const SizedBox(height: 4),
              SegmentedButton<DuplicateDecision>(
                segments: const [
                  ButtonSegment(
                    value: DuplicateDecision.link,
                    label: Text('Lier la recette existante'),
                  ),
                  ButtonSegment(
                    value: DuplicateDecision.write,
                    label: Text('Rédiger quand même'),
                  ),
                ],
                selected: {?_decisions[d.courseIndex]},
                emptySelectionAllowed: true,
                showSelectedIcon: false,
                onSelectionChanged: (s) => setState(() {
                  if (s.isEmpty) {
                    _decisions.remove(d.courseIndex);
                  } else {
                    _decisions[d.courseIndex] = s.first;
                  }
                }),
              ),
            ],
            if (!_allDecided)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text('Choisissez pour chaque doublon.', style: small),
              ),
          ],
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Annuler'),
        ),
        FilledButton(
          onPressed: _allDecided
              ? () => Navigator.of(context).pop(
                  _FreezeChoice(
                    book: _book,
                    decisions: Map.unmodifiable(_decisions),
                  ),
                )
              : null,
          child: const Text('Figer'),
        ),
      ],
    );
  }
}
