import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/ai_reconciliation_repository.dart';
import '../data/backfill_reports_repository.dart';
import '../data/currency_rate_repository.dart';
import '../data/gcp_billing_repository.dart';
import '../domain/ai_reconciliation_report.dart';
import '../domain/recipe_roles_backfill_report.dart';

// ── Repository providers ───────────────────────────────────────────────────────

final gcpBillingRepositoryProvider = Provider<GcpBillingRepository>(
  (ref) => GcpBillingRepository(),
);

final aiReconciliationRepositoryProvider = Provider<AiReconciliationRepository>(
  (ref) => AiReconciliationRepository(),
);

final currencyRateRepositoryProvider = Provider<CurrencyRateRepository>(
  (ref) => CurrencyRateRepository(),
);

/// Taux USD → EUR en vigueur, relevé chaque mois par la réconciliation sur la
/// facturation elle-même. `null` tant qu'aucun taux n'a été relevé.
///
/// Il n'y a pas de taux de repli : un cours figé dans le code donnerait des
/// euros calculés sur une valeur périmée, affichés comme s'ils étaient justes.
/// Sans taux, les montants restent en dollars — voir `formatMoney`.
final currencyRateProvider = FutureProvider<CurrencyRate?>((ref) async {
  return ref.watch(currencyRateRepositoryProvider).fetch();
});

// ── Utilitaires d'affichage ────────────────────────────────────────────────────

String billingFmtInt(int n) {
  final s = n.toString();
  final buf = StringBuffer();
  for (var i = 0; i < s.length; i++) {
    if (i > 0 && (s.length - i) % 3 == 0) buf.write('\u202f');
    buf.write(s[i]);
  }
  return buf.toString();
}

String billingFmtEur(double v) => '${v.toStringAsFixed(v < 1 ? 4 : 2)} €';
String billingFmtUsd(double v) => '\$${v.toStringAsFixed(v < 1 ? 4 : 2)}';

// ── Réconciliation des coûts IA ───────────────────────────────────────────────

/// Période (`YYYY-MM`) dont on regarde la réconciliation.
///
/// Par défaut le mois précédent, et non le mois en cours : c'est celui que la
/// tâche planifiée a réconcilié, et le seul dont la facturation Google soit
/// consolidée. Un rapport sur le mois courant compare un traçage partiel à une
/// facturation partielle.
class ReconciliationPeriodNotifier extends Notifier<String> {
  @override
  String build() {
    final now = DateTime.now().toUtc();
    return AiReconciliationRepository.periodId(
      DateTime.utc(now.year, now.month - 1, 1),
    );
  }

  void set(String period) => state = period;
}

final reconciliationPeriodProvider =
    NotifierProvider<ReconciliationPeriodNotifier, String>(
      ReconciliationPeriodNotifier.new,
    );

/// Rapport de la période sélectionnée. `null` tant qu'il n'a pas été produit.
final aiReconciliationProvider = StreamProvider.autoDispose
    .family<AiReconciliationReport?, String>((ref, period) {
      return ref.watch(aiReconciliationRepositoryProvider).watch(period);
    });

/// Les douze derniers mois réconciliés — sert à peupler le sélecteur.
final recentReconciliationsProvider =
    FutureProvider.autoDispose<List<AiReconciliationReport>>((ref) async {
      return ref.watch(aiReconciliationRepositoryProvider).recent();
    });

/// KPIs courants de normalisation des référentiels (chargés à la demande).
final referentialKpisProvider = FutureProvider.autoDispose<Map<String, int>>((
  ref,
) async {
  return ref.read(gcpBillingRepositoryProvider).getRecipeReferentialKpis();
});

final backfillReportsRepositoryProvider = Provider<BackfillReportsRepository>(
  (ref) => BackfillReportsRepository(),
);

/// Dernier compte rendu du backfill « Rôle des recettes dans un repas », lu
/// en continu depuis son point de contrôle. `null` tant qu'aucun passage n'a
/// fini. Sert à qui a quitté l'écran avant la fin d'un passage, et à dire
/// combien de recettes restent à classer avant d'en lancer un autre.
final recipeRolesBackfillReportProvider =
    StreamProvider.autoDispose<RecipeRolesBackfillReport?>((ref) {
      return ref
          .watch(backfillReportsRepositoryProvider)
          .watchRecipeRolesReport();
    });
