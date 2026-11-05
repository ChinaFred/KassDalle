import 'dart:async';

import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../../core/presentation/leave_guard.dart';
import '../../../../../core/presentation/stylus_pad_text_field.dart';
import '../../../../../core/services/error_report_service.dart';
import '../../../../../core/services/error_reporting.dart';
import '../../../../../core/utils/platform_utils.dart';
import '../../../../../core/widgets/app_states.dart';
import '../../../../admin/presentation/admin_providers.dart'
    show errorReportServiceProvider;
import '../../../../planning/domain/meal_component.dart' show MealComponentRole;
import '../../../../planning/domain/meal_composition.dart'
    show kMaxCoursesPerMenu;
import '../../../../planning/domain/meal_kind.dart';
import '../../../../recipes/presentation/detail/portions_input_dialog.dart';
import '../../../data/sandbox_functions.dart';
import '../../../domain/meal_workshop_menu.dart';
import '../../../domain/sandbox_model_choice.dart';
import '../../sandbox_providers.dart';
import '../../widgets/sandbox_model_picker.dart';
import 'meal_workshop_widgets.dart';

/// Expérience : l'atelier repas, palier 0.
///
/// Une conversation bornée (20 tours, 1 500 caractères par message) pour
/// composer un plat et ses accompagnements (« Plat », le mode par défaut) ou
/// un repas complet (« Menu »), et un menu structuré que le serveur contrôle
/// et que l'écran redessine à chaque tour. Le mode est fixé pour la durée
/// d'une conversation : le changer en cours de route en ouvre une nouvelle,
/// après confirmation. Une troisième zone, « Mesures »,
/// donne le choix du modèle, la taille du contexte envoyé, le coût de chaque
/// tour et un tableau récapitulatif à copier : c'est ce que le palier 0 doit
/// mesurer avant qu'on écrive le palier 1 (`documentation/ToDo/SPEC-atelier-repas.md`).
///
/// Rien n'est enregistré : ni Firestore, ni Storage. Tout vit en mémoire et
/// disparaît avec l'écran. Le périmètre est « Mes recettes » + « Ma famille »
/// de l'administrateur, sans filtres, figé à l'ouverture.
///
/// Pas de « Figer le repas » : c'est le palier 1. La garde de sortie est
/// conservée : vingt tours d'un scénario se perdraient sinon d'un appui sur
/// le rail.
class SandboxMealWorkshopScreen extends ConsumerStatefulWidget {
  const SandboxMealWorkshopScreen({super.key});

  @override
  ConsumerState<SandboxMealWorkshopScreen> createState() =>
      _SandboxMealWorkshopScreenState();
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
  final Object error;
  const _ErrorEntry(this.error);
}

class _SandboxMealWorkshopScreenState
    extends ConsumerState<SandboxMealWorkshopScreen> {
  final SandboxFunctions _sandbox = SandboxFunctions();
  final ErrorReportService _errors = ErrorReportService();
  final TextEditingController _input = TextEditingController();
  final FocusNode _inputFocus = FocusNode();
  final ScrollController _scroll = ScrollController();

  /// Le contexte figé à la première lecture : un changement de corpus
  /// pendant la conversation n'a pas d'effet.
  MealWorkshopContext? _workshop;

  final List<_Entry> _entries = [];

  /// Les tours envoyés au serveur : `{role, text}`, dans l'ordre.
  final List<Map<String, String>> _history = [];

  WorkshopMenu? _menu;
  Set<int> _changed = const {};
  bool _lastTruncated = false;
  int _portions = kWorkshopDefaultPortions;

  /// Plat ou menu. Non persisté ; « Plat » à l'ouverture.
  MealKind _kind = MealKind.plat;
  bool _sending = false;
  SandboxModelChoice? _modelChoice;
  final List<WorkshopTurnMeasure> _measures = [];
  WorkshopTurnResult? _lastResult;
  int _inputLength = 0;

  /// Rang de la conversation en cours, porté par chaque mesure.
  int _conversation = 1;

  /// Incrémenté quand les parts ou le modèle changent : la feuille du
  /// téléphone, route modale au-dessus de l'écran, se redessine en l'écoutant.
  final ValueNotifier<int> _revision = ValueNotifier<int>(0);

  late final LeaveGuardNotifier _leaveGuardNotifier;
  LeaveGuard? _previousGuard;

  int get _userTurns => _history.where((t) => t['role'] == 'user').length;

  /// « 4 parts », « 1 part ».
  String get _portionsLabel => '$_portions ${_portions > 1 ? 'parts' : 'part'}';
  bool get _isDish => _kind == MealKind.plat;

  /// « plat » ou « menu », pour les libellés qui nomment ce qu'on compose.
  String get _thing => _isDish ? 'plat' : 'menu';
  bool get _turnsExhausted => _userTurns >= kWorkshopMaxTurns;
  bool get _hasConversation => _history.isNotEmpty;
  bool get _inputTooLong => _inputLength > kWorkshopMaxMessageChars;
  bool get _canSend =>
      !_sending &&
      _workshop != null &&
      !_turnsExhausted &&
      _input.text.trim().isNotEmpty &&
      !_inputTooLong;

  @override
  void initState() {
    super.initState();
    _input.addListener(_onInputChanged);
    _restoreModelChoice();
    _leaveGuardNotifier = ref.read(leaveGuardProvider.notifier);
    _previousGuard = ref.read(leaveGuardProvider);
    // Après le rendu : un provider ne se modifie pas pendant la construction.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _leaveGuardNotifier.set(_leaveGuard);
    });
  }

  @override
  void dispose() {
    // Différé : un provider ne se modifie pas pendant le démontage de l'arbre.
    final notifier = _leaveGuardNotifier;
    final guard = _leaveGuard;
    final previous = _previousGuard;
    Future.microtask(() => notifier.restoreIf(guard, previous));
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

  Future<void> _restoreModelChoice() async {
    final choice = await SandboxModelPicker.restore(kWorkshopFeature);
    if (!mounted) return;
    setState(() => _modelChoice = choice);
  }

  // ── Garde de sortie ───────────────────────────────────────────────────────

  /// Vrai quand l'écran peut être quitté : sans tour, librement ; avec une
  /// conversation, après confirmation.
  Future<bool> _leaveGuard() async {
    if (!_hasConversation) return true;
    final leave = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Quitter sans enregistrer ?'),
        content: Text(
          _isDish
              ? 'Le plat et la conversation seront perdus.'
              : 'Le menu et la conversation seront perdus.',
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
    _scrollToEnd();

    final turn = _userTurns + 1;
    final payload = <String, dynamic>{
      'kind': _kind.key,
      'history': [for (final t in _history) Map<String, String>.from(t)],
      'message': text,
      'recipes': workshop.summaries,
      'staples': workshop.staplePayload,
      'globalConstraints': workshop.globalConstraints,
      'portions': _portions,
      'menu': _menu?.toJson(),
      if (_modelChoice != null) 'provider': _modelChoice!.provider,
      if (_modelChoice != null) 'model': _modelChoice!.model,
    };

    try {
      final data = await _sandbox.call(kWorkshopExperiment, payload);
      final result = WorkshopTurnResult.fromJson(data);
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
        _lastResult = result;
        _measures.add(
          WorkshopTurnMeasure.fromResult(
            result,
            conversation: _conversation,
            kind: _kind,
          ),
        );
        _input.clear();
        _sending = false;
      });
      _scrollToEnd();
    } on SandboxCallException catch (error, stackTrace) {
      // Un refus attendu (réponse illisible, 21e tour) reste un événement à
      // tracer : le bac à sable mesure, et un code sans rapport ne se compte
      // pas.
      unawaited(
        _errors.reportError(
          feature: 'sandbox.mealWorkshop.turn',
          error: error,
          stackTrace: stackTrace,
          context: {
            'code': error.code,
            'reason': error.reason,
            'turn': turn,
            'message_length': text.length,
            'corpus_size': workshop.summaries.length,
          },
        ),
      );
      if (!mounted) return;
      setState(() {
        _sending = false;
        _entries.add(_ErrorEntry(error));
        if (error.reason == kWorkshopUnreadableReason) {
          // Facturé sans réponse lisible : la ligne du tableau le dit.
          _measures.add(
            WorkshopTurnMeasure.unreadable(
              error.details,
              conversation: _conversation,
              kind: _kind,
              fallbackTurn: turn,
            ),
          );
        }
      });
      _scrollToEnd();
    } catch (error, stackTrace) {
      unawaited(
        _errors.reportError(
          feature: 'sandbox.mealWorkshop.turn',
          error: error,
          stackTrace: stackTrace,
          context: {
            'turn': turn,
            'message_length': text.length,
            'corpus_size': workshop.summaries.length,
          },
        ),
      );
      if (!mounted) return;
      setState(() {
        _sending = false;
        _entries.add(_ErrorEntry(error));
      });
      _scrollToEnd();
    }
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

  /// Même périmètre, menu vide, parts et modèle conservés. Les mesures
  /// restent : elles comptent les appels faits depuis cet écran, et le rang
  /// de conversation les distingue. Le texte du champ reste : un message
  /// tapé avant de repartir n'est pas perdu. [kind] change le mode.
  void _newConversation({MealKind? kind}) {
    setState(() {
      _entries.clear();
      _history.clear();
      _menu = null;
      _changed = const {};
      _lastTruncated = false;
      _lastResult = null;
      if (kind != null) _kind = kind;
      _conversation++;
    });
    _revision.value++;
    _inputFocus.requestFocus();
  }

  /// « Nouvelle conversation » : sans confirmation à 20 tours (le champ est
  /// fermé, rien ne peut plus se perdre par un envoi), avec confirmation
  /// avant, puisqu'une conversation en cours se perd.
  Future<void> _newConversationRequested() async {
    if (!_turnsExhausted) {
      final confirmed = await _confirmDiscard(
        title: 'Nouvelle conversation ?',
        action: 'Nouvelle conversation',
      );
      if (!confirmed || !mounted) return;
    }
    _newConversation();
  }

  /// Le choix Plat | Menu. Sans conversation : bascule libre, la carte d'un
  /// tour échoué disparaît. Avec une conversation : confirmation, puis
  /// nouvelle conversation dans le nouveau mode.
  Future<void> _selectKind(MealKind kind) async {
    if (kind == _kind || _sending) return;
    if (!_hasConversation) {
      setState(() {
        _kind = kind;
        _entries.removeWhere((e) => e is _ErrorEntry);
      });
      _revision.value++;
      return;
    }
    final toMenu = kind == MealKind.menu;
    final confirmed = await _confirmDiscard(
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
    required String action,
  }) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: Text(
          'La conversation et le $_thing en cours seront perdus. Rien '
          'n\'était enregistré.',
        ),
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

  // ── Construction ──────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final asyncWorkshop = ref.watch(mealWorkshopContextProvider);
    // Première valeur figée : le corpus ne bouge plus pendant la conversation.
    if (_workshop == null && asyncWorkshop.hasValue) {
      _workshop = asyncWorkshop.value;
    }
    ref.listen(mealWorkshopContextProvider, (previous, next) {
      if (next.hasError && !next.isLoading) {
        reportUnexpectedError(
          feature: 'sandbox.mealWorkshop.context',
          error: next.error!,
          stackTrace: next.stackTrace,
          service: ref.read(errorReportServiceProvider),
        );
      }
    });

    final wide =
        MediaQuery.sizeOf(context).width >= PlatformUtils.wideBreakpoint;

    return PopScope(
      canPop: !_hasConversation,
      onPopInvokedWithResult: (didPop, result) {
        if (didPop) return;
        _leaveAfterConfirmation();
      },
      child: Scaffold(
        appBar: AppBar(title: const Text('Atelier repas')),
        body: wide
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
  /// `meal_composer.dart` (`_buildKindSwitch`). Inactif pendant un tour.
  Widget _buildKindSwitch() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
      child: Align(
        alignment: Alignment.centerLeft,
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
          onSelectionChanged: _sending ? null : (s) => _selectKind(s.first),
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
      return Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 12, 12, 0),
            child: head,
          ),
          Expanded(
            child: _workshop == null
                ? const SizedBox.shrink()
                : AppEmptyState(
                    icon: Icons.forum_outlined,
                    title: 'Dites ce que vous voulez manger',
                    message:
                        'Pour qui, quand, avec quelles envies ou contraintes. '
                        'L\'IA répond et pose un premier $_thing dans '
                        '« ${_isDish ? 'Plat' : 'Menu'} en cours ». Chaque '
                        'message envoyé est un appel à l\'IA.',
                  ),
          ),
        ],
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
            _ErrorEntry(:final error) => WorkshopErrorCard(
              error: error,
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

  /// Téléphone : « Plat · Bar rôti · 4 parts · modifié » ou « Menu · 3
  /// services · 4 parts · modifié : Dessert ».
  Widget _buildSummaryBanner() {
    final theme = Theme.of(context);
    final menu = _menu;
    final String text;
    if (menu == null || menu.isEmpty) {
      text = '${_isDish ? 'Plat' : 'Menu'} · vide · $_portionsLabel';
    } else if (_isDish) {
      final dish = menu.courses.firstWhere(
        (c) => c.role == MealComponentRole.plat,
        orElse: () => menu.courses.first,
      );
      text =
          'Plat · ${dish.title} · $_portionsLabel'
          '${_changed.isEmpty ? '' : ' · modifié'}';
    } else {
      final changedLabel = _changed.isEmpty
          ? ''
          : ' · modifié : ${_changed.map((i) => menu.courses[i].typeLabel).join(', ')}';
      text =
          'Menu · ${menu.courses.length} '
          '${menu.courses.length > 1 ? 'services' : 'service'} · '
          '$_portionsLabel$changedLabel';
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
        onTap: () => _openSheet(),
      ),
    );
  }

  Widget _buildInputBar({required bool wide}) {
    final theme = Theme.of(context);
    final workshop = _workshop;
    final String helper;
    if (workshop == null) {
      helper = 'Préparation de l\'atelier…';
    } else if (_turnsExhausted) {
      helper =
          'Conversation terminée : $kWorkshopMaxTurns tours. Ouvrez une '
          'nouvelle conversation.';
    } else if (!_hasConversation) {
      final n = workshop.summaries.length;
      helper =
          'Périmètre : ${n == 0 ? 'aucune recette' : '$n ${n > 1 ? 'recettes' : 'recette'}'}'
          ' · $kWorkshopMaxTurns tours au plus par conversation.';
    } else {
      helper = 'Tour ${_userTurns + 1} sur $kWorkshopMaxTurns.';
    }
    final counter = '$_inputLength/$kWorkshopMaxMessageChars';

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
                  child: StylusPadTextField(
                    controller: _input,
                    focusNode: _inputFocus,
                    padTitle: 'Atelier repas',
                    enabled: !_sending && !_turnsExhausted,
                    autofocus: true,
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
                          ? 'Message trop long : '
                                '${formatWorkshopCount(kWorkshopMaxMessageChars)} '
                                'caractères au plus.'
                          : null,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Padding(
                  // Aligné sur le champ, au-dessus de son compteur.
                  padding: const EdgeInsets.only(bottom: 22),
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
              ],
            ),
            Row(
              children: [
                Expanded(
                  child: Text(
                    helper,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
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

  // ── Menu et mesures ───────────────────────────────────────────────────────

  Widget _buildSidePanel() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _buildMenuHeader(),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.only(bottom: 16),
            children: [
              ..._buildMenuBody(),
              const Divider(height: 24),
              _buildMeasures(),
            ],
          ),
        ),
        _buildMenuFooter(),
      ],
    );
  }

  Widget _buildMenuHeader() {
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
            child: OutlinedButton(
              onPressed: _sending ? null : _changePortions,
              child: Text(_portionsLabel),
            ),
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
    return [
      for (final (index, course) in menu.courses.indexed)
        WorkshopCourseTile(
          course: course,
          changed: _changed.contains(index),
          menuPortions: _portions,
          workshop: _workshop,
        ),
    ];
  }

  Widget _buildMenuFooter() {
    final theme = Theme.of(context);
    final small = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    final menu = _menu;
    final count = menu == null || menu.isEmpty
        ? (_isDish ? 'Pas encore de plat.' : 'Le menu est vide.')
        : '${menu.toWriteCount} ${menu.toWriteCount > 1 ? 'plats' : 'plat'} à '
              'rédiger · ${menu.linkedCount} '
              '${menu.linkedCount > 1 ? 'recettes liées' : 'recette liée'}';
    final offKind = _lastResult?.control.offKindCourses ?? 0;
    return Material(
      color: theme.colorScheme.surfaceContainerLow,
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(count, style: theme.textTheme.bodyMedium),
              if (_lastTruncated)
                Text(
                  _isDish
                      ? 'Plat limité à $kWorkshopMaxDishCourses services.'
                      : 'Menu limité à $kMaxCoursesPerMenu services.',
                  style: small,
                ),
              if (_isDish && offKind > 0)
                Text(
                  'Plat seul : $offKind ${offKind > 1 ? 'services écartés' : 'service écarté'}.',
                  style: small,
                ),
              Text('Rien n\'est enregistré : bac à sable.', style: small),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildMeasures() {
    return WorkshopMeasuresPanel(
      modelChoice: _modelChoice,
      onModelChanged: (choice) {
        setState(() => _modelChoice = choice);
        _revision.value++;
      },
      enabled: !_sending,
      contextChars: _workshop?.contextChars ?? 0,
      lastResult: _lastResult,
      measures: _measures,
    );
  }

  /// Téléphone : la feuille Menu | Mesures, pleine hauteur.
  Future<void> _openSheet() {
    FocusManager.instance.primaryFocus?.unfocus();
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      showDragHandle: true,
      builder: (_) => _WorkshopSheet(
        revision: _revision,
        kind: () => _kind,
        header: _buildMenuHeader,
        menuBody: _buildMenuBody,
        footer: _buildMenuFooter,
        measures: _buildMeasures,
      ),
    );
  }
}

/// La feuille du téléphone : « Plat | Mesures » ou « Menu | Mesures ». Les
/// constructeurs lisent l'état de l'écran au moment du rendu ; [revision]
/// change quand les parts, le modèle ou le mode changent, et la feuille se
/// redessine.
class _WorkshopSheet extends StatefulWidget {
  final ValueListenable<int> revision;
  final MealKind Function() kind;
  final Widget Function() header;
  final List<Widget> Function() menuBody;
  final Widget Function() footer;
  final Widget Function() measures;

  const _WorkshopSheet({
    required this.revision,
    required this.kind,
    required this.header,
    required this.menuBody,
    required this.footer,
    required this.measures,
  });

  @override
  State<_WorkshopSheet> createState() => _WorkshopSheetState();
}

class _WorkshopSheetState extends State<_WorkshopSheet> {
  bool _showMeasures = false;

  @override
  Widget build(BuildContext context) {
    final height = MediaQuery.sizeOf(context).height;
    return SizedBox(
      height: height * 0.92,
      child: ValueListenableBuilder<int>(
        valueListenable: widget.revision,
        builder: (context, _, _) => Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: SegmentedButton<bool>(
                segments: [
                  ButtonSegment(value: false, label: Text(widget.kind().label)),
                  const ButtonSegment(value: true, label: Text('Mesures')),
                ],
                selected: {_showMeasures},
                onSelectionChanged: (selection) =>
                    setState(() => _showMeasures = selection.first),
              ),
            ),
            if (_showMeasures)
              Expanded(
                child: ListView(
                  padding: const EdgeInsets.only(bottom: 16),
                  children: [widget.measures()],
                ),
              )
            else ...[
              widget.header(),
              Expanded(
                child: ListView(
                  padding: const EdgeInsets.only(bottom: 16),
                  children: widget.menuBody(),
                ),
              ),
              widget.footer(),
            ],
          ],
        ),
      ),
    );
  }
}
