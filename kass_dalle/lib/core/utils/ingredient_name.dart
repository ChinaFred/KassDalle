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

/// Le seul sous-ensemble de [_preparationTokens] qui reste neutre pour une
/// viande.
const Set<String> _hacheTokens = {'hache', 'hachee', 'haches', 'hachees'};

/// Viandes pour lesquelles « haché » change le produit, pas seulement la
/// coupe.
///
/// « persil haché » et « persil » sont le même achat : couper une herbe ne
/// change rien à sa valeur nutritionnelle, et c'est pour ce cas que
/// [_preparationTokens] existe. Pour une viande, « haché » désigne un produit
/// du boucher à part entière, avec son propre taux de matière grasse — souvent
/// plus élevé qu'une coupe entière. Fusionner « porc haché » et « porc » sous
/// un même identifiant a donné le même chiffre de calories aux deux, faux
/// pour l'un comme pour l'autre. Ces bases gardent donc « haché » dans leur
/// identifiant canonique ; les autres mots de préparation (émincé, râpé,
/// coupé, ciselé) restent neutres même pour elles.
const Set<String> _meatBaseTokens = {
  'porc',
  'boeuf',
  'veau',
  'agneau',
  'mouton',
  'poulet',
  'dinde',
  'canard',
  'oie',
  'lapin',
  'cheval',
  'pintade',
  'caille',
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

  final tokens = strict.split('_').where((token) => token.isNotEmpty).toList();
  // Les mots de préparation neutres partent toujours, « haché » y compris
  // pour l'instant : il ne revient que si la base restante est une viande.
  final withoutNeutralPrep = tokens
      .where(
        (token) =>
            !_preparationTokens.contains(token) || _hacheTokens.contains(token),
      )
      .toList();
  final baseTokens = withoutNeutralPrep
      .where((token) => !_hacheTokens.contains(token))
      .toList();
  final hasHache = withoutNeutralPrep.length > baseTokens.length;
  final isMeat =
      baseTokens.length == 1 && _meatBaseTokens.contains(baseTokens.first);

  final kept = isMeat && hasHache ? withoutNeutralPrep : baseTokens;
  final collapsed = kept.join('_').replaceAll(RegExp(r'^_+|_+$'), '');

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
