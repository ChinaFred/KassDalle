import '../../../core/services/nutrition_units_reference.dart';
import '../../../core/utils/ingredient_name.dart';
import '../../../core/utils/nutrition_quantity_converter.dart';
import '../../admin/data/nutrition_ingredients_repository.dart';
import 'recipe.dart';

/// Les nutriments du tableau, dans l'ordre des colonnes.
const kNutritionMetricKeys = [
  ('kcal', 'Calories'),
  ('protein_g', 'Protéines'),
  ('carbs_g', 'Glucides'),
  ('sugar_g', 'Sucres'),
  ('fiber_g', 'Fibres'),
  ('fat_g', 'Lipides'),
  ('saturated_fat_g', 'Saturés'),
  ('salt_g', 'Sel'),
];

/// Ce qu'un ingrédient apporte au calcul, et ce qui manque pour le savoir.
///
/// Vit dans le domaine et non dans l'écran : le même tableau se dessine
/// maintenant à deux endroits — l'onglet Nutrition et le PDF exporté — et un
/// poids résolu différemment d'un côté ferait dire deux totaux à la même
/// recette.
class NutritionContributionRow {
  final RecipeIngredient ingredient;
  final String canonicalId;
  final Map<String, double>? perIngredient;
  final double? weightGrams;

  /// Le poids d'une unité de cet ingrédient est estimé par l'IA
  /// (« 1 fine tranche » ne se mesure pas, elle se devine).
  final bool weightEstimated;

  /// La recette n'écrivait pas de quantité : celle-ci a été lue par
  /// convention. « sel, pincée » et « poivre » tout court se pèsent à la
  /// pincée — un demi-gramme qu'il vaut mieux compter que perdre, mais qui
  /// doit se dire, sinon il se lit comme une donnée de la recette.
  final bool quantityAssumed;

  /// La quantité lue est la portion usuelle de l'ingrédient, estimée par l'IA :
  /// la recette l'écrit « roquette » ou « parmesan » sans rien de plus. C'est un
  /// ordre de grandeur pour quatre personnes, et il doit s'annoncer comme tel.
  final bool usualPortion;

  /// L'ingrédient appartient à la recette mais pas au repas : bain de friture,
  /// foin de fumage, marinade jetée. Ses valeurs restent affichées — les
  /// masquer reviendrait à cacher un ingrédient — mais sortent du total.
  final bool notConsumed;

  /// La ligne reprend un ingrédient déjà listé : la pièce achetée revient
  /// découpée ou sous un nom générique. Même traitement que [notConsumed] —
  /// visible, atténuée, hors total.
  final bool duplicate;

  const NutritionContributionRow({
    required this.ingredient,
    required this.canonicalId,
    this.perIngredient,
    this.weightGrams,
    this.quantityAssumed = false,
    this.usualPortion = false,
    this.weightEstimated = false,
    this.notConsumed = false,
    this.duplicate = false,
  });

  /// Écartée du total, mais délibérément : rien à corriger ici.
  bool get isExcluded => notConsumed || duplicate;

  /// Rien à afficher : ni poids, ni valeurs. C'est le cas qu'il ne faut pas
  /// laisser passer pour une simple série de tirets.
  ///
  /// Un ingrédient écarté volontairement n'est pas « manquant » : son absence
  /// du total est voulue.
  bool get isMissing => perIngredient == null && !isExcluded;
}

/// Les lignes du tableau et ce qui s'en déduit : totaux, poids connu, comptes
/// de la légende.
class NutritionContributionTable {
  final List<NutritionContributionRow> rows;

  /// Huile passée du bain dans l'assiette. Ni un ingrédient, ni une donnée
  /// manquante : elle compte dans le total sans avoir de ligne dans la recette.
  final RecipeAbsorbedOil? absorbedOil;

  const NutritionContributionTable({required this.rows, this.absorbedOil});

  /// Total d'un nutriment, ce qui n'est pas mangé mis à part.
  ///
  /// Un litre de bain de friture pesait 8280 kcal dans ce total et écrasait
  /// toute la recette.
  double? totalFor(String key) {
    var hasValue = false;
    var sum = 0.0;
    for (final row in rows) {
      if (row.isExcluded) continue;
      final value = row.perIngredient?[key];
      if (value == null) continue;
      hasValue = true;
      sum += value;
    }
    final absorbed = absorbedOil?.contribution[key];
    if (absorbed != null) {
      hasValue = true;
      sum += absorbed;
    }
    return hasValue ? sum : null;
  }

  /// Poids des ingrédients réellement mangés, huile absorbée comprise.
  double get knownWeight =>
      rows
          .where((row) => !row.isExcluded)
          .fold<double>(0, (acc, row) => acc + (row.weightGrams ?? 0)) +
      (absorbedOil?.grams ?? 0);

  /// Seules les unités devinées se signalent ligne à ligne : le poids d'une
  /// « fine tranche » est une convention choisie par l'IA, pas une mesure.
  int get estimatedUnitCount =>
      rows.where((r) => !r.isMissing && r.weightEstimated).length;

  int get missingCount => rows.where((r) => r.isMissing).length;

  int get assumedCount =>
      rows.where((r) => !r.isMissing && r.quantityAssumed).length;

  int get notConsumedCount => rows.where((r) => r.notConsumed).length;

  int get duplicateCount => rows.where((r) => r.duplicate).length;

  /// Cette ligne écartée est-elle le bain d'où sort l'huile absorbée ?
  ///
  /// Le serveur nomme sa source : c'est l'ingrédient non consommé le plus gras
  /// de la recette. On ne rapproche que des lignes déjà écartées — un homonyme
  /// consommé (« huile d'olive » de l'assaisonnement) n'est pas ce bain-là.
  bool isAbsorbedOilSource(NutritionContributionRow row) {
    final oil = absorbedOil;
    if (oil == null || !row.notConsumed) return false;
    return row.ingredient.name.trim().toLowerCase() ==
        oil.sourceName.trim().toLowerCase();
  }

  /// Le bain n'est pas listé, ou sous un nom que le serveur n'a pas retenu :
  /// la ligne dérivée ferme alors le tableau plutôt que de disparaître.
  bool get hasOrphanAbsorbedOil =>
      absorbedOil != null && !rows.any(isAbsorbedOilSource);

  /// Vrai dès qu'une ligne demande une explication sous le tableau.
  bool get needsLegend =>
      estimatedUnitCount > 0 ||
      assumedCount > 0 ||
      missingCount > 0 ||
      notConsumedCount > 0 ||
      duplicateCount > 0 ||
      absorbedOil != null;
}

/// Ce qu'une ligne de légende explique. L'écran y accroche une icône et une
/// couleur, le PDF une puce ; le texte, lui, est le même des deux côtés.
enum NutritionLegendKind {
  absorbedOil,
  assumedQuantity,
  estimatedUnit,
  notConsumed,
  duplicate,
  missing,
}

class NutritionLegendEntry {
  final NutritionLegendKind kind;
  final String label;

  const NutritionLegendEntry(this.kind, this.label);
}

/// Ce que la légende dit des quantités supposées : « à la pincée » quand toutes
/// le sont ainsi, « pour une quantité usuelle » dès qu'un brin, un bouquet ou
/// une portion estimée s'y mêle.
String _assumedUnitsLegend(NutritionContributionTable table) {
  final units = {
    for (final row in table.rows)
      if (!row.isMissing && row.quantityAssumed) nutritionAssumedUnitName(row),
  };
  return units.length == 1 && units.first == 'pincée'
      ? 'à la pincée'
      : 'pour une quantité usuelle';
}

/// Les explications à porter sous le tableau, dans l'ordre d'affichage.
///
/// Du plus étonnant au plus banal : une huile qui n'est écrite nulle part se
/// justifie avant un ingrédient qui manque au référentiel.
List<NutritionLegendEntry> nutritionLegendEntries(
  NutritionContributionTable table,
) {
  final oil = table.absorbedOil;
  return [
    if (oil != null)
      NutritionLegendEntry(
        NutritionLegendKind.absorbedOil,
        '${oil.grams.toStringAsFixed(0)} g d\'huile absorbée à la friture, '
        'comptée dans le total',
      ),
    if (table.assumedCount > 0)
      NutritionLegendEntry(
        NutritionLegendKind.assumedQuantity,
        '${table.assumedCount} ingrédient(s) sans quantité, comptés '
        '${_assumedUnitsLegend(table)}',
      ),
    if (table.estimatedUnitCount > 0)
      NutritionLegendEntry(
        NutritionLegendKind.estimatedUnit,
        '${table.estimatedUnitCount} unité(s) au poids estimé',
      ),
    if (table.notConsumedCount > 0)
      NutritionLegendEntry(
        NutritionLegendKind.notConsumed,
        '${table.notConsumedCount} ingrédient(s) non consommé(s), hors total',
      ),
    if (table.duplicateCount > 0)
      NutritionLegendEntry(
        NutritionLegendKind.duplicate,
        '${table.duplicateCount} ligne(s) déjà comptée(s) plus haut',
      ),
    if (table.missingCount > 0)
      NutritionLegendEntry(
        NutritionLegendKind.missing,
        '${table.missingCount} ingrédient(s) sans valeur, exclus du total',
      ),
  ];
}

/// Identifiants du référentiel à charger pour cette recette.
///
/// Les mêmes variantes que celles interrogées par le serveur — strict,
/// canonique, singulier — pour que les deux couches trouvent ou ne trouvent
/// pas exactement les mêmes profils.
List<String> recipeNutritionProfileIds(Recipe recipe) => [
  for (final ingredient in recipe.ingredients)
    ...buildIngredientLookupIds(ingredient.name),
];

/// Document du référentiel qui porte les valeurs de cet ingrédient.
NutritionIngredientDoc? _profileFor(
  RecipeIngredient ingredient,
  Map<String, NutritionIngredientDoc> nutritionById,
) {
  for (final candidate in buildIngredientLookupIds(ingredient.name)) {
    final doc = nutritionById[candidate];
    if (doc == null || !doc.hasUsableValues) continue;
    return doc;
  }
  return null;
}

/// Document du référentiel, valeurs nutritionnelles ou non.
///
/// Distinct de [_profileFor] : un ingrédient peut connaître le poids de sa
/// pièce sans avoir encore ses valeurs pour 100 g. Confondre les deux ferait
/// perdre le poids exact au moment où il est le plus utile.
NutritionIngredientDoc? _docFor(
  RecipeIngredient ingredient,
  Map<String, NutritionIngredientDoc> nutritionById,
) {
  for (final candidate in buildIngredientLookupIds(ingredient.name)) {
    final doc = nutritionById[candidate];
    if (doc != null) return doc;
  }
  return null;
}

/// Apport d'un ingrédient dont le profil est connu.
///
/// Les métriques affichées partent de zéro, puis le profil les remplit. Le
/// référentiel n'enregistre que les valeurs strictement positives : ce qu'il ne
/// liste pas est un zéro, pas une inconnue. Sans ce garnissage, le sel
/// affichait sept tirets — « on ne sait pas » — pour sept zéros certains, alors
/// même que le total, lui, les additionnait déjà comme des zéros.
Map<String, double> _contributionOf(
  NutritionIngredientDoc profile,
  double weightGrams,
) {
  return {
    for (final metric in kNutritionMetricKeys) metric.$1: 0,
    for (final entry in profile.per100g.entries)
      entry.key: (weightGrams * entry.value) / 100,
  };
}

/// Le tableau des apports d'une recette, référentiels appliqués.
///
/// Même arbitrage que le calcul serveur (`recipeNutrition.ts`) : quand
/// l'ingrédient se compte à la pièce, le poids d'une pièce **du référentiel
/// d'ingrédients** l'emporte — c'est la donnée la plus spécifique dont on
/// dispose.
NutritionContributionTable buildNutritionContributions({
  required Recipe recipe,
  required Map<String, NutritionIngredientDoc> nutritionById,
  required Map<String, ReferentialUnitOverride> unitOverrides,
  required Map<String, NutritionUnitInfo> unitInfos,
}) {
  final snapshot = recipe.nutrition;
  // Le verdict « cette ligne en reprend une autre » vient du serveur : il
  // demande de lire la recette, pas de comparer des noms. L'app le reflète.
  final duplicateNames = (snapshot?.duplicateIngredients ?? const <String>[])
      .map((name) => name.trim().toLowerCase())
      .toSet();

  final rows = recipe.ingredients
      .where((ingredient) => ingredient.name.trim().isNotEmpty)
      .map((ingredient) {
        final profile = _profileFor(ingredient, nutritionById);
        final doc = _docFor(ingredient, nutritionById);
        final weightOverride = doc == null
            ? null
            : IngredientWeightOverride(
                gramsPerPiece: doc.gramsPerPiece,
                gramsPerUnit: doc.gramsPerUnit,
                usualPortionGrams: doc.usualPortionGrams,
              );
        final weight = resolveIngredientWeightGrams(
          overrides: unitOverrides,
          ingredientName: ingredient.name,
          qty: ingredient.qty,
          unit: ingredient.unit,
          ingredientOverride: weightOverride,
        );
        final weighing = NutritionQuantityConverter.resolveWeighingInput(
          ingredientName: ingredient.name,
          qty: ingredient.qty,
          unit: ingredient.unit,
          usualPortionGrams: weightOverride?.usualPortionGrams,
        );
        return NutritionContributionRow(
          notConsumed: doc?.notConsumed ?? false,
          duplicate: duplicateNames.contains(
            ingredient.name.trim().toLowerCase(),
          ),
          ingredient: ingredient,
          canonicalId: normalizeIngredientCanonicalId(ingredient.name),
          perIngredient: weight == null || profile == null
              ? null
              : _contributionOf(profile, weight),
          weightGrams: weight,
          quantityAssumed:
              weight != null &&
              NutritionQuantityConverter.parseQuantity(ingredient.qty) == null,
          usualPortion: weight != null && (weighing?.usualPortion ?? false),
          weightEstimated: isUnitWeightEstimated(
            infos: unitInfos,
            unit: ingredient.unit,
          ),
        );
      })
      .toList(growable: false);

  return NutritionContributionTable(
    rows: rows,
    absorbedOil: snapshot?.absorbedOil,
  );
}

/// Une valeur nutritionnelle, ou un tiret quand elle est inconnue.
String formatNutritionValue(double? v, {bool integer = false}) {
  if (v == null) return '-';
  return integer ? v.round().toString() : v.toStringAsFixed(1);
}

/// Ce que vaut la ligne, faute de quantité écrite dans la recette.
///
/// Le libellé nomme l'unité réellement appliquée plutôt qu'un nombre de
/// grammes : le poids d'une pincée se corrige depuis Admin → Unités, et un
/// message qui annonce « 0,5 g » vieillirait le jour où quelqu'un le change.
String nutritionAssumedUnitName(NutritionContributionRow row) {
  // La portion usuelle n'est pas une unité : elle vient de la fiche de
  // l'ingrédient, que ce calcul-ci ne reçoit pas.
  if (row.usualPortion) return 'portion usuelle';
  final weighing = NutritionQuantityConverter.resolveWeighingInput(
    ingredientName: row.ingredient.name,
    qty: row.ingredient.qty,
    unit: row.ingredient.unit,
  );
  final normalized = NutritionQuantityConverter.normalizeObservedUnit(
    weighing?.unit ?? '',
  );
  return switch (normalized) {
    'pincee' => 'pincée',
    'pointe_de_couteau' => 'pointe de couteau',
    'brin' => 'brin',
    'branche' => 'branche',
    'bouquet' => 'bouquet',
    'feuille' => 'feuille',
    'gousse' => 'gousse',
    _ => 'unité',
  };
}

/// Les unités du calcul qui s'accordent au féminin.
const _feminineAssumedUnits = {
  'pincée',
  'pointe de couteau',
  'branche',
  'feuille',
  'gousse',
  'unité',
  'portion usuelle',
};

/// L'unité appliquée avec son article : « une pincée », « un brin ».
///
/// Une portion usuelle dit son poids et sa source : c'est une estimation, et un
/// chiffre estimé affiché comme un chiffre lu de la recette serait un mensonge
/// par omission.
String nutritionAssumedUnitPhrase(NutritionContributionRow row) {
  final name = nutritionAssumedUnitName(row);
  final phrase = '${_feminineAssumedUnits.contains(name) ? 'une' : 'un'} $name';
  final grams = row.weightGrams;
  if (!row.usualPortion || grams == null) return phrase;
  return '$phrase (${grams.round()} g, estimée par l\'IA)';
}

/// Ce qu'affiche la colonne « Quantite ».
///
/// D'abord ce que la recette écrit. Quand elle n'écrit rien — « poivre » tout
/// court —, l'unité retenue par le calcul prend sa place : la ligne montrait
/// sinon une pastille seule, sans dire de quoi elle parlait, à côté d'un
/// « Pincée » lisible sur la ligne du dessus.
String nutritionQuantityCellText(NutritionContributionRow row) {
  final written = [
    row.ingredient.qty.trim(),
    row.ingredient.unit.trim(),
  ].where((part) => part.isNotEmpty).join(' ');
  if (written.isNotEmpty) return written;
  if (!row.quantityAssumed) return '';
  final name = nutritionAssumedUnitName(row);
  return name.isEmpty ? '' : name[0].toUpperCase() + name.substring(1);
}
