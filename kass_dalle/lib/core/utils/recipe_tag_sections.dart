import '../../features/recipes/domain/meal_role.dart';
import '../../features/recipes/domain/recipe.dart';

class RecipeTagSection {
  final String label;
  final List<String> values;

  const RecipeTagSection({required this.label, required this.values});
}

List<RecipeTagSection> buildRecipeTagSections(RecipeTags tags) {
  final cuisines = _normalizeTags(tags.cuisines);
  final dishTypes = _normalizeTags(tags.dishTypes);
  final themes = _normalizeTags(tags.themes);
  final occasions = _normalizeTags(tags.occasions);

  final sections = <RecipeTagSection>[];
  if (cuisines.isNotEmpty) {
    sections.add(RecipeTagSection(label: 'Cuisine', values: cuisines));
  }
  if (dishTypes.isNotEmpty) {
    sections.add(RecipeTagSection(label: 'Type de plat', values: dishTypes));
  }
  if (themes.isNotEmpty) {
    sections.add(RecipeTagSection(label: 'Thème', values: themes));
  }
  if (occasions.isNotEmpty) {
    sections.add(RecipeTagSection(label: 'Occasion', values: occasions));
  }
  // Le style : libellés complets, dans l'ordre du vocabulaire. Une valeur
  // hors vocabulaire n'a pas de libellé : elle n'est pas affichée, plutôt que
  // de montrer une clé technique au lecteur.
  final styles = orderedRecipeStyles(
    tags.styles.map((s) => s.trim()).where(kRecipeStyles.contains),
  );
  if (styles.isNotEmpty) {
    sections.add(
      RecipeTagSection(
        label: 'Style',
        values: [for (final s in styles) recipeStyleLabel(s)],
      ),
    );
  }
  // En dernier : la liste des recettes ne montre que les deux premières
  // sections, et Cuisine + Type de plat y disent plus qu'un mot sur cinq.
  final mealRole = tags.mealRole?.trim() ?? '';
  if (mealRole.isNotEmpty) {
    sections.add(
      RecipeTagSection(
        label: 'Rôle dans un repas',
        values: [mealRoleLabel(mealRole)],
      ),
    );
  }
  // Protéine et féculent : seulement pour un plat ou un accompagnement, les
  // seuls rôles qui les portent.
  if (tags.carriesMainIngredients) {
    final protein = tags.mainProtein?.trim() ?? '';
    if (protein.isNotEmpty) {
      sections.add(
        RecipeTagSection(
          label: 'Protéine principale',
          values: [mainProteinLabel(protein)],
        ),
      );
    }
    final starch = tags.mainStarch?.trim() ?? '';
    if (starch.isNotEmpty) {
      sections.add(
        RecipeTagSection(
          label: 'Féculent principal',
          values: [mainStarchLabel(starch)],
        ),
      );
    }
    // Ce que la recette apporte : « Apporte : Protéine, Légume ». Le planning
    // propose un accompagnement pour ce qui manque.
    final contains = orderedMealContains(
      tags.contains.map((c) => c.trim()).where((c) => c.isNotEmpty),
    );
    if (contains.isNotEmpty) {
      sections.add(
        RecipeTagSection(
          label: 'Apporte',
          values: [for (final c in contains) mealContainsLabel(c)],
        ),
      );
    }
  }
  return sections;
}

String? buildRecipeTagSummary(
  RecipeTags tags, {
  int maxSections = 2,
  int maxValuesPerSection = 2,
}) {
  final sections = buildRecipeTagSections(tags);
  if (sections.isEmpty) return null;

  final compact = sections
      .take(maxSections)
      .map((section) {
        final visibleValues = section.values.take(maxValuesPerSection).toList();
        final hasMore = section.values.length > visibleValues.length;
        final suffix = hasMore ? '...' : '';
        return '${section.label}: ${visibleValues.join(', ')}$suffix';
      })
      .join(' | ');

  return compact.isEmpty ? null : compact;
}

List<String> _normalizeTags(List<String> values) {
  final out = <String>[];
  final seen = <String>{};
  for (final value in values) {
    final trimmed = value.trim();
    if (trimmed.isEmpty) continue;
    final key = trimmed.toLowerCase();
    if (seen.add(key)) {
      out.add(trimmed);
    }
  }
  return out;
}
