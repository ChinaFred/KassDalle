import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/ai_reconciliation_repository.dart';
import '../data/billing_repository.dart';
import '../data/currency_rate_repository.dart';
import '../data/gcp_billing_repository.dart';
import '../domain/ai_reconciliation_report.dart';

// ── Repository providers ───────────────────────────────────────────────────────

final billingRepositoryProvider = Provider<BillingRepository>(
  (ref) => BillingRepository(),
);

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
/// facturation elle-même. Tous les montants en euros d'un même écran passent par
/// lui : deux taux différents sur un même tableau ne se verraient pas.
final currencyRateProvider = FutureProvider<CurrencyRate>((ref) async {
  return ref.watch(currencyRateRepositoryProvider).fetch();
});

// ── Notifier + providers période ──────────────────────────────────────────────

class BillingPeriodNotifier extends Notifier<BillingPeriod> {
  @override
  BillingPeriod build() => BillingPeriod.buildPresets().first;

  void set(BillingPeriod period) => state = period;
}

final billingPeriodProvider =
    NotifierProvider<BillingPeriodNotifier, BillingPeriod>(
      BillingPeriodNotifier.new,
    );

final billingReportProvider = FutureProvider.autoDispose<BillingReport>((
  ref,
) async {
  final period = ref.watch(billingPeriodProvider);
  final rate = await ref.watch(currencyRateProvider.future);
  return ref
      .watch(billingRepositoryProvider)
      .fetchReport(period, usdToEur: rate.usdToEur);
});

final gcpCostsReportProvider = FutureProvider.autoDispose<GcpCostsReport>((
  ref,
) async {
  final period = ref.watch(billingPeriodProvider);
  final rate = await ref.watch(currencyRateProvider.future);
  return ref
      .watch(gcpBillingRepositoryProvider)
      .fetchCosts(
        start: period.start,
        end: period.end,
        usdToEur: rate.usdToEur,
      );
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
