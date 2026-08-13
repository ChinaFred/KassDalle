/// Normalisation des noms d'ingrédients et d'unités.
///
/// Jumeau Dart de `functions/src/nutrition/ingredientName.ts`, vérifié par les
/// mêmes cas dans `test-fixtures/ingredient_names.json`.
///
/// Cette règle existait en quatre exemplaires divergents : le convertisseur de
/// quantités, le parseur CookLang, le détail nutritionnel et le backend. Les
/// identifiants qu'ils produisaient servent pourtant à retrouver le MÊME
/// document dans `nutrition_ingredients` — une divergence signifiait un
/// ingrédient introuvable, donc un calcul nutritionnel incomplet, sans erreur.
library;

/// Mots de préparation qui ne font pas partie de l'identité d'un ingrédient :
/// « persil haché » et « persil » désignent le même produit.
const Set<String> _preparationTokens = {
  'hache',
  'hachee',
  'haches',
  'hachees',
  'emince',
  'emincee',
  'eminces',
  'emincees',
  'rape',
  'rapee',
  'rapes',
  'rapees',
  'grossierement',
  'finement',
  'coupe',
  'coupee',
  'coupes',
  'coupees',
  'cisele',
  'ciselee',
  'ciseles',
  'ciselees',
};

/// Minuscules, accents retirés, tout caractère non alphanumérique remplacé par
/// un souligné. C'est la brique commune à toutes les normalisations.
String normalizeBase(String value) {
  final lowered = value.trim().toLowerCase();
  final withoutAccents = _stripAccents(lowered);
  return withoutAccents
      .replaceAll(RegExp(r'[^a-z0-9]+'), '_')
      .replaceAll(RegExp(r'^_+|_+$'), '');
}

/// Retire les diacritiques, qu'ils soient précomposés (« é ») ou décomposés
/// (« e » suivi d'un accent combinant).
String _stripAccents(String value) {
  const map = {
    'à': 'a',
    'á': 'a',
    'â': 'a',
    'ã': 'a',
    'ä': 'a',
    'å': 'a',
    'è': 'e',
    'é': 'e',
    'ê': 'e',
    'ë': 'e',
    'ì': 'i',
    'í': 'i',
    'î': 'i',
    'ï': 'i',
    'ò': 'o',
    'ó': 'o',
    'ô': 'o',
    'õ': 'o',
    'ö': 'o',
    'ù': 'u',
    'ú': 'u',
    'û': 'u',
    'ü': 'u',
    'ý': 'y',
    'ÿ': 'y',
    'ç': 'c',
    'ñ': 'n',
    'æ': 'ae',
    'œ': 'oe',
  };
  final buffer = StringBuffer();
  for (final char in value.split('')) {
    buffer.write(map[char] ?? char);
  }
  return buffer.toString().replaceAll(RegExp(r'[̀-ͯ]'), '');
}

/// Identifiant strict : la forme normalisée telle quelle, préparation comprise.
String normalizeIngredientStrictId(String value) => normalizeBase(value);

/// Identifiant canonique : identifiant strict débarrassé des mots de
/// préparation. Retombe sur l'identifiant strict si le retrait ne laisse rien.
String normalizeIngredientCanonicalId(String value) {
  final strict = normalizeBase(value);
  if (strict.isEmpty) return strict;

  final collapsed = strict
      .split('_')
      .where((token) => token.isNotEmpty && !_preparationTokens.contains(token))
      .join('_')
      .replaceAll(RegExp(r'^_+|_+$'), '');

  return collapsed.isEmpty ? strict : collapsed;
}

/// Retire le « s » final d'un mot d'au moins trois lettres.
///
/// Règle unique de dépluralisation du projet : la déduplication du parseur
/// CookLang s'en servait déjà pour fusionner « tomate » et « tomates », mais
/// elle en gardait un exemplaire privé. Les deux ingrédients étaient donc
/// fusionnés dans la recette, puis cherchés sous deux identifiants différents
/// dans le référentiel.
///
/// La règle est volontairement naïve : « ananas » devient « anana ». C'est
/// acceptable parce qu'elle ne sert jamais à écrire un identifiant, seulement
/// à en essayer un de plus en dernier recours.
String depluralizeToken(String token) {
  if (token.length > 2 && token.endsWith('s')) {
    return token.substring(0, token.length - 1);
  }
  return token;
}

/// Identifiant singularisé : l'identifiant canonique dont chaque mot a perdu
/// son pluriel. Repli de lecture uniquement — voir [depluralizeToken].
String normalizeIngredientSingularId(String value) {
  final canonical = normalizeIngredientCanonicalId(value);
  if (canonical.isEmpty) return canonical;
  return canonical.split('_').map(depluralizeToken).join('_');
}

/// Identifiants à essayer pour retrouver un ingrédient dans le référentiel,
/// du plus précis au plus général : strict, puis canonique, puis singularisé.
/// Les formes identiques sont éliminées en conservant cet ordre.
List<String> buildIngredientLookupIds(String value) {
  final ids = <String>[];
  for (final id in [
    normalizeIngredientStrictId(value),
    normalizeIngredientCanonicalId(value),
    normalizeIngredientSingularId(value),
  ]) {
    if (id.isNotEmpty && !ids.contains(id)) ids.add(id);
  }
  return ids;
}

/// Retire les accents en conservant les espaces et la ponctuation.
///
/// Utilisé par les normalisations qui ne veulent pas d'un identifiant à
/// soulignés — la déduplication du parseur CookLang, par exemple, raisonne mot
/// à mot et doit garder les espaces.
String stripAccentsPreservingWords(String value) => _stripAccents(value);
