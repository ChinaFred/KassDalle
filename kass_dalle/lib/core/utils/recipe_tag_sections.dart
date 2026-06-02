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
