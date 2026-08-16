import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';

import '../../../core/services/error_report_service.dart';

/// Taux USD → euro en vigueur, relevé sur la facturation réelle.
///
/// La grille tarifaire Gemini est en dollars, la facture Google en euros :
/// convertir demande un taux. Le figer dans le code revenait à afficher, des
/// mois durant, des montants en euros calculés sur un taux périmé — sans qu'aucun
/// écran ne signale quoi que ce soit.
///
/// Le taux est désormais relevé par la réconciliation mensuelle depuis
/// `currency_conversion_rate` de l'export de facturation, c'est-à-dire depuis le
/// taux que Google a lui-même appliqué, et déposé dans `app_config/currency_rate`.
class CurrencyRate {
  final double usdToEur;

  /// Devise du compte de facturation d'où vient le taux.
  final String currency;

  /// Mois (`YYYY-MM`) sur lequel le taux a été relevé.
  final String? sourcePeriod;

  final DateTime? updatedAt;

  const CurrencyRate({
    required this.usdToEur,
    required this.currency,
    required this.sourcePeriod,
    required this.updatedAt,
  });
}

class CurrencyRateRepository {
  static const String docId = 'currency_rate';

  final FirebaseFirestore _firestore;
  final ErrorReportService _errorReportService;

  CurrencyRateRepository({
    FirebaseFirestore? firestore,
    ErrorReportService? errorReportService,
  }) : _firestore = firestore ?? FirebaseFirestore.instance,
       _errorReportService = errorReportService ?? ErrorReportService();

  /// Lit le taux en vigueur, ou `null` s'il n'y en a pas.
  ///
  /// **Aucun repli.** Un taux figé dans le code appliqué à la place du taux réel
  /// donnerait des euros calculés sur un cours périmé, affichés comme s'ils
  /// étaient justes — la même panne silencieuse que les prix. Sans taux, les
  /// montants restent en dollars, ce qui est vrai (voir `formatMoney`).
  Future<CurrencyRate?> fetch() async {
    try {
      final snap = await _firestore.collection('app_config').doc(docId).get();

      final data = snap.data();
      if (data == null) return null;

      final rate = (data['usd_to_account_rate'] as num?)?.toDouble();

      // Le backend borne déjà le taux avant de l'écrire ; on revalide ici parce
      // qu'un document Firestore peut aussi avoir été édité à la main. La devise
      // doit être l'euro : ce taux ne sert qu'à afficher des euros, et un taux
      // vers une autre monnaie appliqué tel quel donnerait des montants faux
      // sans que rien ne le signale.
      if (rate == null ||
          !rate.isFinite ||
          rate <= 0 ||
          data['currency'] != 'EUR') {
        return null;
      }
      const currency = 'EUR';

      final updatedAt = data['updated_at'];
      return CurrencyRate(
        usdToEur: rate,
        currency: currency,
        sourcePeriod: data['source_period'] as String?,
        updatedAt: updatedAt is Timestamp ? updatedAt.toDate() : null,
      );
    } catch (error, stackTrace) {
      unawaited(
        _errorReportService.reportError(
          feature: 'admin.currencyRate',
          error: error,
          stackTrace: stackTrace,
          context: {'doc': docId},
        ),
      );
      return null;
    }
  }
}
