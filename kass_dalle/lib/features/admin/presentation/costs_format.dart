import 'package:intl/intl.dart';

/// Mise en forme des montants et des volumes de la comptabilité.
///
/// Le compte est belge : les montants s'affichent en euros, avec la virgule
/// pour les décimales et un séparateur de milliers. Les fournisseurs facturent
/// en dollars — la conversion se fait au taux du mois concerné, celui que
/// Google a lui-même appliqué à sa facture, jamais un taux unique plaqué sur
/// tout l'historique.

const _locale = 'fr_BE';

final _integer = NumberFormat.decimalPattern(_locale);
final _twoDecimals = NumberFormat.decimalPatternDigits(
  locale: _locale,
  decimalDigits: 2,
);
final _fourDecimals = NumberFormat.decimalPatternDigits(
  locale: _locale,
  decimalDigits: 4,
);

/// Un entier avec séparateur de milliers : `1 284 306`.
String formatCount(num value) => _integer.format(value);

/// Un montant en euros, converti depuis les dollars au taux fourni.
///
/// Les petits montants gardent quatre décimales : à deux, la majorité des
/// appels d'IA s'afficherait « 0,00 € », ce qui revient à prétendre qu'ils sont
/// gratuits. Sans taux connu, le dollar est affiché tel quel plutôt que
/// converti au hasard — un montant faux vaut moins qu'un montant étranger.
String formatMoney(double usd, double usdToEur, {bool forceDecimals = false}) {
  if (usdToEur <= 0) return '${_amount(usd, forceDecimals)} \$';
  return formatEur(usd * usdToEur, forceDecimals: forceDecimals);
}

/// Un montant déjà exprimé en euros.
///
/// Sert aux agrégations qui traversent plusieurs mois : chaque mois est
/// converti à son propre taux avant d'être additionné, faute de quoi la somme
/// s'obtiendrait en appliquant le cours d'aujourd'hui à des dépenses passées.
String formatEur(double eur, {bool forceDecimals = false}) =>
    '${_amount(eur, forceDecimals)} €';

/// Le même montant, suivi de sa valeur d'origine en dollars.
///
/// Réservé aux totaux : c'est là que la question « d'où vient ce chiffre ? »
/// se pose, et le montant facturé par le fournisseur est en dollars.
String formatMoneyWithSource(double usd, double usdToEur) {
  if (usdToEur <= 0) return '${_amount(usd, false)} \$';
  return '${_amount(usd * usdToEur, false)} € (${_amount(usd, false)} \$)';
}

String _amount(double value, bool forceDecimals) {
  final magnitude = value.abs();
  if (!forceDecimals && magnitude > 0 && magnitude < 1) {
    return _fourDecimals.format(value);
  }
  return _twoDecimals.format(value);
}

/// Un taux de conversion, à quatre décimales : `0,8612`.
String formatRate(double rate) => _fourDecimals.format(rate);

/// Un pourcentage signé : `+9,7 %`, `−3,2 %`.
String formatSignedPercent(double ratio) {
  final percent = _twoDecimals.format(ratio.abs() * 100);
  final sign = ratio < 0 ? '−' : '+';
  return '$sign$percent %';
}

// ── Empreinte énergétique ────────────────────────────────────────────────────

/// Énergie consommée par jeton, en Wh.
///
/// Ordre de grandeur publié pour l'inférence d'un grand modèle de langage :
/// ~0,001 Wh pour mille jetons. C'est une estimation, pas une mesure — aucun
/// fournisseur ne facture l'électricité au jeton. Elle vaut mieux qu'un écran
/// muet sur la question : une consommation qu'on ne regarde jamais est une
/// consommation qui ne baisse jamais.
const double whPerToken = 0.000001;

double estimateWh(int tokens) => tokens * whPerToken;

/// L'énergie estimée, dans l'unité qui la rend lisible.
String formatEnergy(int tokens) {
  final wh = estimateWh(tokens);
  if (wh < 0.001) return '≈ ${_twoDecimals.format(wh * 1000000)} µWh';
  if (wh < 1) return '≈ ${_twoDecimals.format(wh * 1000)} mWh';
  if (wh < 1000) return '≈ ${_fourDecimals.format(wh)} Wh';
  return '≈ ${_fourDecimals.format(wh / 1000)} kWh';
}

/// L'énergie estimée, toujours exprimée en kWh.
///
/// Utile quand plusieurs lignes doivent se comparer d'un coup d'œil : une
/// colonne qui change d'unité d'une ligne à l'autre ne se compare pas.
String formatEnergyKwh(int tokens) {
  final kwh = estimateWh(tokens) / 1000;
  if (kwh == 0) return '0 kWh';
  if (kwh < 0.000001) return '< 0,000001 kWh';
  return '${NumberFormat.decimalPatternDigits(locale: _locale, decimalDigits: 6).format(kwh)} kWh';
}
