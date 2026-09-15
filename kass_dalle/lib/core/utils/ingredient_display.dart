/// Accord en nombre et en français des ingrédients à l'affichage.
///
/// ── Pourquoi ce module existe ────────────────────────────────────────────────
///
/// Une fiche imprimée disait « 3 Cuillère à soupe sauce soja », « 1 pièces
/// poivron », « 2 gousse ail » et, dans la prose d'une étape, « les carotte ».
/// Aucune de ces lignes n'est une faute de l'IA : ce sont des **identifiants
/// affichés comme du texte**.
///
///  - `Cuillère à soupe` est le libellé du référentiel d'unités, écrit pour un
///    écran d'administration — majuscule et singulier ;
///  - `carotte` est le nom **canonique** de l'ingrédient, celui qui sert à
///    l'appariement nutritionnel, à la liste de courses et à l'index de
///    recherche. `rewriteCooklangWithReferentials` le réécrit dans le CookLang
///    à chaque enregistrement.
///
/// D'où le parti pris : **on ne corrige pas le texte stocké, on corrige le
/// rendu**. Réécrire les noms dans le CookLang casserait l'identité dont
/// dépendent quatre chaînes — et serait de toute façon effacé au prochain
/// enregistrement. Corriger l'affichage, à l'inverse, répare d'un coup toutes
/// les recettes déjà en base, réimpression comprise.
///
/// Rendu uniquement, donc **client uniquement** : le serveur n'affiche rien, et
/// écrire un jumeau TypeScript « par symétrie » n'ajouterait qu'une divergence
/// possible.
library;

import 'nutrition_quantity_converter.dart';

/// Unités qui **comptent des objets**. Elles ne s'écrivent pas : on dit
/// « 2 carottes », jamais « 2 pièces carotte ». C'est le nom qui prend le
/// nombre.
const Set<String> kCountingUnits = {'piece', 'unite'};

/// Unités écrites en symbole : invariables, et jamais de majuscule.
///
/// « 500 gs » n'existe pas. Un symbole n'est pas un mot.
const Set<String> kSymbolUnits = {
  'g',
  'kg',
  'mg',
  'ml',
  'cl',
  'dl',
  'l',
  'cm',
  'mm',
};

/// Mots à **h aspiré** : pas d'élision, on dit « de haricots », pas
/// « d'haricots ». Liste courte et culinaire — le h muet (huile, herbe,
/// huître) est le cas par défaut, et de loin le plus fréquent en cuisine.
const Set<String> kAspiratedH = {
  'haricot',
  'haricots',
  'hareng',
  'harengs',
  'homard',
  'homards',
  'hachis',
  'hache',
  'haché',
  'hamburger',
  'hot',
  'houmous',
};

/// Noms en `-ou` qui prennent un `x` : les sept de la comptine, dont deux
/// arrivent vraiment dans une cuisine (chou, caillou pour le pain).
const Set<String> _ouTakesX = {
  'bijou',
  'caillou',
  'chou',
  'genou',
  'hibou',
  'joujou',
  'pou',
};

/// Noms en `-al` qui prennent un `s` au lieu de `-aux`.
const Set<String> _alTakesS = {
  'bal',
  'carnaval',
  'festival',
  'chacal',
  'recital',
  'récital',
  'regal',
  'régal',
  'cal',
};

/// Mots en `-eu` qui prennent un `s` au lieu de `x`.
const Set<String> _euTakesS = {'pneu', 'bleu', 'landau', 'sarrau'};

/// Prépositions qui figent la suite d'un groupe nominal.
///
/// « pomme de terre » → « pommes de terre » : seul ce qui précède s'accorde.
const List<String> _prepositions = [
  ' de ',
  " d'",
  ' du ',
  ' des ',
  ' à ',
  ' au ',
  ' aux ',
  ' en ',
  ' sans ',
  ' pour ',
];

/// Met un mot simple au pluriel, selon les règles usuelles du français.
String pluralizeWord(String word) {
  if (word.isEmpty) return word;
  final lower = word.toLowerCase();

  // Déjà pluriel — ou invariable.
  if (lower.endsWith('s') || lower.endsWith('x') || lower.endsWith('z')) {
    return word;
  }
  // Un symbole d'unité ne se met jamais au pluriel.
  if (kSymbolUnits.contains(lower)) return word;
  // Un mot qui contient un chiffre n'est pas un mot.
  if (RegExp(r'\d').hasMatch(lower)) return word;

  if (lower.endsWith('al') && !_alTakesS.contains(lower)) {
    return '${word.substring(0, word.length - 2)}aux';
  }
  if (lower.endsWith('au') || lower.endsWith('eau') || lower.endsWith('eu')) {
    return _euTakesS.contains(lower) ? '${word}s' : '${word}x';
  }
  if (lower.endsWith('ou')) {
    return _ouTakesX.contains(lower) ? '${word}x' : '${word}s';
  }
  return '${word}s';
}

/// Met un groupe nominal au pluriel.
///
/// Deux cas, et c'est tout ce que le français demande ici :
///
///  - avec préposition — « cuillère à soupe », « pomme de terre » — seul ce qui
///    **précède** s'accorde : « cuillères à soupe » ;
///  - sans préposition, tous les mots s'accordent, l'adjectif compris :
///    « haricot vert » → « haricots verts ».
///
/// Limite connue et assumée : un nom employé comme complément sans préposition
/// — « sauce soja » — donnerait « sauces sojas ». Le cas ne se présente pas,
/// parce qu'un tel ingrédient se mesure toujours avec une unité (cuillère,
/// millilitre), et qu'une unité empêche justement l'accord du nom.
String pluralizeNounPhrase(String phrase) {
  final trimmed = phrase.trim();
  if (trimmed.isEmpty) return trimmed;

  final lower = trimmed.toLowerCase();
  for (final preposition in _prepositions) {
    final index = lower.indexOf(preposition);
    if (index > 0) {
      final head = trimmed.substring(0, index);
      final tail = trimmed.substring(index);
      return pluralizeNounPhrase(head) + tail;
    }
  }

  return trimmed.split(' ').map(pluralizeWord).join(' ');
}

/// Vrai si la quantité commande le pluriel.
///
/// À partir de deux, et non au-dessus de un : le français écrit « 1,5 litre »
/// au singulier. Une quantité illisible — « quelques », « au goût » — laisse le
/// singulier : deviner un accord sur un mot qu'on n'a pas compris se voit plus
/// que de s'abstenir.
bool quantityIsPlural(String qty) {
  final value = NutritionQuantityConverter.parseQuantity(qty);
  return value != null && value >= 2;
}

/// `de` ou `d'`, selon l'initiale du mot qui suit.
String _liaison(String next) {
  final word = next.trim().toLowerCase();
  if (word.isEmpty) return 'de';
  final firstWord = word.split(RegExp(r"[\s']")).first;
  if (kAspiratedH.contains(firstWord)) return 'de';
  return RegExp(r'^[aàâeéèêëiîïoôuùûüyh]').hasMatch(word) ? "d'" : 'de';
}

String _joinWithLiaison(String head, String name) {
  final liaison = _liaison(name);
  return liaison == "d'" ? "$head d'$name" : '$head de $name';
}

/// Forme d'affichage d'une unité : minuscule, et accordée au nombre.
///
/// Le référentiel écrit `Cuillère à soupe` — un libellé de tableau
/// d'administration. Dans une phrase, ce n'est ni une majuscule ni un
/// singulier : « 3 cuillères à soupe ».
String displayUnit(String unit, {required bool plural}) {
  final trimmed = unit.trim();
  if (trimmed.isEmpty) return '';
  final canonical = NutritionQuantityConverter.normalizeObservedUnit(trimmed);
  if (kSymbolUnits.contains(canonical) || kSymbolUnits.contains(trimmed)) {
    return trimmed;
  }
  final lowered = trimmed.toLowerCase();
  return plural ? pluralizeNounPhrase(lowered) : lowered;
}

/// Ligne d'ingrédient telle qu'elle se lit : « 3 cuillères à soupe de sauce
/// soja », « 2 carottes », « 500 g d'émincé de bœuf ».
///
/// Quatre cas :
///
///  - **pas de quantité** → le nom seul ;
///  - **pas d'unité** → la quantité et le nom accordé ;
///  - **unité qui compte** (`pièce`, `unité`) → elle disparaît, et c'est le nom
///    qui porte le nombre : « 2 carottes » ;
///  - **unité de mesure** → « quantité unité **de** nom », avec élision.
///
/// Le nom reste au singulier derrière « de » : trois cuillères de sauce soja,
/// pas de sauces soja.
String formatIngredientDisplay({
  required String qty,
  required String unit,
  required String name,
}) {
  final cleanName = name.trim();
  final cleanQty = qty.trim();
  final cleanUnit = unit.trim();
  if (cleanName.isEmpty) return [cleanQty, cleanUnit].join(' ').trim();
  if (cleanQty.isEmpty && cleanUnit.isEmpty) return cleanName;

  final plural = quantityIsPlural(cleanQty);
  final canonicalUnit = cleanUnit.isEmpty
      ? ''
      : NutritionQuantityConverter.normalizeObservedUnit(cleanUnit);
  final counting = cleanUnit.isEmpty || kCountingUnits.contains(canonicalUnit);

  if (counting) {
    final displayName = plural ? pluralizeNounPhrase(cleanName) : cleanName;
    return cleanQty.isEmpty ? displayName : '$cleanQty $displayName';
  }

  // L'unité est déjà le premier mot du nom — « brin », « brin de romarin » :
  // la répéter donnerait « 1 brin brin de romarin ».
  if (cleanName.toLowerCase().startsWith(canonicalUnit) ||
      cleanName.toLowerCase().startsWith(cleanUnit.toLowerCase())) {
    final displayName = plural ? pluralizeNounPhrase(cleanName) : cleanName;
    return cleanQty.isEmpty ? displayName : '$cleanQty $displayName';
  }

  final unitText = displayUnit(cleanUnit, plural: plural);
  final head = cleanQty.isEmpty ? unitText : '$cleanQty $unitText';
  return _joinWithLiaison(head, cleanName);
}

/// Une quantité seule, telle qu'elle se lit : « 400 ml », « 2 cuillères à
/// soupe », « 6 » pour un comptage.
///
/// Sert aux provenances de la liste de courses — « Curry (400 ml) » — où le
/// nom du produit est déjà sur la ligne.
String formatQuantityOnly({required String qty, required String unit}) {
  final cleanQty = qty.trim();
  final cleanUnit = unit.trim();
  if (cleanUnit.isEmpty) return cleanQty;
  final canonicalUnit = NutritionQuantityConverter.normalizeObservedUnit(
    cleanUnit,
  );
  if (kCountingUnits.contains(canonicalUnit)) return cleanQty;
  final unitText = displayUnit(cleanUnit, plural: quantityIsPlural(cleanQty));
  return cleanQty.isEmpty ? unitText : '$cleanQty $unitText';
}

/// Une ligne de courses qui porte plusieurs quantités : « 400 ml + 250 g de
/// lait de coco », « 2 kg + 6 pommes de terre ».
///
/// Deux familles d'unités sans conversion exacte restent deux quantités, sur
/// une seule ligne : c'est un produit, on l'achète une fois. Les mesures
/// viennent d'abord ; le comptage, s'il y en a un, vient en dernier et c'est
/// lui qui accorde le nom. Une seule quantité se lit comme une ligne
/// d'ingrédient ordinaire.
String formatShoppingLine({
  required List<({String qty, String unit})> quantities,
  required String name,
}) {
  final cleanName = name.trim();
  if (quantities.isEmpty) return cleanName;
  if (quantities.length == 1) {
    return formatIngredientDisplay(
      qty: quantities.single.qty,
      unit: quantities.single.unit,
      name: cleanName,
    );
  }
  final measured = <String>[];
  String? counted;
  for (final q in quantities) {
    final cleanUnit = q.unit.trim();
    final canonicalUnit = cleanUnit.isEmpty
        ? ''
        : NutritionQuantityConverter.normalizeObservedUnit(cleanUnit);
    final counting =
        cleanUnit.isEmpty || kCountingUnits.contains(canonicalUnit);
    if (counting) {
      final qty = q.qty.trim();
      counted = counted == null ? qty : '$counted + $qty';
    } else {
      measured.add(formatQuantityOnly(qty: q.qty, unit: q.unit));
    }
  }
  if (counted == null || counted.isEmpty) {
    return _joinWithLiaison(measured.join(' + '), cleanName);
  }
  final displayName = quantityIsPlural(counted)
      ? pluralizeNounPhrase(cleanName)
      : cleanName;
  return '${[...measured, counted].join(' + ')} $displayName';
}

/// Le nom d'un ingrédient tel qu'il se lit **dans une phrase**.
///
/// « Émincer finement le poivron, les carotte » : le nom canonique était
/// injecté brut dans la prose. Il s'accorde ici — mais seulement quand l'unité
/// compte des objets, car c'est le seul cas où le nom porte le nombre. Trois
/// cuillères de sauce soja restent « la sauce soja », et deux gousses d'ail
/// restent « l'ail ».
String ingredientNameInProse({
  required String name,
  required String qty,
  required String unit,

  /// Le texte de l'étape qui précède le jeton. L'article qu'il porte — « les »,
  /// « la » — l'emporte sur la quantité : dans la prose, un ingrédient s'écrit
  /// le plus souvent sans quantité, et c'est l'article qui donne le nombre.
  String before = '',
}) {
  final cleanName = name.trim();
  if (cleanName.isEmpty) return cleanName;

  final imposed = numberFromPrecedingArticle(before);
  if (imposed != null) {
    return imposed ? pluralizeNounPhrase(cleanName) : cleanName;
  }
  final canonicalUnit = unit.trim().isEmpty
      ? ''
      : NutritionQuantityConverter.normalizeObservedUnit(unit.trim());
  final counting =
      unit.trim().isEmpty || kCountingUnits.contains(canonicalUnit);
  if (!counting || !quantityIsPlural(qty)) return cleanName;
  return pluralizeNounPhrase(cleanName);
}

/// Articles qui imposent le pluriel au nom qui suit.
const Set<String> _pluralArticles = {
  'les',
  'des',
  'ces',
  'aux',
  'mes',
  'tes',
  'ses',
  'nos',
  'vos',
  'leurs',
  'quelques',
  'plusieurs',
  'deux',
  'trois',
  'quatre',
  'cinq',
  'six',
  'sept',
  'huit',
  'neuf',
  'dix',
};

/// Articles qui imposent le singulier.
const Set<String> _singularArticles = {
  'le',
  'la',
  "l'",
  'un',
  'une',
  'du',
  'ce',
  'cet',
  'cette',
  'mon',
  'ma',
  'ton',
  'ta',
  'son',
  'sa',
  'notre',
  'votre',
  'leur',
  'chaque',
};

/// Le nombre imposé par l'article qui précède, ou `null` s'il n'en dit rien.
///
/// C'est le signal que lit un humain, et il a deux avantages sur la quantité :
/// il est **local** — il tient dans les deux mots qui précèdent — et il est
/// **toujours là**, même quand le jeton ne porte aucune quantité. Or dans la
/// prose, un ingrédient s'écrit le plus souvent `@carotte{}`, sans quantité :
/// celle-ci vit dans la liste. C'est précisément ce cas qui laissait « les
/// carotte » passer.
bool? numberFromPrecedingArticle(String before) {
  final trimmed = before.trimRight();
  if (trimmed.isEmpty) return null;

  // Un article élidé est collé au mot : « l'ail ».
  if (trimmed.endsWith("'") || trimmed.endsWith('’')) {
    final match = RegExp(r"(\w+)['’]$").firstMatch(trimmed);
    final word = match?.group(1)?.toLowerCase();
    return (word == 'l' || word == 'd') ? false : null;
  }

  final words = trimmed.split(RegExp(r'\s+'));
  final last = words.last.toLowerCase();
  if (_pluralArticles.contains(last)) return true;
  if (_singularArticles.contains(last)) return false;
  return null;
}
