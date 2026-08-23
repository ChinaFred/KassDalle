import '../../../core/services/cooklang_parser.dart' show kReIngredientWithQty;
import '../domain/recipe.dart';
import 'cooklang_preview_helpers.dart';

/// Ce qu'un texte CookLang veut dire, avant toute question d'affichage.
///
/// Cette lecture occupait 120 lignes au milieu d'une méthode de rendu de 430 :
/// elle y était mêlée aux couleurs, aux `Chip` et aux `Wrap`, donc intestable
/// autrement qu'en montant l'écran entier. Elle ne dépend pourtant d'aucun
/// `BuildContext` — c'est de la lecture de texte.
class CooklangPreviewModel {
  /// Entrées `>> clé: valeur`, clés en minuscules.
  final Map<String, String> meta;

  /// Étapes groupées par section `== nom ==`.
  final List<CooklangStepGroup> stepGroups;

  /// Ingrédients trouvés dans le texte, dédupliqués par nom (insensible à la
  /// casse), dans l'ordre de première apparition.
  final List<RecipeIngredient> ingredients;

  const CooklangPreviewModel({
    required this.meta,
    required this.stepGroups,
    required this.ingredients,
  });

  /// Toutes les étapes, sections aplaties.
  List<String> get steps => stepGroups.expand((g) => g.steps).toList();

  /// Vrai dès qu'au moins une section nommée structure la préparation.
  bool get hasSections =>
      stepGroups.length > 1 ||
      (stepGroups.length == 1 && stepGroups.first.name != null);
}

/// Lit un texte CookLang.
///
/// Les règles, telles qu'elles étaient appliquées :
/// * `>> clé: valeur` alimente les métadonnées ;
/// * `== nom ==` ouvre une section, qui vaut à la fois pour les étapes et pour
///   la catégorie des ingrédients qui suivent ;
/// * `-- texte` est un commentaire, ignoré ;
/// * `+ texte` prolonge l'étape précédente au lieu d'en ouvrir une — sauf si
///   celle-ci est une note (`>`) ou une image (`![`) ;
/// * une ligne de note (`>`) ne porte pas d'ingrédient structuré.
CooklangPreviewModel parseCooklangPreview(String text) {
  final meta = <String, String>{};
  // Clé : nom en minuscules — déduplique les ingrédients répétés entre étapes.
  final ingredientMap = <String, RecipeIngredient>{};
  final stepGroups = <CooklangStepGroup>[];

  var currentGroup = CooklangStepGroup(null, []);
  String? currentCategory;

  void collectIngredients(String line) {
    for (final m in RegExp(kReIngredientWithQty).allMatches(line)) {
      final name = m.group(1)!.trim();
      final key = name.toLowerCase();
      if (ingredientMap.containsKey(key)) continue;
      final parts = (m.group(2) ?? '').split('%');
      ingredientMap[key] = RecipeIngredient(
        name: name,
        qty: parts.isNotEmpty ? parts[0] : '',
        unit: parts.length > 1 ? parts[1] : '',
        category: currentCategory,
      );
    }
  }

  void closeGroup() {
    if (currentGroup.steps.isNotEmpty || currentGroup.name != null) {
      stepGroups.add(currentGroup);
    }
  }

  for (final rawLine in text.split('\n')) {
    final line = rawLine.trim();
    if (line.isEmpty || line.startsWith('--')) continue;

    if (line.startsWith('>>')) {
      final rest = line.substring(2).trim();
      final idx = rest.indexOf(':');
      if (idx >= 0) {
        meta[rest.substring(0, idx).trim().toLowerCase()] = rest
            .substring(idx + 1)
            .trim();
      }
      continue;
    }

    if (line.startsWith('==')) {
      // Une section qui ne nomme rien n'est pas une section.
      //
      // `== (sans titre) ==` vient d'un marqueur que le serveur écrivait dans
      // la transcription et que le modèle recopiait consciencieusement. La
      // source est corrigée ; les recettes déjà importées le portent encore, et
      // ce filtre les rend lisibles sans toucher à la base.
      final sectionName = RecipeIngredient.normalizeIngredientCategory(
        line.replaceAll('==', ''),
      );
      closeGroup();
      currentGroup = CooklangStepGroup(sectionName, []);
      currentCategory = sectionName;
      continue;
    }

    // Continuation : « + texte » se recolle à l'étape précédente comme un
    // simple retour à la ligne. Une note ou une image n'accepte pas de suite.
    if (line.startsWith('+ ') &&
        line.length > 2 &&
        currentGroup.steps.isNotEmpty) {
      final lastStep = currentGroup.steps.last;
      if (!lastStep.startsWith('>') && !lastStep.startsWith('![')) {
        currentGroup.steps[currentGroup.steps.length - 1] =
            '$lastStep\n${line.substring(2)}';
        collectIngredients(line);
        continue;
      }
    }

    currentGroup.steps.add(line);
    if (line.startsWith('>')) continue;
    collectIngredients(line);
  }
  closeGroup();

  return CooklangPreviewModel(
    meta: meta,
    stepGroups: stepGroups,
    ingredients: ingredientMap.values.toList(),
  );
}
