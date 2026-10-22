import 'ingredient_name.dart';

/// Ustensiles et consommables de cuisine : une liste fermée.
///
/// Jumelle de `functions/src/nutrition/utensils.ts`, verrouillée par
/// `test-fixtures/utensils.json`. Le client s'en sert quand il reconstruit la
/// liste d'ingrédients depuis les `@` du CookLang (éditeur, validation d'un
/// brouillon) : un `@papier sulfurisé{}` écrit à la main ou resté d'un ancien
/// import n'y entre pas. Le serveur l'applique aussi au balisage et au
/// référentiel nutritionnel.
///
/// Sans aliment : « moule » seul est le mollusque, « ficelle » seule le pain,
/// « brochette » seule le plat ; « ramequin » reste hors liste, c'est aussi un
/// fromage (Bugey, Vaud).
const List<String> kUtensilNames = [
  'papier sulfurisé',
  'papier cuisson',
  'papier de cuisson',
  'papier aluminium',
  "papier d'aluminium",
  'papier alu',
  'aluminium',
  'film alimentaire',
  'film étirable',
  'papier film',
  'papier absorbant',
  'essuie-tout',
  'tapis de cuisson',
  'tapis en silicone',
  'cure-dent',
  'pique à brochette',
  'pic à brochette',
  'pique en bois',
  'brochette en bois',
  'ficelle de cuisine',
  'ficelle alimentaire',
  'fil de cuisine',
  'poche à douille',
  'douille',
  'caissette',
  'cercle à pâtisserie',
  'cercle à tarte',
  'cercle à entremets',
  'emporte-pièce',
  'étamine',
  'sac de congélation',
  'sachet de congélation',
  'moule à tarte',
  'moule à tartelette',
  'moule à manqué',
  'moule à cake',
  'moule à gâteau',
  'moule à charnière',
  'moule à savarin',
  'moule à kouglof',
  'moule à muffin',
  'moule à madeleine',
  'moule à cannelé',
  'moule à soufflé',
  'moule à brioche',
  'moule à financier',
  'moule à quiche',
  'moule à gratin',
  'moule à pain',
  'moule en silicone',
];

/// Mots de tête sans contenu : articles et tailles (« 1 grande feuille de… »).
const Set<String> _leadingNoise = {
  'un',
  'une',
  'des',
  'du',
  'de',
  'd',
  'l',
  'le',
  'la',
  'les',
  'grand',
  'grande',
  'petit',
  'petite',
};

/// Unités de dimension retirées partout (« cercle de 20 cm »).
const Set<String> _dimensionUnits = {'cm', 'mm'};

/// Contenants de tête : « feuille de papier sulfurisé », « rouleau de film ».
const Set<String> _containers = {
  'feuille',
  'morceau',
  'bande',
  'rouleau',
  'carre',
  'rectangle',
};

/// Qualificatifs de fin d'un seul mot.
const Set<String> _trailingWords = {
  'de',
  'd',
  'environ',
  'inox',
  'jetable',
  'individuel',
  'individuelle',
};

/// Matières introduites par « en » en fin de nom : « piques en bois ».
///
/// Comparées après dépluralisation, comme les mots du texte : « bois » y
/// devient « boi ».
final Set<String> _trailingMaterials = {
  for (final m in ['bois', 'papier', 'silicone', 'metal', 'inox', 'alu'])
    depluralizeToken(m),
};

List<String> _utensilTokens(String text) {
  final withoutParentheses = text.replaceAll(RegExp(r'\([^)]*\)'), ' ');
  return normalizeIngredientStrictId(
    withoutParentheses,
  ).split('_').where((t) => t.isNotEmpty).map(depluralizeToken).toList();
}

List<String> _stripTrailingQualifiers(List<String> tokens) {
  final out = [...tokens];
  while (true) {
    final last = out.last;
    if (out.length > 1 && _trailingWords.contains(last)) {
      out.removeLast();
      continue;
    }
    if (out.length > 2 &&
        out[out.length - 2] == 'en' &&
        _trailingMaterials.contains(last)) {
      out.removeRange(out.length - 2, out.length);
      continue;
    }
    return out;
  }
}

final Set<String> _utensilKeys = {
  for (final name in kUtensilNames) _utensilTokens(name).join('_'),
};

/// Vrai quand le texte — un nom d'ingrédient ou une ligne du livre — désigne
/// un ustensile de la liste fermée. Même algorithme que `isUtensil` côté
/// serveur : parenthèses, nombres, cm/mm, articles et « grand / petit » de tête
/// ignorés ; puis égalité avec un nom de la liste, tel quel, sans contenant de
/// tête (« feuille de ») ou sans qualificatif de fin (« en bois »).
bool isUtensil(String text) {
  var tokens = _utensilTokens(text)
      .where(
        (t) => !RegExp(r'^\d+$').hasMatch(t) && !_dimensionUnits.contains(t),
      )
      .toList();
  while (tokens.isNotEmpty && _leadingNoise.contains(tokens.first)) {
    tokens = tokens.sublist(1);
  }
  if (tokens.isEmpty) return false;

  final candidates = <List<String>>[tokens];
  if (tokens.length > 2 &&
      _containers.contains(tokens[0]) &&
      (tokens[1] == 'de' || tokens[1] == 'd')) {
    candidates.add(tokens.sublist(2));
  }
  for (final candidate in [...candidates]) {
    candidates.add(_stripTrailingQualifiers(candidate));
  }
  return candidates.any(
    (c) => c.isNotEmpty && _utensilKeys.contains(c.join('_')),
  );
}
