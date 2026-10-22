/// Nom français d'une langue, à partir de son code ISO 639-1.
///
/// Deux formes par langue, écrites à la main : le nom (« anglais ») et la forme
/// avec « de » (« de l'anglais », « du japonais »). Une règle d'élision se
/// tromperait sur « hébreu » ou « hindi » ; la table, elle, se relit.
///
/// Ni `intl` ni `flutter_localizations` ne donnent les noms de langues.
library;

const _languageNames = <String, (String, String)>{
  'en': ('anglais', "de l'anglais"),
  'es': ('espagnol', "de l'espagnol"),
  'it': ('italien', "de l'italien"),
  'de': ('allemand', "de l'allemand"),
  'pt': ('portugais', 'du portugais'),
  'nl': ('néerlandais', 'du néerlandais'),
  'ja': ('japonais', 'du japonais'),
  'zh': ('chinois', 'du chinois'),
  'ko': ('coréen', 'du coréen'),
  'th': ('thaï', 'du thaï'),
  'vi': ('vietnamien', 'du vietnamien'),
  'ar': ('arabe', "de l'arabe"),
  'he': ('hébreu', "de l'hébreu"),
  'fa': ('persan', 'du persan'),
  'tr': ('turc', 'du turc'),
  'el': ('grec', 'du grec'),
  'ru': ('russe', 'du russe'),
  'pl': ('polonais', 'du polonais'),
  'sv': ('suédois', 'du suédois'),
  'da': ('danois', 'du danois'),
  'no': ('norvégien', 'du norvégien'),
  'nb': ('norvégien', 'du norvégien'),
  'fi': ('finnois', 'du finnois'),
  'hi': ('hindi', 'du hindi'),
  'id': ('indonésien', "de l'indonésien"),
  'cs': ('tchèque', 'du tchèque'),
  'hu': ('hongrois', 'du hongrois'),
  'ro': ('roumain', 'du roumain'),
  'uk': ('ukrainien', "de l'ukrainien"),
  'ca': ('catalan', 'du catalan'),
};

/// Langues écrites de droite à gauche.
const _rightToLeft = {'ar', 'he', 'fa', 'ur'};

String _normalize(String code) =>
    code.trim().toLowerCase().split(RegExp('[-_]')).first;

/// « anglais », ou `null` pour un code absent de la table.
String? languageName(String code) => _languageNames[_normalize(code)]?.$1;

/// « Traduit de l'anglais », ou « Traduit d'une autre langue » pour un code
/// absent de la table.
String translatedFromLabel(String code) {
  final forms = _languageNames[_normalize(code)];
  return forms == null ? "Traduit d'une autre langue" : 'Traduit ${forms.$2}';
}

/// « en anglais », ou « dans sa langue d'origine (xx) » pour un code absent de
/// la table.
String inLanguageLabel(String code) {
  final name = languageName(code);
  return name == null
      ? "dans sa langue d'origine (${_normalize(code)})"
      : 'en $name';
}

/// Vrai pour une langue qui s'écrit de droite à gauche.
bool isRightToLeft(String code) => _rightToLeft.contains(_normalize(code));

/// « Traduction depuis l'anglais », « Traduction depuis le japonais », ou
/// « Traduction » pour un code absent ou inconnu de la table.
///
/// L'article vient de la forme avec « de » écrite à la main : « de l'anglais »
/// donne « l'anglais », « du japonais » donne « le japonais ».
String translationStepLabel(String? code) {
  final forms = code == null ? null : _languageNames[_normalize(code)];
  if (forms == null) return 'Traduction';
  final from = forms.$2;
  final withArticle = from.startsWith("de l'")
      ? from.substring(3)
      : 'le ${from.substring(3)}';
  return 'Traduction depuis $withArticle';
}
