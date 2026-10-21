import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'admin_providers.dart';
import 'backfill_failures_sheet.dart';
import 'backfill_schedule_editor.dart';
import 'billing_providers.dart';
import 'move_meals_to_group_dialog.dart';
import '../data/gcp_billing_repository.dart';
import '../domain/backfill_failures.dart';
import '../domain/backfill_registry.dart';
import '../domain/backfill_status.dart';
import '../domain/move_meals_request.dart';
import '../domain/recipe_roles_backfill_report.dart';
import '../../../core/router/app_router.dart';
import '../../../core/services/error_reporting.dart';
import '../../../core/theme/app_icon_size.dart';
import '../../../core/utils/context_extensions.dart';
import '../../../core/utils/platform_utils.dart';
import '../../../core/widgets/app_states.dart';

/// Admin › Backfills : les reprises de données, rangées en trois sections.
///
/// - **Récurrents** : du travail à chaque nouvelle recette ou nouvel
///   ingrédient. Date du dernier passage, programmation (jours + heure de
///   Paris) lancée par la tâche `scheduledBackfills`.
/// - **Ponctuels à lancer** : un fonds antérieur à reprendre une fois.
/// - **Ponctuels terminés** : passés sans reste (marqués par le serveur) ou
///   marqués à la main, en attendant leur retrait du code.
///
/// L'état de chaque tuile est lu en continu dans Firestore : un passage
/// programmé, ou lancé depuis un autre appareil, apparaît sans rafraîchir.
/// Lancer un backfill ne bloque pas l'écran : chaque backfill a son verrou
/// côté serveur, et deux backfills différents tournent ensemble.
class AdminBackfillsScreen extends ConsumerStatefulWidget {
  const AdminBackfillsScreen({super.key});

  @override
  ConsumerState<AdminBackfillsScreen> createState() =>
      _AdminBackfillsScreenState();
}

/// Ce qu'un passage lancé depuis l'écran rend à la bannière.
class _PassOutcome {
  final String message;
  final BackfillFailures? failures;
  final bool termineAuto;

  const _PassOutcome({
    required this.message,
    required this.failures,
    required this.termineAuto,
  });
}

String _flag(BackfillCounts r, String key, String text) =>
    (r[key] ?? 0) == 1 ? text : '';

class _AdminBackfillsScreenState extends ConsumerState<AdminBackfillsScreen> {
  /// Backfills lancés depuis cet écran et pas encore revenus.
  final Set<String> _launching = {};

  String? _resultMessage;
  bool _resultIsError = false;

  /// Éléments à revoir du dernier passage revenu, et le titre de sa tuile.
  BackfillFailures? _failures;
  String _failuresTitle = '';

  bool _termineesExpanded = true;

  /// Rafraîchit l'heure de référence : un verrou expire, une reprise
  /// annoncée « à 04:00 » passe à l'heure suivante.
  Timer? _clock;
  DateTime _now = DateTime.now();

  @override
  void initState() {
    super.initState();
    _clock = Timer.periodic(const Duration(minutes: 1), (_) {
      if (mounted) setState(() => _now = DateTime.now());
    });
  }

  @override
  void dispose() {
    _clock?.cancel();
    super.dispose();
  }

  GcpBillingRepository get _repo => ref.read(gcpBillingRepositoryProvider);

  // ── Passages ──────────────────────────────────────────────────────────────

  /// Ce que la boîte de confirmation dit avant de lancer.
  String _confirmText(BackfillDefinition def) {
    switch (def.key) {
      case BackfillKeys.nutrition:
        return 'Reprend le calcul des recettes dont la nutrition manque, a '
            'échoué ou reste incomplète, quarante au plus.\n\n'
            'Le passage programmé attend vingt heures entre deux tentatives, '
            'renonce après cinq essais et ne reprend pas une recette à laquelle '
            'il ne manque que des lignes impossibles à peser ou des '
            'ingrédients plus redemandés à l\'IA. Ce passage-ci lève '
            'ces trois limites : utile juste après une correction de '
            'référentiel.\n\n'
            'Appels d\'IA facturés. Relancez tant que le résultat indique '
            '« incomplet ».';
      case BackfillKeys.enrichReferentials:
        return 'Estime par l\'IA le poids des unités sans conversion et les '
            'valeurs nutritionnelles des ingrédients qui en manquent.\n\n'
            '$_exclusionText\n\n'
            'Appels d\'IA facturés, huit minutes de travail au plus. Reprend '
            'où il s\'était arrêté.';
      case BackfillKeys.allergens:
        return 'Demande à l\'IA les allergènes des ingrédients qui n\'en ont '
            'pas, quarante par appel et quatre cents au plus. Une fois tout '
            'le référentiel parcouru, recalcule ceux des recettes, sans '
            'appel d\'IA.\n\n'
            '$_exclusionText\n\n'
            'Appels d\'IA facturés. Relancez tant que le résultat indique '
            '« incomplet ».';
      case BackfillKeys.recipeRoles:
        final report = _rolesReport();
        final reste = report == null ? '' : '\n\n${report.restantesSentence}';
        return 'Demande à l\'IA le rôle dans un repas de chaque recette non '
            'classée, et ce qu\'elle apporte déjà. Un appel par recette, '
            'quarante au plus.\n\n'
            '$_exclusionText\n\n'
            'Appels d\'IA facturés.$reste';
      case BackfillKeys.shoppingProducts:
        return 'Recalcule la liste de courses de toutes les recettes avec la '
            'règle du jour. Une recette dont le résultat ne change pas n\'est '
            'pas réécrite.\n\n'
            'Aucun appel d\'IA. Cinq cents recettes par passage.';
      case BackfillKeys.refreshSodium:
        return 'Le sel et le sodium d\'un ingrédient étaient additionnés : '
            'tout ingrédient salé porte un sel deux fois trop élevé. Ce '
            'passage fait réestimer par l\'IA les ingrédients porteurs de '
            'sodium.\n\n'
            'Dépense importante : autant qu\'un premier remplissage du '
            'référentiel. Relancez tant que le résultat indique « incomplet ».';
      case BackfillKeys.defaultUnits:
        return 'Crée dans le référentiel les unités de mesure standard qui '
            'manquent (gramme, cuillère à soupe, verre, pincée…), et complète '
            'celles qui n\'ont pas encore leur grammage, leur volume, leur '
            'libellé ou leur type. Une valeur déjà saisie n\'est jamais '
            'remplacée.\n\n'
            'Aucun appel d\'IA. Quarante unités par passage ; on peut '
            'relancer, une unité complète n\'est pas réécrite.';
      case BackfillKeys.moveMealsToGroup:
        return 'Vos repas de « Mon planning » sur cette période passent dans '
            'le planning du groupe : ses membres les voient, et ils quittent '
            'votre planning personnel. La recette, la date, les parts et les '
            'événements déjà exportés vers l\'agenda ne changent pas. Un repas '
            'déjà dans un groupe est laissé tel quel ; on peut relancer.\n\n'
            'Aucun appel d\'IA.';
      default:
        return '';
    }
  }

  /// Backfills dont la confirmation propose « Réessayer aussi les éléments
  /// exclus après 3 échecs » : ceux qui tiennent une mémoire des échecs.
  static const _retryableKeys = {
    BackfillKeys.enrichReferentials,
    BackfillKeys.allergens,
    BackfillKeys.recipeRoles,
  };

  static const _exclusionText =
      'Un élément qui échoue trois fois n\'est plus redemandé à l\'IA. '
      'Cochez la case ci-dessous pour le réessayer quand même.';

  RecipeRolesBackfillReport? _rolesReport() {
    final raw = ref
        .read(backfillRunsProvider)
        .value?[BackfillKeys.recipeRoles]
        ?.lastReport;
    return raw == null ? null : RecipeRolesBackfillReport.fromMap(raw);
  }

  _PassOutcome _fromCounts(BackfillCounts r, String message) => _PassOutcome(
    message: message,
    failures: r.failures,
    termineAuto: (r['termineAuto'] ?? 0) == 1,
  );

  /// Lance le passage de [def] et met en forme son compte rendu.
  /// [retryExcluded] : la case « Réessayer aussi les éléments exclus après 3 échecs ».
  /// [move] porte les paramètres de « Déplacer mes repas vers un groupe ».
  Future<_PassOutcome> _runPass(
    BackfillDefinition def, {
    bool retryExcluded = false,
    MoveMealsRequest? move,
  }) async {
    switch (def.key) {
      case BackfillKeys.nutrition:
        final r = await _repo.backfillNutrition();
        return _fromCounts(
          r,
          'Recettes : examinées=${r['examinees']}, reprises=${r['reprises']}, '
          'complétées=${r['completees']}, encore incomplètes=${r['echouees']}, '
          'laissées faute de temps=${r['laissees']}, '
          'sans reprise possible=${r['nonReprenables']}, '
          'abandonnées=${r['abandonnees']}'
          '${(r['completed'] ?? 0) == 1 && (r['echouees'] ?? 0) == 0 ? ' — terminé' : ' — incomplet'}'
          '${_flag(r, 'stoppedByBudget', ' (plafond de dépense atteint)')}'
          '${_flag(r, 'stoppedByDeadline', ' (arrêt préventif, relancer pour continuer)')}',
        );
      case BackfillKeys.enrichReferentials:
        final r = await _repo.backfillEnrichReferentials(
          retryExcluded: retryExcluded,
        );
        return _fromCounts(
          r,
          'Unités : scannées=${r['scannedUnits']}, enrichies=${r['enrichedUnits']}, '
          'restantes=${r['remainingUnitsWithoutWeight']}, '
          'exclues après 3 échecs=${r['excludedUnits']} | '
          'Ingrédients : scannés=${r['scannedIngredients']}, '
          'enrichis=${r['enrichedIngredients']}, échecs=${r['failedIngredients']}, '
          'exclus après 3 échecs=${r['excludedIngredients']}'
          '${(r['completed'] ?? 0) == 1 && (r['unresolvedFailures'] ?? 0) == 0 ? ' — terminé' : ' — incomplet'}'
          '${_flag(r, 'stoppedByDeadline', ' (arrêt préventif, relancer pour continuer)')}',
        );
      case BackfillKeys.refreshSodium:
        final r = await _repo.backfillEnrichReferentials(refreshSodium: true);
        return _fromCounts(
          r,
          'Ingrédients : scannés=${r['scannedIngredients']}, '
          'repris=${r['refreshedIngredients']}, échecs=${r['failedIngredients']}'
          '${(r['completed'] ?? 0) == 1 ? ' — terminé' : ' — incomplet'}'
          '${_flag(r, 'stoppedByDeadline', ' (arrêt préventif, relancer pour continuer)')}',
        );
      case BackfillKeys.allergens:
        final r = await _repo.backfillAllergens(retryExcluded: retryExcluded);
        return _fromCounts(
          r,
          'Ingrédients : examinés=${r['ingredientsExamines']}, '
          'ignorés (déjà examinés)=${r['ingredientsIgnores']}, '
          'en erreur=${r['ingredientsEnErreur']}, '
          'exclus après 3 échecs=${r['ingredientsExclus'] ?? 0}'
          '${(r['referentielParcouru'] ?? 0) == 1 ? '' : ' — référentiel pas encore parcouru en entier, recettes non recalculées'}\n'
          'Recettes : calculées=${r['recettesCalculees']}, '
          'identiques=${r['recettesIdentiques']}, '
          'encore incomplètes=${r['recettesIncompletes']}, '
          'hors recette=${r['recettesHorsRecette']}, '
          'échecs=${r['recettesEchouees']}'
          '${(r['completed'] ?? 0) == 1 && (r['echecsNonExclus'] ?? 0) == 0 ? ' — terminé' : ' — incomplet, relancer'}'
          '${_flag(r, 'stoppedByBudget', ' (quota du passage atteint)')}'
          '${_flag(r, 'stoppedByErrors', ' (trois échecs de suite : voir les rapports d\'erreurs)')}'
          '${_flag(r, 'stoppedByDeadline', ' (arrêt préventif)')}',
        );
      case BackfillKeys.recipeRoles:
        final r = await _repo.backfillRecipeRoles(retryExcluded: retryExcluded);
        return _PassOutcome(
          message: '${r.restantesSentence}\nCe passage : ${r.passSummary}',
          failures: r.failures,
          termineAuto: false,
        );
      case BackfillKeys.shoppingProducts:
        final r = await _repo.backfillShopping();
        return _fromCounts(
          r,
          'Recettes : examinées=${r['examinees']}, '
          'recalculées=${r['recalculees']}, identiques=${r['identiques']}, '
          'sans ingrédients=${r['sansIngredients']}, '
          'hors recette=${r['horsRecette']}, échecs=${r['echouees']}'
          '${(r['completed'] ?? 0) == 1 ? ' — terminé' : ' — incomplet'}'
          '${_flag(r, 'stoppedByBudget', ' (quota du passage atteint, relancer pour continuer)')}'
          '${_flag(r, 'stoppedByErrors', ' (trois échecs de suite : voir les rapports d\'erreurs)')}'
          '${_flag(r, 'stoppedByDeadline', ' (arrêt préventif, relancer pour continuer)')}',
        );
      case BackfillKeys.defaultUnits:
        final r = await _repo.backfillDefaultUnits();
        return _fromCounts(
          r,
          'Unités standard : examinées=${r['examinees']}, '
          'créées=${r['creees']}, complétées=${r['completees']}, '
          'déjà à jour=${r['dejaAJour']}, en erreur=${r['echouees']}, '
          'restantes=${r['restantes']}'
          '${(r['completed'] ?? 0) == 1 ? ' — terminé' : ' — incomplet, relancer'}'
          '${_flag(r, 'stoppedByErrors', ' (trois échecs de suite : voir les rapports d\'erreurs)')}'
          '${_flag(r, 'stoppedByDeadline', ' (arrêt préventif, relancer pour continuer)')}',
        );
      case BackfillKeys.moveMealsToGroup:
        if (move == null) throw StateError('Paramètres manquants : ${def.key}');
        final r = await _repo.backfillMoveMealsToGroup(move);
        return _fromCounts(
          r,
          'Repas : examinés=${r['examines']}, déplacés=${r['deplaces']}, '
          'ignorés (déjà dans un groupe)=${r['ignores']}, '
          'en erreur=${r['echoues']}, restants=${r['restants']}'
          '${(r['completed'] ?? 0) == 1 ? ' — terminé' : ' — incomplet, relancer'}'
          '${_flag(r, 'groupeIndisponible', ' (groupe supprimé ou cédé pendant le passage : arrêté, rien de plus n\'a été déplacé)')}'
          '${_flag(r, 'lectureTronquee', ' (plus de 2 000 repas sur la période : relancer)')}'
          '${_flag(r, 'stoppedByBudget', ' (quota du passage atteint, relancer pour continuer)')}'
          '${_flag(r, 'stoppedByErrors', ' (trois échecs de suite : voir les rapports d\'erreurs)')}'
          '${_flag(r, 'stoppedByDeadline', ' (arrêt préventif, relancer pour continuer)')}',
        );
      default:
        throw StateError('Backfill inconnu : ${def.key}');
    }
  }

  Future<bool> _confirm({
    required String title,
    required String content,
    required String confirmLabel,
  }) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        scrollable: true,
        content: Text(content),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Annuler'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text(confirmLabel),
          ),
        ],
      ),
    );
    return confirmed == true && mounted;
  }

  /// Confirmation d'un backfill qui tient une mémoire des échecs : le texte
  /// habituel, et la case « Réessayer aussi les éléments exclus après 3 échecs », décochée.
  Future<({bool ok, bool retryExcluded})> _confirmWithRetry(
    BackfillDefinition def,
  ) async {
    var retry = false;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          title: Text(def.title),
          scrollable: true,
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(_confirmText(def)),
              const SizedBox(height: 8),
              CheckboxListTile(
                value: retry,
                onChanged: (v) => setDialogState(() => retry = v ?? false),
                title: const Text(
                  'Réessayer aussi les éléments exclus après 3 échecs',
                ),
                contentPadding: EdgeInsets.zero,
                controlAffinity: ListTileControlAffinity.leading,
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: const Text('Annuler'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(ctx).pop(true),
              child: const Text('Lancer'),
            ),
          ],
        ),
      ),
    );
    return (ok: confirmed == true && mounted, retryExcluded: retry);
  }

  Future<void> _launch(BackfillDefinition def, BackfillRunState? state) async {
    if (_launching.contains(def.key)) return;
    MoveMealsRequest? move;
    if (def.key == BackfillKeys.moveMealsToGroup) {
      // Paramétré : le groupe et la période d'abord, puis le récapitulatif.
      move = await showMoveMealsToGroupDialog(context);
      if (move == null || !mounted) return;
    }
    final done = state?.isDone ?? false;
    final doneAt = state?.termineLe;
    var retryExcluded = false;
    final bool ok;
    if (move != null) {
      ok = await _confirm(
        title: move.confirmQuestion,
        content: _confirmText(def),
        confirmLabel: 'Déplacer',
      );
    } else if (done) {
      ok = await _confirm(
        title: 'Relancer « ${def.title} » ?',
        content:
            'Ce backfill est terminé'
            '${doneAt == null ? '' : ' depuis le ${formatParisDate(doneAt)}'}. '
            'Un nouveau passage ne traitera que ce qui aurait été ajouté '
            'depuis.',
        confirmLabel: 'Relancer',
      );
    } else if (_retryableKeys.contains(def.key)) {
      final answer = await _confirmWithRetry(def);
      ok = answer.ok;
      retryExcluded = answer.retryExcluded;
    } else {
      ok = await _confirm(
        title: def.title,
        content: _confirmText(def),
        confirmLabel: 'Lancer',
      );
    }
    if (!ok) return;

    setState(() => _launching.add(def.key));
    try {
      final outcome = await _runPass(
        def,
        retryExcluded: retryExcluded,
        move: move,
      );
      if (!mounted) return;
      ref.invalidate(referentialKpisProvider);
      setState(() {
        _resultMessage = outcome.message;
        _resultIsError = false;
        _failures = outcome.failures;
        _failuresTitle = def.title;
      });
      if (outcome.termineAuto) {
        context.showSuccessSnackBar(
          '« ${def.title} » est terminé : rangé en bas de la liste.',
        );
      }
    } on CallableFailure catch (e, st) {
      if (e.code == 'failed-precondition') {
        // Refus attendu, pas une panne : un passage de ce backfill, ou d'un
        // backfill qui partage ses données, tient le verrou serveur (autre
        // appareil, ou passage programmé). Le message du serveur le nomme,
        // et la tuile montre son avancement ; rien à remonter.
        if (mounted) {
          context.showSnackBar(
            '${e.message} Son résultat s\'affichera sur sa tuile.',
          );
        }
        return;
      }
      await _reportFailure(def, e, st);
    } catch (e, st) {
      await _reportFailure(def, e, st);
    } finally {
      if (mounted) setState(() => _launching.remove(def.key));
    }
  }

  Future<void> _reportFailure(
    BackfillDefinition def,
    Object error,
    StackTrace stackTrace,
  ) async {
    await _report(
      feature: 'admin_backfill_${def.key}',
      error: error,
      stackTrace: stackTrace,
      context: {'key': def.key},
    );
    if (!mounted) return;
    setState(() {
      _resultMessage = '${def.title} : ${callableFailureReason(error)}';
      _resultIsError = true;
      _failures = null;
      _failuresTitle = def.title;
    });
  }

  Future<void> _report({
    required String feature,
    required Object error,
    required StackTrace stackTrace,
    Map<String, dynamic> context = const {},
  }) async {
    try {
      await ref
          .read(errorReportServiceProvider)
          .reportError(
            feature: feature,
            error: error,
            stackTrace: stackTrace,
            context: context,
          );
    } catch (reportError, reportStack) {
      reportUnexpectedError(
        feature: 'adminBackfillsScreen.report',
        error: reportError,
        stackTrace: reportStack,
      );
    }
  }

  // ── Terminé à la main ─────────────────────────────────────────────────────

  Future<void> _setDone(
    BackfillDefinition def,
    BackfillRunState? state,
    bool done,
  ) async {
    final toReview = state?.failures?.total ?? 0;
    final ok = done
        ? await _confirm(
            title: 'Marquer « ${def.title} » comme terminé ?',
            content:
                'Il passera en bas de la liste, et restera lançable.'
                '${toReview > 0 ? ' Le dernier passage a laissé $toReview élément${toReview > 1 ? 's' : ''} à revoir.' : ''}',
            confirmLabel: 'Marquer terminé',
          )
        : await _confirm(
            title: 'Remettre « ${def.title} » à lancer ?',
            content: 'Il reviendra parmi les ponctuels à lancer.',
            confirmLabel: 'Remettre à lancer',
          );
    if (!ok) return;
    try {
      await _repo.setBackfillDone(key: def.key, done: done);
      if (!mounted) return;
      context.showSuccessSnackBar(
        done
            ? '« ${def.title} » marqué comme terminé.'
            : '« ${def.title} » remis à lancer.',
      );
    } catch (e, st) {
      await _report(
        feature: 'admin_backfill_set_done',
        error: e,
        stackTrace: st,
        context: {'key': def.key, 'done': done},
      );
      if (!mounted) return;
      context.showErrorSnackBar(
        'Changement non enregistré : ${callableFailureReason(e)}.',
      );
    }
  }

  // ── Liste des ponctuels terminés ──────────────────────────────────────────

  Future<void> _copyDoneList(
    List<BackfillDefinition> done,
    Map<String, BackfillRunState> states,
  ) async {
    try {
      await Clipboard.setData(
        ClipboardData(text: backfillDoneListText(done, states)),
      );
      if (!mounted) return;
      context.showSuccessSnackBar('Liste des ponctuels terminés copiée.');
    } catch (e, st) {
      await _report(
        feature: 'admin_backfill_copy_done_list',
        error: e,
        stackTrace: st,
      );
      if (!mounted) return;
      context.showErrorSnackBar('La liste n\'a pas pu être copiée.');
    }
  }

  // ── Programmation ─────────────────────────────────────────────────────────

  Future<void> _editSchedule(
    BackfillDefinition def,
    BackfillSchedule? current,
  ) async {
    final saved = await showBackfillScheduleEditor(
      context,
      def: def,
      current: current,
      onSave: (choice) async {
        try {
          await _repo.setBackfillSchedule(
            key: def.key,
            enabled: choice.enabled,
            days: choice.days,
            hour: choice.hour,
          );
        } catch (e, st) {
          await _report(
            feature: 'admin_backfill_schedule',
            error: e,
            stackTrace: st,
            context: {'key': def.key},
          );
          rethrow;
        }
      },
      // L'éditeur se ferme lui-même avant d'appeler ce lien.
      onOpenSpendCap: () => context.push(AppRoutes.adminAiSpend),
    );
    if (saved && mounted) {
      context.showSuccessSnackBar('Programmation enregistrée.');
    }
  }

  // ── Écran ─────────────────────────────────────────────────────────────────

  void _retryRead() {
    ref.invalidate(backfillRunsProvider);
    ref.invalidate(backfillSchedulesProvider);
  }

  @override
  Widget build(BuildContext context) {
    final runs = ref.watch(backfillRunsProvider);
    final schedulesAsync = ref.watch(backfillSchedulesProvider);
    final states = runs.value ?? const <String, BackfillRunState>{};
    final schedules = schedulesAsync.value ?? BackfillSchedules.empty;
    final readError = runs.error ?? schedulesAsync.error;
    final loading =
        readError == null && (!runs.hasValue || !schedulesAsync.hasValue);
    final runsRead = _readOf(runs);
    final schedulesRead = _readOf(schedulesAsync);
    // Les ponctuels ne se rangent qu'une fois l'état lu : sans lui, on ne sait
    // pas lesquels sont terminés, et les ranger d'abord à lancer les ferait
    // sauter d'une section à l'autre à l'arrivée des données.
    final sorted = runsRead == _Read.known;
    final sections = backfillSections(kBackfillRegistry, states);
    final ponctuels = [
      for (final def in kBackfillRegistry)
        if (!def.isRecurrent) def,
    ];

    Widget tile(BackfillDefinition def, {required bool wide}) => _BackfillCard(
      def: def,
      state: states[def.key],
      stateRead: runsRead,
      scheduleRead: schedulesRead,
      schedule: schedules.scheduleFor(def.key),
      scheduleIsDefault: schedules.isDefault(def.key),
      now: _now,
      launching: _launching.contains(def.key),
      wide: wide,
      onLaunch: () => _launch(def, states[def.key]),
      onSchedule: def.isRecurrent
          ? () => _editSchedule(def, schedules.scheduleFor(def.key))
          : null,
      onSetDone: backfillOffersDoneMenu(def, states[def.key])
          ? (done) => _setDone(def, states[def.key], done)
          : null,
      onShowFailures: (failures) => showBackfillFailuresSheet(
        context,
        title: def.title,
        failures: failures,
      ),
    );

    return Scaffold(
      appBar: AppBar(title: const Text('Backfills')),
      body: Column(
        children: [
          // Hors de la liste, pour rester visible quel que soit le défilement.
          if (_resultMessage != null)
            BackfillOperationBanner(
              isError: _resultIsError,
              message: _resultMessage ?? '',
              failures: _resultIsError ? null : _failures,
              onShowFailures: () {
                final failures = _failures;
                if (failures == null) return;
                showBackfillFailuresSheet(
                  context,
                  title: _failuresTitle,
                  failures: failures,
                );
              },
              onClose: () => setState(() {
                _resultMessage = null;
                _failures = null;
              }),
            ),
          Expanded(
            child: LayoutBuilder(
              builder: (context, constraints) {
                final wide =
                    constraints.maxWidth >= PlatformUtils.wideBreakpoint;
                Widget grid(List<BackfillDefinition> defs) => _TileGrid(
                  wide: wide,
                  children: [for (final def in defs) tile(def, wide: wide)],
                );
                return ListView(
                  padding: const EdgeInsets.all(16),
                  children: [
                    if (loading)
                      const Padding(
                        padding: EdgeInsets.only(bottom: 12),
                        child: Text('Lecture de l\'état…'),
                      ),
                    if (readError != null)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 12),
                        child: AppErrorState(
                          error: readError,
                          compact: true,
                          title: 'Impossible de lire l\'état des backfills.',
                          onRetry: _retryRead,
                        ),
                      ),
                    _SectionHeader(
                      title: 'Récurrents (${sections.recurrents.length})',
                    ),
                    grid(sections.recurrents),
                    const SizedBox(height: 24),
                    if (!sorted) ...[
                      const _SectionHeader(title: 'Ponctuels'),
                      grid(ponctuels),
                    ] else ...[
                      _SectionHeader(
                        title:
                            'Ponctuels à lancer (${sections.ponctuelsALancer.length})',
                      ),
                      if (sections.ponctuelsALancer.isEmpty)
                        const Padding(
                          padding: EdgeInsets.only(bottom: 8),
                          child: Text('Tous les ponctuels sont terminés.'),
                        )
                      else
                        grid(sections.ponctuelsALancer),
                    ],
                    if (sorted && sections.ponctuelsTermines.isNotEmpty) ...[
                      const SizedBox(height: 24),
                      _SectionHeader(
                        title:
                            'Ponctuels terminés (${sections.ponctuelsTermines.length})',
                        expanded: _termineesExpanded,
                        onToggle: () => setState(
                          () => _termineesExpanded = !_termineesExpanded,
                        ),
                      ),
                      // Le texte que la session de retrait demande : une
                      // ligne par ponctuel terminé, sans capture d'écran.
                      Align(
                        alignment: AlignmentDirectional.centerStart,
                        child: TextButton.icon(
                          style: TextButton.styleFrom(
                            minimumSize: const Size(48, 48),
                          ),
                          icon: const Icon(Icons.copy_outlined),
                          label: const Text('Copier la liste'),
                          onPressed: () =>
                              _copyDoneList(sections.ponctuelsTermines, states),
                        ),
                      ),
                      const SizedBox(height: 8),
                      if (_termineesExpanded) grid(sections.ponctuelsTermines),
                    ],
                  ],
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  // Dix-huit opérations ont quitté cet écran, et le code derrière elles avec.
  //
  // « Amorcer les droits utilisateurs » rattrapait les comptes créés avant que
  // le déclencheur `syncUserClaims` n'existe. Ce déclencheur écrit désormais les
  // claims à chaque écriture d'un document utilisateur, création comprise : il
  // ne reste aucun compte à rattraper, et un compte qui en aurait besoin se
  // répare en changeant son rôle depuis l'écran Utilisateurs.
  //
  // « Amorcer les poids à la pièce » versait la table intégrée dans le
  // référentiel. Le versement a eu lieu ; la table reste consultée comme filet
  // par `pieceWeightForIngredient`, donc son retrait de cet écran ne fait rien
  // disparaître du calcul.
  //
  // « Auditer les identifiants d'ingrédients » réparait les documents rendus
  // inatteignables par un changement de la règle de normalisation — celui des
  // ligatures, où « œuf » produisait « uf ». La règle n'a pas rebougé, et les
  // écritures passent toutes par le même normalisateur : l'audit n'a plus rien
  // à constater. Si la règle change à nouveau, l'outil se retrouve dans
  // l'historique git, écrit pour cette occasion-là.
  //
  // « Reprendre la confidentialité des livres » (`backfillBookPrivacyFn`) a posé
  // `is_private` sur les livres antérieurs au champ. Lancée en production,
  // retirée en v0.23.14 (10 octobre 2026) : son travail est fait.
  //
  // « Reprendre la confidentialité » a posé `is_private` sur tout le fonds
  // antérieur au champ. Passée au complet le 5 octobre 2026 — la politique IAM
  // qui la rendait inappelable venait d'être corrigée le même jour. Toute
  // recette écrite depuis porte le champ dès sa création.
  //
  // « Produit acheté des ingrédients » (mode `aliases` de la reprise de la
  // liste de courses) a demandé au modèle le produit acheté de chaque
  // ingrédient antérieur du référentiel qui n'en avait pas. Passée au complet.
  // Un ingrédient neuf le reçoit désormais seul, à l'import ; `products` —
  // le recalcul de `shopping_products` sur les recettes, lui, reste réutilisé
  // à chaque changement de règle de regroupement.
  //
  // « Rattacher les recettes sans livre » ne faisait que rendre compte d'un
  // traitement qui tourne déjà seul à chaque ouverture de la bibliothèque
  // (`ensureSystemBooks` → `migrateLibresRecipes`, `book_repository.dart`).
  // Ce traitement automatique reste en place ; seul le bouton de contrôle
  // manuel a disparu.
  //
  // « Semer les garnitures simples » versait `kDefaultMealStaples` dans
  // `meal_staples/*`. Le versement a eu lieu ; la constante n'avait plus
  // d'autre lecteur, elle a quitté `meal_staple.dart` avec sa méthode de
  // semis et son test dédié.
  //
  // « Corriger les tarifs » appliquait à Firestore une table de tarifs
  // MESURÉS mais écrite en dur dans le code (`PRICING_CORRECTIONS`,
  // `ai/pricing.ts`) — la correction déjà posée. Une dérive de tarif future
  // se corrige directement depuis Admin › Moteur d'IA (`setAiPricingFn`),
  // qui écrit le même document sans dupliquer aucun chiffre dans le code.
  //
  // Trois ponctuels, menés au bout et marqués terminés en production, sont
  // retirés en v0.23.52 (13 octobre 2026) :
  //
  // « Protéine et féculent des plats » (`backfillRecipeProteinFn`, v0.23.24) a
  // posé `tags.main_protein` et `tags.main_starch` sur les plats et
  // accompagnements déjà classés. Le classement à l'écriture
  // (`onRecipeWritten`) et l'import les posent sur toute recette neuve.
  //
  // « Durées estimées » (`backfillEstimatedTimesFn`, v0.23.38) a estimé la
  // préparation et la cuisson des recettes qui n'en donnaient pas. Le
  // déclencheur `onRecipeWritten` (`recipeEstimatedTimes.ts`) estime une
  // recette neuve ou modifiée.
  //
  // « Contraintes de variété par défaut » (`backfillPlanningDefaultsFn`,
  // v0.23.28) a posé `kDefaultGlobalConstraints` dans les contraintes du
  // planning des comptes existants. Un compte sans contraintes enregistrées
  // lit ce texte par défaut (`PlanningPreferences.fromFirestore`).
  //
  // Leurs documents `app_config/backfill_run_<clé>` et leurs curseurs restent
  // en base : l'écran ignore une clé absente du registre.
  //
  // Six ponctuels, menés au bout et marqués terminés en production, sont
  // retirés en v0.24.33 (20 octobre 2026) :
  //
  // « Livres système des comptes » (`backfillSystemBooksFn`, terminé le 13/10
  // en v0.23.51) a créé les livres système manquants des comptes approuvés.
  // `syncUserClaims` les crée à l'approbation d'un compte.
  //
  // « Portée des groupes et des plannings » (`backfillGroupPlanningReachFn`,
  // terminé le 13/10 en v0.23.58) a recalculé `group_reach` et
  // `planning_reach` des membres et marqué personnels les repas antérieurs.
  // `syncGroupReach` et `syncPlanningReachOnRole` les tiennent à jour.
  //
  // « Analyses des tickets » (`backfillTicketAnalysesFn`, terminé le 14/10 en
  // v0.23.63) a relevé sur GitHub les analyses déjà publiées. Le webhook et la
  // tâche horaire des tickets les relisent.
  //
  // « Clé de titre des recettes » (`backfillTitleKeysFn`, terminé le 17/10 en
  // v0.23.97) a posé `titre_key` sur les recettes antérieures. L'import et
  // `onRecipeWritten` la posent sur toute recette écrite.
  //
  // « PR des tickets livrés » (`backfillTicketDeliveredPrFn`, terminé le
  // 17/10 en v0.23.99) a retrouvé la PR de chaque ticket déjà livré. Le
  // webhook et la tâche horaire l'enregistrent à la livraison.
  //
  // « Propriétaire du groupe des invitations »
  // (`backfillInvitationGroupOwnerFn`, terminé le 19/10 en v0.24.14) a posé
  // `group_owner_id` sur les invitations par e-mail antérieures.
  // `manageInvitationFn` l'écrit à la création et au renvoi.
  //
  // Deux ponctuels, menés au bout et marqués terminés en production le
  // 21/10 en v0.24.36, sont retirés en v0.24.37 (21 octobre 2026) :
  //
  // « Dossiers des illustrations » (`backfillIllustrationFoldersFn`) a
  // contrôlé, sans rien écrire, que les illustrations et vignettes des
  // recettes sont sous `illustrations/` ou `recipes/` du bucket, et enregistré
  // la liste des images hors de ces dossiers. Dernier passage : 616 recettes
  // examinées, 616 conformes, 0 à revoir.
  //
  // « Ranger les illustrations » (`backfillIllustrationFoldersMoveFn`) a copié
  // ces images sous `recipes/{id}/`, les a inscrites dans `image_moderation`
  // comme publiées par décision d'un administrateur (`manual_folder_move`),
  // a réécrit les recettes et supprimé les anciens fichiers que plus rien ne
  // citait. Dernier passage : 18 recettes rangées, 0 restante, 92 anciens
  // fichiers conservés car encore cités.
  //
  // Depuis v0.23.45, chaque backfill est classé ponctuel ou récurrent
  // (`backfill_registry.dart`, `functions/src/backfills/registry.ts`). Un
  // ponctuel terminé reste visible en bas de l'écran jusqu'à son retrait du
  // code, qui laisse ici un paragraphe daté comme ceux ci-dessus.
}

/// En-tête de section, pleine largeur. [onToggle] la rend repliable.
class _SectionHeader extends StatelessWidget {
  final String title;
  final bool expanded;
  final VoidCallback? onToggle;

  const _SectionHeader({
    required this.title,
    this.expanded = true,
    this.onToggle,
  });

  @override
  Widget build(BuildContext context) {
    final style = Theme.of(context).textTheme.titleMedium;
    final text = Semantics(header: true, child: Text(title, style: style));
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: onToggle == null
          ? text
          : Semantics(
              button: true,
              expanded: expanded,
              child: InkWell(
                onTap: onToggle,
                borderRadius: BorderRadius.circular(8),
                child: SizedBox(
                  height: 48,
                  child: Row(
                    children: [
                      Expanded(child: text),
                      ExcludeSemantics(
                        child: Icon(
                          expanded ? Icons.expand_less : Icons.expand_more,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
    );
  }
}

/// Une colonne sur téléphone, deux au-delà de `PlatformUtils.wideBreakpoint`.
class _TileGrid extends StatelessWidget {
  final bool wide;
  final List<Widget> children;

  const _TileGrid({required this.wide, required this.children});

  @override
  Widget build(BuildContext context) {
    const gap = 12.0;
    if (!wide) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final child in children)
            Padding(
              padding: const EdgeInsets.only(bottom: gap),
              child: child,
            ),
        ],
      );
    }
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = (constraints.maxWidth - gap) / 2;
        return Wrap(
          spacing: gap,
          runSpacing: gap,
          children: [
            for (final child in children) SizedBox(width: width, child: child),
          ],
        );
      },
    );
  }
}

enum _TileAction { markDone, unmarkDone }

/// Ce que l'écran sait d'une lecture Firestore : en cours, en échec, lue.
enum _Read { loading, error, known }

_Read _readOf(AsyncValue<Object?> value) => value.hasError
    ? _Read.error
    : value.hasValue
    ? _Read.known
    : _Read.loading;

/// Tuile d'un backfill : état, programmation, actions.
class _BackfillCard extends StatefulWidget {
  final BackfillDefinition def;
  final BackfillRunState? state;

  /// Lecture de l'état : « … » pendant le chargement, « État inconnu » en
  /// erreur.
  final _Read stateRead;

  /// Lecture de la programmation, même règle.
  final _Read scheduleRead;
  final BackfillSchedule? schedule;

  /// La programmation vient du défaut du registre, pas du document.
  final bool scheduleIsDefault;
  final DateTime now;
  final bool launching;
  final bool wide;
  final VoidCallback onLaunch;
  final VoidCallback? onSchedule;
  final void Function(bool done)? onSetDone;
  final void Function(BackfillFailures failures) onShowFailures;

  const _BackfillCard({
    required this.def,
    required this.state,
    required this.stateRead,
    required this.scheduleRead,
    required this.schedule,
    required this.scheduleIsDefault,
    required this.now,
    required this.launching,
    required this.wide,
    required this.onLaunch,
    required this.onSchedule,
    required this.onSetDone,
    required this.onShowFailures,
  });

  @override
  State<_BackfillCard> createState() => _BackfillCardState();
}

class _BackfillCardState extends State<_BackfillCard> {
  bool _hovered = false;

  static const _icons = <String, IconData>{
    BackfillKeys.nutrition: Icons.restore_outlined,
    BackfillKeys.enrichReferentials: Icons.auto_awesome_outlined,
    BackfillKeys.allergens: Icons.no_food_outlined,
    BackfillKeys.recipeRoles: Icons.restaurant_outlined,
    BackfillKeys.shoppingProducts: Icons.shopping_cart_outlined,
    BackfillKeys.refreshSodium: Icons.science_outlined,
    BackfillKeys.defaultUnits: Icons.straighten_outlined,
    BackfillKeys.moveMealsToGroup: Icons.move_down_outlined,
  };

  bool get _done => widget.state?.isDone ?? false;

  /// Un passage tourne (lancé d'ici, ou lu en cours dans l'état).
  bool get _running =>
      widget.launching ||
      widget.state?.status(widget.now) == BackfillRunStatus.enCours;

  List<PopupMenuEntry<_TileAction>> _menuItems() => [
    if (_done)
      const PopupMenuItem(
        value: _TileAction.unmarkDone,
        child: Text('Remettre à lancer'),
      )
    else
      // Pas pendant un passage : son issue pourrait contredire la marque.
      PopupMenuItem(
        value: _TileAction.markDone,
        enabled: !_running,
        child: Text(
          _running
              ? 'Marquer comme terminé (passage en cours)'
              : 'Marquer comme terminé',
        ),
      ),
  ];

  void _onMenu(_TileAction action) {
    widget.onSetDone?.call(action == _TileAction.markDone);
  }

  Future<void> _showContextMenu(Offset position) async {
    if (widget.onSetDone == null) return;
    final overlay =
        Overlay.of(context).context.findRenderObject() as RenderBox?;
    if (overlay == null) return;
    final action = await showMenu<_TileAction>(
      context: context,
      position: RelativeRect.fromRect(
        position & const Size(1, 1),
        Offset.zero & overlay.size,
      ),
      items: _menuItems(),
    );
    if (action != null) _onMenu(action);
  }

  /// L'icône double le texte de l'état, qui le dit en toutes lettres : la
  /// couleur seule ne porte jamais l'information.
  IconData _statusIcon(BackfillRunStatus status) => switch (status) {
    BackfillRunStatus.jamais => Icons.history,
    BackfillRunStatus.enCours => Icons.sync,
    BackfillRunStatus.termine => Icons.check_circle_outline,
    BackfillRunStatus.incomplet => Icons.warning_amber_outlined,
    BackfillRunStatus.erreur => Icons.error_outline,
    BackfillRunStatus.interrompu => Icons.error_outline,
  };

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final def = widget.def;
    final state = widget.state;
    final done = _done;
    final muted = scheme.onSurfaceVariant;
    final status = state?.status(widget.now) ?? BackfillRunStatus.jamais;
    final running = _running;
    final failures = state?.failures;
    final linkLabel = backfillFailuresLinkLabel(failures);
    final bodyStyle = theme.textTheme.bodyMedium?.copyWith(
      color: done ? muted : null,
    );

    final statusText = switch (widget.stateRead) {
      _Read.loading => '…',
      _Read.error => 'État inconnu',
      _Read.known =>
        widget.launching && status != BackfillRunStatus.enCours
            ? 'Passage lancé, en attente du serveur…'
            : backfillStatusLine(
                def: def,
                state: state,
                schedule: widget.schedule,
                now: widget.now,
              ),
    };
    final statusIcon = widget.launching
        ? Icons.sync
        : widget.stateRead == _Read.known
        ? _statusIcon(status)
        : Icons.more_horiz;
    final scheduleText = switch (widget.scheduleRead) {
      _Read.loading => '…',
      _Read.error => 'inconnue',
      _Read.known => backfillScheduleLabel(
        widget.schedule,
        isDefault: widget.scheduleIsDefault,
      ),
    };

    final actions = <Widget>[
      if (running)
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 12),
          child: Text('Passage en cours', style: bodyStyle),
        )
      else if (done)
        TextButton(
          onPressed: widget.onLaunch,
          child: const Text('Relancer quand même'),
        )
      else
        FilledButton.tonal(
          onPressed: widget.onLaunch,
          child: const Text('Lancer'),
        ),
      if (widget.onSchedule != null)
        TextButton.icon(
          onPressed: widget.onSchedule,
          icon: const Icon(Icons.schedule),
          label: const Text('Programmer'),
        ),
      if (widget.onSetDone != null)
        PopupMenuButton<_TileAction>(
          tooltip: 'Plus d\'actions',
          icon: const Icon(Icons.more_vert),
          onSelected: _onMenu,
          itemBuilder: (_) => _menuItems(),
        ),
    ];

    final card = Card(
      elevation: widget.wide && _hovered ? 4 : 1,
      color: done ? scheme.surfaceContainerLow : null,
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 8, 4),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(_icons[def.key] ?? Icons.build_outlined, color: muted),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    def.title,
                    style: theme.textTheme.titleSmall?.copyWith(
                      color: done ? muted : null,
                    ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: Chip(
                    visualDensity: VisualDensity.compact,
                    avatar: Icon(
                      def.usesAi
                          ? Icons.payments_outlined
                          : Icons.money_off_outlined,
                      size: AppIconSize.small,
                    ),
                    label: Text(def.usesAi ? 'IA' : 'Sans IA'),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: Text(def.description, style: bodyStyle),
            ),
            const SizedBox(height: 8),
            if (def.isRecurrent)
              _InfoLine(
                icon: Icons.event_repeat_outlined,
                text: 'Programmation : $scheduleText',
                color: muted,
              ),
            if (done)
              _InfoLine(
                icon: Icons.task_alt,
                text: backfillDoneLine(state!),
                color: muted,
              ),
            if (!done)
              _InfoLine(icon: statusIcon, text: statusText)
            else if (state?.dernierPassageLe != null)
              _InfoLine(
                icon: statusIcon,
                text: 'Dernier passage — ${_lowerFirst(statusText)}',
                color: muted,
              ),
            if (running)
              const Padding(
                padding: EdgeInsets.only(top: 8, right: 8),
                child: LinearProgressIndicator(),
              ),
            if (linkLabel != null && failures != null && !running)
              TextButton(
                style: TextButton.styleFrom(
                  padding: EdgeInsets.zero,
                  minimumSize: const Size(0, 48),
                  alignment: Alignment.centerLeft,
                ),
                onPressed: () => widget.onShowFailures(failures),
                child: Text(linkLabel),
              ),
            Align(
              alignment: Alignment.centerRight,
              child: OverflowBar(spacing: 4, children: actions),
            ),
          ],
        ),
      ),
    );

    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        // Clic droit : le même menu que ⋮, à l'endroit du clic.
        onSecondaryTapDown: (details) =>
            _showContextMenu(details.globalPosition),
        child: card,
      ),
    );
  }
}

String _lowerFirst(String text) =>
    text.isEmpty ? text : '${text[0].toLowerCase()}${text.substring(1)}';

class _InfoLine extends StatelessWidget {
  final IconData icon;
  final String text;
  final Color? color;

  const _InfoLine({required this.icon, required this.text, this.color});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 4, right: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Icon(
              icon,
              size: AppIconSize.small,
              color: color ?? theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              text,
              style: theme.textTheme.bodyMedium?.copyWith(color: color),
            ),
          ),
        ],
      ),
    );
  }
}

/// Libellé du lien vers la liste « à revoir », ou `null` quand il n'y a
/// rien à montrer : aucun élément, ou une liste vide malgré un total.
String? backfillFailuresLinkLabel(BackfillFailures? failures) {
  if (failures == null || failures.total <= 0 || failures.items.isEmpty) {
    return null;
  }
  if (failures.truncated) {
    return 'Voir les ${failures.items.length} premiers sur '
        '${failures.total} à revoir';
  }
  if (failures.total == 1) return 'Voir l\'élément à revoir';
  return 'Voir les ${failures.total} à revoir';
}

/// Bannière de compte rendu d'un backfill, au-dessus de la liste des tuiles.
///
/// Avec des éléments à revoir, l'icône passe à l'avertissement et un lien
/// ouvre la feuille qui les nomme.
class BackfillOperationBanner extends StatelessWidget {
  final bool isError;
  final String message;
  final BackfillFailures? failures;
  final VoidCallback onShowFailures;
  final VoidCallback onClose;

  const BackfillOperationBanner({
    super.key,
    required this.isError,
    required this.message,
    required this.failures,
    required this.onShowFailures,
    required this.onClose,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final bg = isError
        ? theme.colorScheme.errorContainer
        : theme.colorScheme.secondaryContainer;
    final fg = isError
        ? theme.colorScheme.onErrorContainer
        : theme.colorScheme.onSecondaryContainer;
    final toReview = !isError && (failures?.total ?? 0) > 0;
    final linkLabel = isError ? null : backfillFailuresLinkLabel(failures);
    final detailMissing = toReview && linkLabel == null;

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
      child: Material(
        color: bg,
        borderRadius: BorderRadius.circular(10),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(
                isError
                    ? Icons.error_outline
                    : toReview
                    ? Icons.warning_amber_outlined
                    : Icons.check_circle_outline,
                color: fg,
                size: AppIconSize.small,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      detailMissing
                          ? '$message\nDétail indisponible pour cette opération.'
                          : message,
                      style: theme.textTheme.bodyMedium?.copyWith(color: fg),
                    ),
                    if (linkLabel != null)
                      TextButton(
                        style: TextButton.styleFrom(
                          foregroundColor: fg,
                          minimumSize: const Size(0, 48),
                          padding: EdgeInsets.zero,
                          alignment: Alignment.centerLeft,
                        ),
                        onPressed: onShowFailures,
                        child: Text(linkLabel),
                      ),
                  ],
                ),
              ),
              IconButton(
                tooltip: 'Fermer',
                onPressed: onClose,
                icon: Icon(Icons.close, color: fg, size: AppIconSize.small),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
