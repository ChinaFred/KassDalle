/// Helpers de parsing CookLang.
///
/// Extrait du fichier gemini_service.dart pour améliorer la lisibilité.
library;

import '../../features/recipes/domain/recipe.dart';
import '../utils/ingredient_name.dart';

// ── Helpers CookLang ──────────────────────────────────────────────────────────

/// Pattern : ingrédient avec quantité obligatoire → `@nom{qty%unit}`.
/// Groupes de capture : 1 = nom, 2 = contenu des accolades.
const kReIngredientWithQty = r'@([^{@#~\n]+)\{([^}]*)\}';

/// Pattern : ingrédient avec ou sans quantité → `@nom` ou `@nom{qty%unit}`.
/// Groupe de capture : 1 = nom.
const kReIngredientAny = r'@([^{@#~\n]+)(?:\{[^}]*\})?';

/// Extrait les métadonnées >> d'un bloc CookLang.
Map<String, String> parseCooklangMeta(String cooklang) {
  final meta = <String, String>{};
  for (final line in cooklang.split('\n')) {
    final trimmed = line.trim();
    if (trimmed.startsWith('>>')) {
      final content = trimmed.substring(2);
      final colonIdx = content.indexOf(':');
      if (colonIdx > 0) {
        final key = content.substring(0, colonIdx).trim().toLowerCase();
        final value = content.substring(colonIdx + 1).trim();
        meta[key] = value;
      }
    }
  }
  return meta;
}

/// Retourne true si le nom ressemble à une température (ex: "180°c") ou commence
/// par un chiffre — ces tokens ne sont pas des ingrédients.
bool _isTemperatureLike(String name) {
  final n = name.trim().toLowerCase();
  return n.contains('°') || RegExp(r'^\d').hasMatch(n);
}

/// Extrait la liste des ingrédients (@nom) d'un bloc CookLang.
/// Résultat trié par ordre d'apparition, sans doublons de nom, sans températures.
List<String> extractIngredients(String cooklang) {
  final re = RegExp(kReIngredientAny);
  final seen = <String>{};
  final result = <String>[];
  for (final m in re.allMatches(cooklang)) {
    final name = m.group(1)!.trim().toLowerCase();
    if (_isTemperatureLike(name)) continue;
    if (seen.add(name)) result.add(name);
  }
  return result;
}

/// Normalise un nom d'ingrédient pour la déduplication.
/// - Met en minuscules.
/// - Normalise les apostrophes typographiques en apostrophe droite.
/// - Normalise les caractères accentués courants.
/// - Supprime le 's' final de chaque mot (singulier/pluriel).
String ingredientKey(String name) {
  // Accents délégués au normaliseur partagé ; la déduplication garde en
  // revanche les espaces et retire le pluriel mot à mot, ce qui lui est propre.
  final s = stripAccentsPreservingWords(
    name
        .toLowerCase()
        .replaceAll('’', "'")
        .replaceAll('‘', "'")
        .replaceAll('ʼ', "'"),
  );
  return s.split(' ').map(depluralizeToken).join(' ');
}

/// Index de recherche d'une recette : les noms de ses ingrédients structurés,
/// en minuscules, sans doublon, dans l'ordre d'apparition.
///
/// **Écrivain unique de `ingredients_index`.** Il en existait trois, qui ne
/// produisaient pas la même chose : les noms normalisés par le référentiel à la
/// création et à la mise à jour, les noms bruts du CookLang à la validation, et
/// les noms du formulaire sans mise en minuscules à la création libre. Une même
/// recette était donc indexée différemment selon la façon dont elle avait été
/// enregistrée, et la recherche par ingrédient répondait en conséquence.
List<String> buildIngredientsIndex(List<RecipeIngredient> ingredients) {
  final seen = <String>{};
  final result = <String>[];
  for (final ingredient in ingredients) {
    final name = ingredient.name.trim().toLowerCase();
    if (name.isEmpty || !seen.add(name)) continue;
    result.add(name);
  }
  return result;
}

/// Extrait la liste structurée des ingrédients avec quantité, unité et catégorie.
/// Triée par ordre d'apparition dans la recette.
/// Les sections CookLang (== Nom ==) sont utilisées comme catégories.
/// Si un même ingrédient apparaît avec des quantités différentes, elles sont
/// combinées (ex : "45 g + une poignée").
List<RecipeIngredient> extractIngredientsStructured(String cooklang) {
  final re = RegExp(kReIngredientWithQty);
  final indexMap = <String, int>{};
  final result = <RecipeIngredient>[];
  String? currentCategory;

  for (final line in cooklang.split('\n')) {
    final trimmed = line.trim();
    if (trimmed.isEmpty || trimmed.startsWith('--')) continue;
    if (trimmed.startsWith('>>')) continue;
    if (trimmed.startsWith('>')) continue;
    if (trimmed.startsWith('==')) {
      final sectionName = trimmed.replaceAll('==', '').trim();
      currentCategory = sectionName.isEmpty ? null : sectionName;
      continue;
    }
    for (final m in re.allMatches(trimmed)) {
      final name = m.group(1)!.trim();
      if (_isTemperatureLike(name)) continue;
      final nameKey = ingredientKey(name);
      // Clé de déduplication sensible à la section : le même ingrédient dans
      // deux sections différentes (ex : sauce soja pour la garniture ET pour
      // la sauce) doit apparaître deux fois dans la liste.
      final dedupeKey = '${currentCategory ?? ""}::$nameKey';
      final parts = (m.group(2) ?? '').split('%');
      final qty = parts.isNotEmpty ? parts[0].trim() : '';
      final unit = parts.length > 1 ? parts[1].trim() : '';
      if (indexMap.containsKey(dedupeKey)) {
        final idx = indexMap[dedupeKey]!;
        final existing = result[idx];
        // Si la nouvelle occurrence a une quantité DIFFÉRENTE de celle déjà connue,
        // c'est un usage distinct dans la même section (ex : sauce soja dans la
        // garniture ET dans la sauce sans section séparée). On crée une entrée
        // supplémentaire plutôt que de la supprimer.
        if (qty.isNotEmpty && existing.qty.isNotEmpty && qty != existing.qty) {
          final altKey = '$dedupeKey|$qty$unit';
          if (!indexMap.containsKey(altKey)) {
            indexMap[altKey] = result.length;
            result.add(
              RecipeIngredient(
                name: name,
                qty: qty,
                unit: unit,
                category: currentCategory,
              ),
            );
          }
        } else {
          // Même quantité ou l'une des deux est vide : garder la première
          // (typiquement la déclaration en liste d'ingrédients).
          if (existing.qty.isEmpty && qty.isNotEmpty) {
            result[idx] = RecipeIngredient(
              name: existing.name,
              qty: qty,
              unit: existing.unit.isNotEmpty ? existing.unit : unit,
              category: existing.category,
            );
          } else if (existing.unit.isEmpty && unit.isNotEmpty) {
            result[idx] = RecipeIngredient(
              name: existing.name,
              qty: existing.qty,
              unit: unit,
              category: existing.category,
            );
          }
        }
      } else {
        indexMap[dedupeKey] = result.length;
        result.add(
          RecipeIngredient(
            name: name,
            qty: qty,
            unit: unit,
            category: currentCategory,
          ),
        );
      }
    }
  }
  return result;
}

/// Extrait le nombre de portions depuis les métadonnées CookLang (>> portions: N).
int? extractPortions(String cooklang) {
  final meta = parseCooklangMeta(cooklang);
  final raw = meta['portions'] ?? meta['servings'];
  if (raw == null) return null;
  return int.tryParse(raw.split(' ').first);
}

int? _parseTimeToMinutes(String? raw) {
  if (raw == null || raw.trim().isEmpty) return null;
  final text = raw.toLowerCase().trim();
  final match = RegExp(r'(\d+)').firstMatch(text);
  if (match == null) return null;
  final value = int.tryParse(match.group(1)!);
  if (value == null) return null;
  if (text.contains('h')) return value * 60;
  return value;
}

RecipeTags extractRecipeTags(String cooklang) {
  final meta = parseCooklangMeta(cooklang);
  return RecipeTags(
    difficulty: meta['difficulte'] ?? meta['difficulté'] ?? meta['difficulty'],
    prepTime: _parseTimeToMinutes(
      meta['temps_preparation'] ??
          meta['temps_préparation'] ??
          meta['prep_time'],
    ),
    cookTime: _parseTimeToMinutes(
      meta['temps_cuisson'] ?? meta['cook_time'] ?? meta['cuisson'],
    ),
    dishTypes: _parseCsvList(meta['dish_types']),
  );
}

/// Parse une valeur CSV en liste de strings normalisés.
List<String> _parseCsvList(String? value) {
  if (value == null || value.trim().isEmpty) return const [];
  return value
      .split(',')
      .map((s) => s.trim().toLowerCase())
      .where((s) => s.isNotEmpty)
      .toList();
}

/// Extrait le titre depuis les métadonnées ou retourne un fallback.
String extractTitle(String cooklang) {
  final meta = parseCooklangMeta(cooklang);
  return meta['titre'] ?? meta['title'] ?? meta['nom'] ?? 'Recette sans titre';
}

/// Extrait le numéro de page depuis les métadonnées CookLang (>> page: N).
int? extractPageNumber(String cooklang) {
  final meta = parseCooklangMeta(cooklang);
  final raw = meta['page'] ?? meta['page_number'];
  if (raw == null) return null;
  return int.tryParse(raw.trim().split(' ').first);
}

/// Interprète un libellé de type de page, d'où qu'il vienne : champ Firestore
/// `page_type` ou métadonnée CookLang `>> page_type:`.
///
/// Ce mapping vivait en deux exemplaires divergents — ici et dans
/// `Recipe._parsePageTypeString`. Le parseur acceptait « ingredient note »,
/// le modèle acceptait « ingredientNote », aucun des deux n'acceptait les
/// deux : la même page changeait de type selon l'endroit où on la lisait.
/// Les trois formes qui circulent sont désormais reconnues au même endroit.
///
/// Un libellé inconnu vaut [PageType.recipe] : mieux vaut une page traitée
/// comme une recette qu'une page qu'on refuse de lire.
PageType parsePageTypeLabel(String raw) {
  return switch (raw.toLowerCase().trim()) {
    'technique' => PageType.technique,
    'equipment' => PageType.equipment,
    'ingredient_note' ||
    'ingredient note' ||
    'ingredientnote' => PageType.ingredientNote,
    'other' => PageType.other,
    _ => PageType.recipe,
  };
}

/// Détecte le type de page depuis les métadonnées (>> page_type: ...).
/// Retourne [PageType.recipe] par défaut si aucun type non-recette n'est détecté.
PageType extractPageType(String content) {
  return parsePageTypeLabel(parseCooklangMeta(content)['page_type'] ?? '');
}

/// Supprime les lignes de métadonnées (>> ...) d'un bloc de contenu.
String stripCooklangMeta(String content) {
  return content
      .split('\n')
      .where((line) => !line.trimLeft().startsWith('>>'))
      .join('\n')
      .trim();
}
