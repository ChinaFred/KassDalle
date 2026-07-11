import 'package:flutter/material.dart';

import '../../domain/recipe.dart';

class DressingGuidanceSection extends StatelessWidget {
  final Recipe recipe;
  final int? basePortions;
  final int? selectedPortions;

  const DressingGuidanceSection({
    super.key,
    required this.recipe,
    this.basePortions,
    this.selectedPortions,
  });

  @override
  Widget build(BuildContext context) {
    final portionsText = _portionText(basePortions, selectedPortions);
    final platingStyle = _resolvePlatingStyle(recipe.tags);
    final compositionTips = _buildCompositionTips(recipe);
    final garnishIngredients = _extractDecorationCandidates(recipe.ingredients);
    final finalTouches = _buildFinishingTouches(garnishIngredients);
    final palette = _buildPaletteAdvice(recipe, garnishIngredients);
    final structure = _buildStructureAdvice(recipe.ingredients);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Card(
          margin: EdgeInsets.zero,
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(
                      Icons.style_outlined,
                      color: Theme.of(context).colorScheme.primary,
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        'Aide au dressage',
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                Text(
                  'Objectif: presenter les elements deja cuisines de maniere elegante, lisible et appetissante, sans rejouer la recette etape par etape.',
                ),
                const SizedBox(height: 12),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    _AdviceChip(label: platingStyle),
                    if (portionsText != null) _AdviceChip(label: portionsText),
                    if (recipe.tags.difficulty?.isNotEmpty ?? false)
                      _AdviceChip(label: 'Niveau ${recipe.tags.difficulty}'),
                  ],
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 12),
        _AdviceCard(
          title: 'Construction de l\'assiette',
          icon: Icons.grid_view_outlined,
          items: compositionTips,
        ),
        const SizedBox(height: 12),
        _AdviceCard(
          title: 'Volume et structure',
          icon: Icons.stacked_bar_chart_outlined,
          items: structure,
        ),
        const SizedBox(height: 12),
        _AdviceCard(
          title: 'Couleurs et contrastes',
          icon: Icons.palette_outlined,
          items: palette,
        ),
        const SizedBox(height: 12),
        _AdviceCard(
          title: 'Touches finales',
          icon: Icons.auto_awesome_outlined,
          items: finalTouches,
        ),
      ],
    );
  }
}

class _AdviceCard extends StatelessWidget {
  final String title;
  final IconData icon;
  final List<String> items;

  const _AdviceCard({
    required this.title,
    required this.icon,
    required this.items,
  });

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(icon, size: 18),
                const SizedBox(width: 8),
                Text(title, style: Theme.of(context).textTheme.titleSmall),
              ],
            ),
            const SizedBox(height: 12),
            for (final item in items)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('• '),
                    Expanded(child: Text(item)),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}

List<RecipeIngredient> _extractDecorationCandidates(
  List<RecipeIngredient> ingredients,
) {
  const decoKeywords = <String>[
    'persil',
    'coriandre',
    'basilic',
    'menthe',
    'ciboulette',
    'sesame',
    'graines',
    'zeste',
    'citron',
    'herbe',
    'poivre',
    'piment',
  ];
  return ingredients
      .where((ingredient) {
        final name = ingredient.name.toLowerCase();
        return decoKeywords.any(name.contains);
      })
      .toList(growable: false);
}

String _decorationAlternative(String missingName) {
  final value = missingName.toLowerCase();
  if (value.contains('persil') || value.contains('coriandre')) {
    return 'Utiliser ciboulette ou herbes seches.';
  }
  if (value.contains('citron') || value.contains('zeste')) {
    return 'Ajouter une pointe d\'acide et une herbe fraiche.';
  }
  if (value.contains('sesame') || value.contains('graines')) {
    return 'Remplacer par fruits secs concasses ou chapelure toastee.';
  }
  if (value.contains('piment') || value.contains('poivre')) {
    return 'Apporter le contraste avec paprika doux ou herbes.';
  }
  return 'Accentuer le relief avec une finition plus nette et plus verticale.';
}

class _AdviceChip extends StatelessWidget {
  final String label;

  const _AdviceChip({required this.label});

  @override
  Widget build(BuildContext context) {
    return Chip(
      visualDensity: VisualDensity.compact,
      label: Text(label),
    );
  }
}

String? _portionText(int? basePortions, int? selectedPortions) {
  if (basePortions == null && selectedPortions == null) return null;
  if (basePortions != null && selectedPortions != null) {
    if (basePortions == selectedPortions) {
      return '$selectedPortions portions';
    }
    return '$basePortions -> $selectedPortions portions';
  }
  return '${selectedPortions ?? basePortions} portions';
}

String _resolvePlatingStyle(RecipeTags tags) {
  final dishTypes = tags.dishTypes.map((value) => value.toLowerCase()).toList();
  if (dishTypes.any((value) => value.contains('dessert') || value.contains('patisserie'))) {
    return 'Dressage precis et net';
  }
  if (dishTypes.any((value) => value.contains('soupe'))) {
    return 'Dressage centre sur la surface';
  }
  if (dishTypes.any((value) => value.contains('entree'))) {
    return 'Dressage delicat et aere';
  }
  return 'Dressage genereux mais structure';
}

List<String> _buildCompositionTips(Recipe recipe) {
  final hasSauce = recipe.ingredients.any(_isSauceLikeIngredient);
  final hasCrunch = recipe.ingredients.any(_isCrunchyIngredient);
  final hasProtein = recipe.ingredients.any(_isProteinIngredient);

  return [
    if (hasProtein)
      'Poser l\'element principal en premier, legerement decentre, pour donner un point focal clair a l\'assiette.'
    else
      'Choisir un point focal visuel unique et eviter d\'etaler tous les elements sur toute la surface.',
    'Garder une zone vide visible autour du montage pour que le dressage respire et paraisse plus intentionnel.',
    if (hasSauce)
      'Utiliser la sauce comme outil graphique: trait, virgule ou base discrete sous l\'element principal plutot qu\'un nappage integral.',
    if (hasCrunch)
      'Ajouter les elements croustillants en dernier, sur le dessus ou en bord de volume, pour conserver texture et relief.',
  ];
}

List<String> _buildStructureAdvice(List<RecipeIngredient> ingredients) {
  final hasSmallCuts = ingredients.any((ingredient) {
    final name = ingredient.name.toLowerCase();
    return name.contains('brunoise') ||
        name.contains('emince') ||
        name.contains('julienne') ||
        name.contains('salade');
  });

  return [
    'Jouer sur trois niveaux visuels: une base, un volume principal, puis une finition plus fine pour donner du relief.',
    'Regrouper les accompagnements par petites masses coherentes plutot que de les disperser en petits points sans intention.',
    if (hasSmallCuts)
      'Les elements tailles finement servent de couronne, de lit ou de touche laterale; ils ne doivent pas voler la vedette au coeur du plat.'
    else
      'Si tous les elements sont volumineux, en superposer une partie pour creer de la hauteur et eviter un rendu plat.',
  ];
}

List<String> _buildPaletteAdvice(
  Recipe recipe,
  List<RecipeIngredient> garnishIngredients,
) {
  final colors = <String>[];
  final names = recipe.ingredients.map((ingredient) => ingredient.name.toLowerCase());
  if (names.any((name) => name.contains('tomate') || name.contains('poivron'))) {
    colors.add('rouges');
  }
  if (names.any((name) => name.contains('herbe') || name.contains('persil') || name.contains('basilic'))) {
    colors.add('verts');
  }
  if (names.any((name) => name.contains('carotte') || name.contains('courge') || name.contains('curcuma'))) {
    colors.add('oranges');
  }

  final accentLine = colors.isEmpty
      ? 'Prevoir au moins une couleur d\'accent franche pour casser un ensemble trop beige ou trop uniforme.'
      : 'Mettre en avant les tons ${colors.join(', ')} sans chercher a tout montrer a la fois dans la meme zone.';

  return [
    accentLine,
    'Contraster matieres brillantes et mates: puree lisse, element roti, herbes fraiches ou graines pour une lecture plus riche.',
    if (garnishIngredients.isNotEmpty)
      'Les herbes, zestes ou graines doivent souligner le mouvement du dressage, pas recouvrir toute l\'assiette.',
  ];
}

List<String> _buildFinishingTouches(List<RecipeIngredient> garnishIngredients) {
  final garnishNames = garnishIngredients
      .map((ingredient) => ingredient.name.trim())
      .where((name) => name.isNotEmpty)
      .toSet()
      .toList(growable: false);

  return [
    'Essuyer les bords avant envoi: une assiette propre change immediatement la perception de precision.',
    'Ajouter les finitions fragiles au dernier moment pour garder fraicheur, brillance et nettete.',
    if (garnishNames.isNotEmpty)
      'Finitions detectees dans la recette: ${garnishNames.join(', ')}. Les utiliser avec parcimonie pour signer le plat.',
    'Verifier la lecture a une distance de service: on doit comprendre en un coup d\'oeil ou regarder et ce qui constitue le coeur du plat.',
  ];
}

bool _isSauceLikeIngredient(RecipeIngredient ingredient) {
  final value = ingredient.name.toLowerCase();
  return value.contains('sauce') ||
      value.contains('jus') ||
      value.contains('creme') ||
      value.contains('coulis') ||
      value.contains('vinaigrette') ||
      value.contains('pesto');
}

bool _isCrunchyIngredient(RecipeIngredient ingredient) {
  final value = ingredient.name.toLowerCase();
  return value.contains('graines') ||
      value.contains('noisette') ||
      value.contains('amande') ||
      value.contains('tuile') ||
      value.contains('crumble') ||
      value.contains('chips');
}

bool _isProteinIngredient(RecipeIngredient ingredient) {
  final value = ingredient.name.toLowerCase();
  return value.contains('viande') ||
      value.contains('boeuf') ||
      value.contains('poulet') ||
      value.contains('canard') ||
      value.contains('poisson') ||
      value.contains('saumon') ||
      value.contains('thon') ||
      value.contains('oeuf') ||
      value.contains('tofu');
}
