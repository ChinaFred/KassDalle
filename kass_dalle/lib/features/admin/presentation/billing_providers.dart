import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/billing_repository.dart';
import '../data/gcp_billing_repository.dart';

// ── Repository providers ───────────────────────────────────────────────────────

final billingRepositoryProvider = Provider<BillingRepository>(
  (ref) => BillingRepository(),
);

final gcpBillingRepositoryProvider = Provider<GcpBillingRepository>(
  (ref) => GcpBillingRepository(),
);

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
  return ref.watch(billingRepositoryProvider).fetchReport(period);
});

final gcpCostsReportProvider = FutureProvider.autoDispose<GcpCostsReport>((
  ref,
) async {
  final period = ref.watch(billingPeriodProvider);
  return ref
      .watch(gcpBillingRepositoryProvider)
      .fetchCosts(start: period.start, end: period.end);
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
