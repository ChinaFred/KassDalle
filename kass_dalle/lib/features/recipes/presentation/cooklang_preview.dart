import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import '../../../core/services/cooklang_parser.dart' show kReIngredientWithQty;
import '../../../core/utils/recipe_portion_scaler.dart';
import '../../../core/utils/recipe_tag_sections.dart';
import '../domain/recipe.dart';
import 'cooklang_preview_helpers.dart';

final _reImageLine = RegExp(r'^!\[([^\]]*)\]\(([^)]+)\)$');

/// Tracks the last rendered step for look-back image pairing.
class _RenderedStep {
  final String text;
  final int num;
  const _RenderedStep(this.text, this.num);
}

/// Widget d'aperçu CookLang — partagé entre DraftReviewScreen et RecipeDetailScreen.
///
/// Quand [overrideIngredients] est fourni et non vide, la section "Ingrédients"
/// utilise ces données structurées plutôt que celles extraites du texte CookLang.
/// Cela permet de refléter immédiatement les modifications faites dans l'éditeur
/// structuré sans avoir à modifier le texte CookLang.
///
/// [illustrationUrls] : URLs des illustrations de la recette.
/// [onAddIllustration] : callback pour ajouter une illustration (null → bouton masqué).
/// [onTapIllustration] : callback appelé avec l'index cliqué pour la visionneuse.
class CooklangPreview extends StatefulWidget {
  final TextEditingController ctrl;

  /// Liste d'ingrédients structurés à utiliser pour l'affichage.
  /// Quand null ou vide, les ingrédients sont extraits du texte CookLang.
  final List<RecipeIngredient>? overrideIngredients;

  /// URLs des illustrations attachées à la recette.
  final List<String>? illustrationUrls;

  /// Callback pour déclencher l'ajout d'une illustration.
  final VoidCallback? onAddIllustration;

  /// Callback appelé avec l'index de la miniature cliquée.
  final void Function(int index)? onTapIllustration;

  /// Callback appelé avec l'URL de la miniature à supprimer.
  final void Function(String url)? onDeleteIllustration;

  /// Callback optionnel pour déclencher la création de la liste de courses.
  /// Si null, le bouton n'est pas affiché dans la section ingrédients.
  final VoidCallback? onCreateShoppingList;

  /// Callback optionnel pour planifier la recette dans Google Calendar.
  /// Si null, le bouton calendrier n'est pas affiché.
  final VoidCallback? onSchedule;

  /// Types de plat à afficher (viande, dessert, etc.)
  /// Optionnel — si null ou vide, la section n'est pas affichée.
  /// Déprécié: préférer [recipeTags] pour afficher la catégorisation complète.
  final List<String>? dishTypes;

  /// Tags recette complets pour afficher la catégorisation uniforme
  /// (Cuisine, Type de plat, Thème, Occasion).
  final RecipeTags? recipeTags;

  /// Portions source (recette originale) pour calculer le coefficient.
  final int? basePortions;

  /// Portions actuellement affichées (version redimensionnée locale).
  final int? selectedPortions;

  /// Callback de mise à jour des portions affichées.
  final ValueChanged<int>? onSelectedPortionsChanged;

  /// Bornes de saisie/ajustement des portions.
  final int minPortions;
  final int maxPortions;

  const CooklangPreview({
    super.key,
    required this.ctrl,
    this.overrideIngredients,
    this.illustrationUrls,
    this.onAddIllustration,
    this.onTapIllustration,
    this.onDeleteIllustration,
    this.onCreateShoppingList,
    this.onSchedule,
    this.recipeTags,
    this.dishTypes,
    this.basePortions,
    this.selectedPortions,
    this.onSelectedPortionsChanged,
    this.minPortions = 1,
    this.maxPortions = 99,
  });

  @override
  State<CooklangPreview> createState() => _CooklangPreviewState();
}

class _CooklangPreviewState extends State<CooklangPreview> {
  bool _categorizationExpanded = true;
  bool _ingredientsExpanded = true;
  bool _preparationExpanded = true;

  Widget _buildSectionHeader(
    BuildContext context, {
    required IconData icon,
    required String title,
    required bool expanded,
    required VoidCallback onTap,
    Widget? action,
  }) {
    final theme = Theme.of(context);
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 10),
        child: Row(
          children: [
            Icon(icon, size: 20, color: theme.colorScheme.primary),
            const SizedBox(width: 8),
            Text(title, style: theme.textTheme.titleMedium),
            const Spacer(),
            ?action,
            Icon(
              expanded ? Icons.keyboard_arrow_up : Icons.keyboard_arrow_down,
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.ctrl,
      builder: (context, _) => _buildPreview(context, widget.ctrl.text),
    );
  }

  Widget _buildPreview(BuildContext context, String text) {
    if (text.trim().isEmpty) {
      return const Center(child: Text('Aucun contenu à afficher'));
    }

    final overrideIngredients = widget.overrideIngredients;
    final illustrationUrls = widget.illustrationUrls;
    final onAddIllustration = widget.onAddIllustration;
    final onTapIllustration = widget.onTapIllustration;
    final onDeleteIllustration = widget.onDeleteIllustration;
    final onCreateShoppingList = widget.onCreateShoppingList;
    final onSchedule = widget.onSchedule;
    final dishTypes = widget.dishTypes;
    final basePortions = widget.basePortions;
    final selectedPortions = widget.selectedPortions;
    final onSelectedPortionsChanged = widget.onSelectedPortionsChanged;
    final tagSections = widget.recipeTags != null
        ? buildRecipeTagSections(widget.recipeTags!)
        : (dishTypes != null && dishTypes.isNotEmpty
              ? buildRecipeTagSections(RecipeTags(dishTypes: dishTypes))
              : const <RecipeTagSection>[]);

    final scaleFactor =
        basePortions != null &&
            selectedPortions != null &&
            basePortions > 0 &&
            selectedPortions > 0
        ? portionScaleFactor(
            basePortions: basePortions,
            targetPortions: selectedPortions,
          )
        : 1.0;

    final lines = text.split('\n');
    final Map<String, String> meta = {};
    // Clé : nom en minuscules — déduplique les ingrédients répétés entre étapes.
    final Map<String, RecipeIngredient> ingredientMap = {};

    // Groupes de préparation (sections)
    final List<CooklangStepGroup> stepGroups = [];
    CooklangStepGroup currentGroup = CooklangStepGroup(null, []);
    // Catégorie courante pour les ingrédients (déterminée par les == sections ==)
    String? currentIngCategory;

    for (final line in lines) {
      final trimmed = line.trim();
      if (trimmed.isEmpty) continue;
      if (trimmed.startsWith('--')) continue;
      if (trimmed.startsWith('>>')) {
        final rest = trimmed.substring(2).trim();
        final idx = rest.indexOf(':');
        if (idx >= 0) {
          meta[rest.substring(0, idx).trim().toLowerCase()] = rest
              .substring(idx + 1)
              .trim();
        }
      } else if (trimmed.startsWith('==')) {
        // Nouvelle section
        final sectionName = trimmed.replaceAll('==', '').trim();
        if (currentGroup.steps.isNotEmpty || currentGroup.name != null) {
          stepGroups.add(currentGroup);
        }
        currentGroup = CooklangStepGroup(
          sectionName.isEmpty ? null : sectionName,
          [],
        );
        // Met aussi à jour la catégorie des ingrédients
        currentIngCategory = sectionName.isEmpty ? null : sectionName;
      } else {
        // Continuation: + text → append to the last step (visual line break)
        if (trimmed.startsWith('+ ') &&
            trimmed.length > 2 &&
            currentGroup.steps.isNotEmpty) {
          final lastStep = currentGroup.steps.last;
          // Only merge into regular steps (not notes/images)
          if (!lastStep.startsWith('>') && !lastStep.startsWith('![')) {
            currentGroup.steps[currentGroup.steps.length - 1] =
                '$lastStep\n${trimmed.substring(2)}';
            // Parse inline ingredients from the continuation line
            if (!trimmed.startsWith('>')) {
              final re = RegExp(kReIngredientWithQty);
              for (final m in re.allMatches(trimmed)) {
                final name = m.group(1)!.trim();
                final key = name.toLowerCase();
                if (!ingredientMap.containsKey(key)) {
                  final parts = (m.group(2) ?? '').split('%');
                  ingredientMap[key] = RecipeIngredient(
                    name: name,
                    qty: parts.isNotEmpty ? parts[0] : '',
                    unit: parts.length > 1 ? parts[1] : '',
                    category: currentIngCategory,
                  );
                }
              }
            }
            continue;
          }
        }
        currentGroup.steps.add(trimmed);
        // Les lignes notes (> texte) ne contiennent pas d'ingrédients structurés
        if (trimmed.startsWith('>')) continue;
        final re = RegExp(kReIngredientWithQty);
        for (final m in re.allMatches(trimmed)) {
          final name = m.group(1)!.trim();
          final key = name.toLowerCase();
          if (!ingredientMap.containsKey(key)) {
            final parts = (m.group(2) ?? '').split('%');
            ingredientMap[key] = RecipeIngredient(
              name: name,
              qty: parts.isNotEmpty ? parts[0] : '',
              unit: parts.length > 1 ? parts[1] : '',
              category: currentIngCategory,
            );
          }
        }
      }
    }
    if (currentGroup.steps.isNotEmpty || currentGroup.name != null) {
      stepGroups.add(currentGroup);
    }

    // Compatibilité avec l'existant : liste plate des étapes
    final List<String> steps = stepGroups.expand((g) => g.steps).toList();
    final hasSections =
        stepGroups.length > 1 ||
        (stepGroups.length == 1 && stepGroups.first.name != null);
    // Liste unifiée pour l'affichage : overrideIngredients si fourni, sinon
    // construit depuis le parsing CookLang (avec catégories de sections).
    final List<RecipeIngredient> displayIngredients =
        (overrideIngredients != null && overrideIngredients.isNotEmpty)
        ? overrideIngredients
        : ingredientMap.values.toList();

    final scaledDisplayIngredients = scaleRecipeIngredients(
      displayIngredients,
      scaleFactor,
    );

    // Groupement par catégorie (sections)
    final bool hasCategoryData = displayIngredients.any(
      (i) => i.category != null && i.category!.isNotEmpty,
    );

    // Ordre des catégories tel qu'elles apparaissent dans la liste
    final List<String?> categoryOrder = [];
    for (final ing in scaledDisplayIngredients) {
      final cat = (ing.category?.isEmpty ?? true) ? null : ing.category;
      if (!categoryOrder.contains(cat)) categoryOrder.add(cat);
    }

    final theme = Theme.of(context);

    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // ── Chips méta + illustrations ────────────────────────────────────
          Builder(
            builder: (context) {
              final hasPortions =
                  selectedPortions != null ||
                  meta.containsKey('portions') ||
                  meta.containsKey('servings');
              final hasPrepTime = meta.containsKey('prep_time');
              final hasCookTime = meta.containsKey('cook_time');
              final illus = illustrationUrls ?? const <String>[];
              final hasIllus = illus.isNotEmpty;
              final hasAdd = onAddIllustration != null;
              if (!hasPortions &&
                  !hasPrepTime &&
                  !hasCookTime &&
                  !hasIllus &&
                  !hasAdd) {
                return const SizedBox.shrink();
              }
              return Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    if (hasPortions)
                      _buildPortionsChip(
                        context,
                        selectedPortions: selectedPortions,
                        fallback: meta['portions'] ?? meta['servings'],
                        onChanged: onSelectedPortionsChanged,
                        minPortions: widget.minPortions,
                        maxPortions: widget.maxPortions,
                      ),
                    if (hasPrepTime)
                      Chip(
                        label: Text('Prép. ${meta['prep_time']} min'),
                        avatar: const Icon(Icons.timer_outlined, size: 16),
                      ),
                    if (hasCookTime)
                      Chip(
                        label: Text('Cuisson ${meta['cook_time']} min'),
                        avatar: const Icon(
                          Icons.local_fire_department_outlined,
                          size: 16,
                        ),
                      ),
                    // Miniatures illustrations
                    for (int i = 0; i < illus.length; i++)
                      CooklangIllustrationThumb(
                        url: illus[i],
                        onTap: () => onTapIllustration?.call(i),
                        onDelete: onDeleteIllustration != null
                            ? () => onDeleteIllustration(illus[i])
                            : null,
                      ),
                    // Bouton ajout
                    if (hasAdd)
                      InkWell(
                        onTap: onAddIllustration,
                        borderRadius: BorderRadius.circular(8),
                        child: Container(
                          width: 48,
                          height: 48,
                          decoration: BoxDecoration(
                            border: Border.all(
                              color: theme.colorScheme.outline.withAlpha(80),
                              width: 1.5,
                            ),
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Icon(
                            Icons.add_a_photo_outlined,
                            size: 20,
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ),
                  ],
                ),
              );
            },
          ),
          if (meta.isNotEmpty) const SizedBox(height: 8),
          if (tagSections.isNotEmpty) ...[
            _buildSectionHeader(
              context,
              icon: Icons.category_outlined,
              title: 'Catégorisation',
              expanded: _categorizationExpanded,
              onTap: () => setState(
                () => _categorizationExpanded = !_categorizationExpanded,
              ),
            ),
            if (_categorizationExpanded)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: tagSections.map((section) {
                    return Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            section.label,
                            style: theme.textTheme.labelMedium?.copyWith(
                              color: theme.colorScheme.primary,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Wrap(
                            spacing: 6,
                            runSpacing: 4,
                            children: section.values
                                .map(
                                  (value) => Chip(
                                    label: Text(value),
                                    backgroundColor:
                                        theme.colorScheme.tertiaryContainer,
                                    labelStyle: TextStyle(
                                      fontSize: 11,
                                      color:
                                          theme.colorScheme.onTertiaryContainer,
                                    ),
                                    visualDensity: VisualDensity.compact,
                                    materialTapTargetSize:
                                        MaterialTapTargetSize.shrinkWrap,
                                  ),
                                )
                                .toList(),
                          ),
                        ],
                      ),
                    );
                  }).toList(),
                ),
              ),
            const Divider(height: 16),
          ],
          if (scaledDisplayIngredients.isNotEmpty) ...[
            _buildSectionHeader(
              context,
              icon: Icons.format_list_bulleted,
              title: 'Ingrédients',
              expanded: _ingredientsExpanded,
              onTap: () =>
                  setState(() => _ingredientsExpanded = !_ingredientsExpanded),
              action: (onCreateShoppingList != null || onSchedule != null)
                  ? Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (onSchedule != null)
                          IconButton(
                            onPressed: onSchedule,
                            icon: const Icon(Icons.calendar_month_outlined),
                            tooltip: 'Planifier',
                            iconSize: 20,
                            visualDensity: VisualDensity.compact,
                            color: theme.colorScheme.primary,
                          ),
                        if (onCreateShoppingList != null)
                          IconButton(
                            onPressed: onCreateShoppingList,
                            icon: const Icon(Icons.shopping_cart_outlined),
                            tooltip: 'Liste de courses',
                            iconSize: 20,
                            visualDensity: VisualDensity.compact,
                            color: theme.colorScheme.primary,
                          ),
                      ],
                    )
                  : null,
            ),
            if (_ingredientsExpanded) ...[
              const SizedBox(height: 8),
              if (hasCategoryData) ...[
                // Affichage groupé par catégorie / section
                ...categoryOrder.map((cat) {
                  final group = scaledDisplayIngredients
                      .where(
                        (i) => cat == null
                            ? (i.category == null || i.category!.isEmpty)
                            : i.category == cat,
                      )
                      .toList();
                  if (group.isEmpty) return const SizedBox.shrink();
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (cat != null) ...[
                        const SizedBox(height: 10),
                        Text(
                          cat,
                          style: theme.textTheme.labelLarge?.copyWith(
                            color: theme.colorScheme.primary,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const SizedBox(height: 4),
                      ],
                      Wrap(
                        spacing: 8,
                        runSpacing: 4,
                        children: group.map((ing) {
                          return Chip(
                            label: Text(
                              cooklangFormatIngredient(
                                ing.qty,
                                ing.unit,
                                ing.name,
                              ),
                            ),
                            backgroundColor:
                                theme.colorScheme.secondaryContainer,
                          );
                        }).toList(),
                      ),
                    ],
                  );
                }),
              ] else ...[
                // Affichage plat (pas de sections)
                Wrap(
                  spacing: 8,
                  runSpacing: 4,
                  children: scaledDisplayIngredients.map((ing) {
                    return Chip(
                      label: Text(
                        cooklangFormatIngredient(ing.qty, ing.unit, ing.name),
                      ),
                      backgroundColor: theme.colorScheme.secondaryContainer,
                    );
                  }).toList(),
                ),
              ],
            ], // _ingredientsExpanded
            const Divider(height: 16),
          ],
          if (steps.isNotEmpty) ...[
            _buildSectionHeader(
              context,
              icon: Icons.menu_book_outlined,
              title: 'Préparation',
              expanded: _preparationExpanded,
              onTap: () =>
                  setState(() => _preparationExpanded = !_preparationExpanded),
            ),
            if (_preparationExpanded) ...[
              const SizedBox(height: 8),
              if (hasSections)
                ..._buildSectionedSteps(
                  context,
                  stepGroups,
                  scaleFactor: scaleFactor,
                )
              else
                ..._buildFlatSteps(
                  context,
                  steps,
                  scaleFactor: scaleFactor,
                ),
            ], // _preparationExpanded
          ],
        ],
      ),
    );
  }

  Widget _buildPortionsChip(
    BuildContext context, {
    required int? selectedPortions,
    required String? fallback,
    required ValueChanged<int>? onChanged,
    required int minPortions,
    required int maxPortions,
  }) {
    final fallbackInt = _extractFirstInt(fallback);
    final displayed = selectedPortions ?? fallbackInt;
    if (displayed == null) {
      return Chip(
        label: Text('${fallback ?? ''} portions'),
        avatar: const Icon(Icons.people_outline, size: 16),
      );
    }

    if (onChanged == null) {
      return Chip(
        label: Text('$displayed portions'),
        avatar: const Icon(Icons.people_outline, size: 16),
      );
    }

    return Chip(
      avatar: const Icon(Icons.people_outline, size: 16),
      label: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _tinyPortionButton(
            icon: Icons.remove,
            enabled: displayed > minPortions,
            onTap: () => onChanged(displayed - 1),
          ),
          const SizedBox(width: 6),
          InkWell(
            borderRadius: BorderRadius.circular(6),
            onTap: () async {
              final input = await _showPortionsInputDialog(
                context,
                current: displayed,
                minPortions: minPortions,
                maxPortions: maxPortions,
              );
              if (!mounted || input == null || input == displayed) return;
              onChanged(input);
            },
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
              child: Text(
                '$displayed portions',
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  fontWeight: FontWeight.w500,
                  decoration: TextDecoration.underline,
                ),
              ),
            ),
          ),
          const SizedBox(width: 6),
          _tinyPortionButton(
            icon: Icons.add,
            enabled: displayed < maxPortions,
            onTap: () => onChanged(displayed + 1),
          ),
        ],
      ),
    );
  }

  Widget _tinyPortionButton({
    required IconData icon,
    required bool enabled,
    required VoidCallback onTap,
  }) {
    return InkResponse(
      onTap: enabled ? onTap : null,
      radius: 14,
      child: Opacity(
        opacity: enabled ? 1 : 0.35,
        child: Container(
          width: 20,
          height: 20,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            border: Border.all(color: Theme.of(context).colorScheme.outline),
            borderRadius: BorderRadius.circular(4),
          ),
          child: Icon(icon, size: 14),
        ),
      ),
    );
  }

  Future<int?> _showPortionsInputDialog(
    BuildContext context, {
    required int current,
    required int minPortions,
    required int maxPortions,
  }) async {
    final ctrl = TextEditingController(text: '$current');
    final result = await showDialog<int>(
      context: context,
      builder: (ctx) {
        String? errorText;

        int? validate() {
          final parsed = int.tryParse(ctrl.text.trim());
          if (parsed == null) {
            errorText = 'Saisis un nombre entier.';
            return null;
          }
          if (parsed < minPortions || parsed > maxPortions) {
            errorText =
                'Le nombre de portions doit être entre $minPortions et $maxPortions.';
            return null;
          }
          errorText = null;
          return parsed;
        }

        return StatefulBuilder(
          builder: (ctx, setStateDialog) => AlertDialog(
            title: const Text('Nombre de portions'),
            content: TextField(
              controller: ctrl,
              keyboardType: TextInputType.number,
              autofocus: true,
              decoration: InputDecoration(
                labelText: 'Portions',
                hintText: '$minPortions - $maxPortions',
                errorText: errorText,
              ),
              onChanged: (_) {
                if (errorText != null) {
                  setStateDialog(() => errorText = null);
                }
              },
              onSubmitted: (_) {
                final value = validate();
                if (value == null) {
                  setStateDialog(() {});
                  return;
                }
                Navigator.of(ctx).pop(value);
              },
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(ctx).pop(),
                child: const Text('Annuler'),
              ),
              FilledButton(
                onPressed: () {
                  final value = validate();
                  if (value == null) {
                    setStateDialog(() {});
                    return;
                  }
                  Navigator.of(ctx).pop(value);
                },
                child: const Text('Valider'),
              ),
            ],
          ),
        );
      },
    );
    ctrl.dispose();
    return result;
  }

  int? _extractFirstInt(String? raw) {
    if (raw == null || raw.trim().isEmpty) return null;
    final match = RegExp(r'\d+').firstMatch(raw);
    if (match == null) return null;
    return int.tryParse(match.group(0)!);
  }

  List<Widget> _buildFlatSteps(
    BuildContext context,
    List<String> steps, {
    required double scaleFactor,
  }) {
    final (widgets, _) = _buildGroupStepWidgets(
      context,
      steps,
      0,
      scaleFactor: scaleFactor,
    );
    return widgets;
  }

  /// Construit une liste de widgets pour un groupe d'étapes.
  /// Retourne (widgets, nouveauCompteur) en gérant les images flottantes.
  /// Les images left/right sont associées à l'étape PRÉCÉDENTE (look-back).
  (List<Widget>, int) _buildGroupStepWidgets(
    BuildContext context,
    List<String> steps,
    int startStepNum,
    {
    required double scaleFactor,
  }
  ) {
    final theme = Theme.of(context);
    final widgets = <Widget>[];
    int stepNum = startStepNum;
    _RenderedStep? lastStep;
    int i = 0;

    while (i < steps.length) {
      final step = steps[i];

      if (step.startsWith('>')) {
        widgets.add(
          _buildNoteWidget(
            context,
            step.substring(1).trim(),
            scaleFactor: scaleFactor,
          ),
        );
        lastStep = null;
        i++;
        continue;
      }

      final imgMatch = _reImageLine.firstMatch(step);
      if (imgMatch != null) {
        final posAndWidth = imgMatch.group(1)!.trim().toLowerCase();
        final url = imgMatch.group(2)!;
        final pipeIdx = posAndWidth.indexOf('|');
        final pos = pipeIdx >= 0
            ? posAndWidth.substring(0, pipeIdx).trim()
            : posAndWidth;
        final widthStr = pipeIdx >= 0
            ? posAndWidth.substring(pipeIdx + 1).trim().replaceAll('%', '')
            : null;
        final widthPct =
            (widthStr != null ? double.tryParse(widthStr) : null) ?? 30.0;

        if (pos == 'left' || pos == 'right') {
          if (lastStep != null) {
            // Look-back : remplace l'étape précédente par une ligne flottante.
            widgets.removeLast();
            widgets.add(
              _buildFloatRow(
                context,
                url: url,
                isLeft: pos == 'left',
                stepText: lastStep.text,
                stepNum: lastStep.num,
                widthPct: widthPct,
                  scaleFactor: scaleFactor,
              ),
            );
            lastStep = null;
          } else if (i + 1 < steps.length) {
            // Fallback look-ahead : image placée avant l'étape en source.
            final nextStep = steps[i + 1];
            if (!nextStep.startsWith('>') &&
                _reImageLine.firstMatch(nextStep) == null) {
              stepNum++;
              final rawStep = nextStep.replaceFirst(
                RegExp(r'^\d+[\.)\-]\s*'),
                '',
              );
              widgets.add(
                _buildFloatRow(
                  context,
                  url: url,
                  isLeft: pos == 'left',
                  stepText: rawStep,
                  stepNum: stepNum,
                  widthPct: widthPct,
                  scaleFactor: scaleFactor,
                ),
              );
              lastStep = null;
              i += 2;
              continue;
            } else {
              widgets.add(
                _buildImageWidget(
                  context,
                  url: url,
                  position: pos,
                  widthPct: widthPct,
                ),
              );
              lastStep = null;
            }
          } else {
            widgets.add(
              _buildImageWidget(
                context,
                url: url,
                position: pos,
                widthPct: widthPct,
              ),
            );
            lastStep = null;
          }
        } else {
          widgets.add(
            _buildImageWidget(
              context,
              url: url,
              position: pos,
              widthPct: widthPct,
            ),
          );
          lastStep = null;
        }
        i++;
        continue;
      }

      stepNum++;
      final rawStep = step.replaceFirst(RegExp(r'^\d+[\.)\-]\s*'), '');
      final stepWidget = Padding(
        padding: const EdgeInsets.only(bottom: 14),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            CircleAvatar(
              radius: 13,
              backgroundColor: theme.colorScheme.primaryContainer,
              child: Text(
                '$stepNum',
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.bold,
                  color: theme.colorScheme.onPrimaryContainer,
                ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: _buildStepText(
                context,
                rawStep,
                scaleFactor: scaleFactor,
              ),
            ),
          ],
        ),
      );
      widgets.add(stepWidget);
      lastStep = _RenderedStep(rawStep, stepNum);
      i++;
    }

    return (widgets, stepNum);
  }

  /// Image positionnée : after = centrée, left/right = largeur définie par [widthPct].
  Widget _buildImageWidget(
    BuildContext context, {
    required String url,
    required String position,
    double? widthPct,
  }) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final isFloat = position == 'left' || position == 'right';
        final isLeft = position == 'left';
        final double imageWidth;
        if (isFloat) {
          imageWidth = constraints.maxWidth * (widthPct ?? 30.0) / 100;
        } else {
          imageWidth = (constraints.maxWidth * (widthPct ?? 65.0) / 100).clamp(
            0.0,
            320.0,
          );
        }
        return Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: Align(
            alignment: isFloat
                ? (isLeft ? Alignment.centerLeft : Alignment.centerRight)
                : Alignment.center,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(10),
              child: CachedNetworkImage(
                imageUrl: url,
                width: imageWidth,
                fit: BoxFit.cover,
                placeholder: (_, __) => SizedBox(
                  width: imageWidth,
                  height: isFloat ? 80 : 160,
                  child: const Center(child: CircularProgressIndicator()),
                ),
                errorWidget: (_, __, ___) => Container(
                  width: imageWidth,
                  height: isFloat ? 60 : 80,
                  decoration: BoxDecoration(
                    color: Colors.grey.shade200,
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: const Center(child: Icon(Icons.broken_image_outlined)),
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  /// Ligne flottante : image + étape numérotée côte à côte.
  Widget _buildFloatRow(
    BuildContext context, {
    required String url,
    required bool isLeft,
    required String stepText,
    required int stepNum,
    double widthPct = 30.0,
    required double scaleFactor,
  }) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final theme = Theme.of(context);
        final imageWidth = constraints.maxWidth * widthPct / 100;

        final imageWidget = ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child: CachedNetworkImage(
            imageUrl: url,
            width: imageWidth,
            fit: BoxFit.cover,
            placeholder: (_, __) => SizedBox(
              width: imageWidth,
              height: 100,
              child: const Center(child: CircularProgressIndicator()),
            ),
            errorWidget: (_, __, ___) => Container(
              width: imageWidth,
              height: 80,
              decoration: BoxDecoration(
                color: Colors.grey.shade200,
                borderRadius: BorderRadius.circular(8),
              ),
              child: const Center(child: Icon(Icons.broken_image_outlined)),
            ),
          ),
        );

        final stepWidget = Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            CircleAvatar(
              radius: 13,
              backgroundColor: theme.colorScheme.primaryContainer,
              child: Text(
                '$stepNum',
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.bold,
                  color: theme.colorScheme.onPrimaryContainer,
                ),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: _buildStepText(
                context,
                stepText,
                scaleFactor: scaleFactor,
              ),
            ),
          ],
        );

        return Padding(
          padding: const EdgeInsets.only(bottom: 14),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: isLeft
                ? [
                    imageWidget,
                    const SizedBox(width: 12),
                    Expanded(child: stepWidget),
                  ]
                : [
                    Expanded(child: stepWidget),
                    const SizedBox(width: 12),
                    imageWidget,
                  ],
          ),
        );
      },
    );
  }

  List<Widget> _buildSectionedSteps(
    BuildContext context,
    List<CooklangStepGroup> groups, {
    required double scaleFactor,
  }
  ) {
    final theme = Theme.of(context);
    int globalStepNum = 0;
    final widgets = <Widget>[];

    for (final group in groups) {
      if (group.steps.isEmpty) continue;

      if (group.name != null) {
        final (stepWidgets, newCount) = _buildGroupStepWidgets(
          context,
          group.steps,
          globalStepNum,
          scaleFactor: scaleFactor,
        );
        globalStepNum = newCount;
        widgets.add(
          Card(
            margin: const EdgeInsets.only(bottom: 12),
            color: theme.colorScheme.surfaceContainerLow,
            elevation: 0,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
              side: BorderSide(
                color: theme.colorScheme.outlineVariant,
                width: 1,
              ),
            ),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(
                        Icons.label_outline,
                        size: 16,
                        color: theme.colorScheme.primary,
                      ),
                      const SizedBox(width: 6),
                      Text(
                        group.name!,
                        style: theme.textTheme.labelLarge?.copyWith(
                          color: theme.colorScheme.primary,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  ...stepWidgets,
                ],
              ),
            ),
          ),
        );
      } else {
        final (stepWidgets, newCount) = _buildGroupStepWidgets(
          context,
          group.steps,
          globalStepNum,
          scaleFactor: scaleFactor,
        );
        globalStepNum = newCount;
        widgets.addAll(stepWidgets);
      }
    }
    return widgets;
  }

  Widget _buildNoteWidget(
    BuildContext context,
    String text, {
    required double scaleFactor,
  }) {
    final theme = Theme.of(context);
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: theme.colorScheme.secondaryContainer.withAlpha(120),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color: theme.colorScheme.secondary.withAlpha(80),
          width: 1,
        ),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            Icons.tips_and_updates_outlined,
            size: 16,
            color: theme.colorScheme.secondary,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: _buildStepText(
              context,
              text,
              scaleFactor: scaleFactor,
              style: theme.textTheme.bodyMedium?.copyWith(
                fontStyle: FontStyle.italic,
                color: theme.colorScheme.onSecondaryContainer,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildStepText(
    BuildContext context,
    String step, {
    TextStyle? style,
    double scaleFactor = 1.0,
  }) {
    final theme = Theme.of(context);
    final spans = <InlineSpan>[];
    // Normalise les timers écrits en texte brut (ex: "3%minutes" → "~{3%minutes}")
    // et les timers nommés (ex: "~cuisson{3%minutes}" → reconnus par la regex)
    final normalizedStep = cooklangNormalizeStepTimers(step);
    // Regex : ingrédients @, équipements #, timers ~ (anonymes ou nommés)
    final re = RegExp(
      r'(@[^{@#~]+\{[^}]*\}|#[^{@#~]+\{[^}]*\}|~[^{@#~\s]*\{[^}]*\})',
    );
    int lastEnd = 0;

    for (final match in re.allMatches(normalizedStep)) {
      if (match.start > lastEnd) {
        spans.add(
          TextSpan(text: normalizedStep.substring(lastEnd, match.start)),
        );
      }
      final token = match.group(0)!;
      String display;
      Color bgColor;

      if (token.startsWith('@')) {
        final name = token.substring(1, token.indexOf('{')).trim();
        final content = token.substring(
          token.indexOf('{') + 1,
          token.length - 1,
        );
        final parts = content.split('%');
        final rawQty = parts.isNotEmpty ? parts[0] : '';
        final qty = scaleQuantityText(rawQty, scaleFactor);
        final unit = parts.length > 1 ? parts[1] : '';
        display = cooklangFormatIngredient(qty, unit, name);
        bgColor = theme.colorScheme.primaryContainer;
      } else if (token.startsWith('#')) {
        display = token.substring(1, token.indexOf('{')).trim();
        bgColor = theme.colorScheme.tertiaryContainer;
      } else {
        // Timer : extrait le contenu entre { et } (gère ~{...} et ~nom{...})
        final braceIdx = token.indexOf('{');
        final content = token.substring(braceIdx + 1, token.length - 1);
        display = cooklangFormatTimer(content);
        bgColor = theme.colorScheme.secondaryContainer;
      }

      spans.add(
        WidgetSpan(
          alignment: PlaceholderAlignment.middle,
          child: Container(
            margin: const EdgeInsets.symmetric(horizontal: 2),
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
            decoration: BoxDecoration(
              color: bgColor,
              borderRadius: BorderRadius.circular(4),
            ),
            child: Text(
              display,
              style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500),
            ),
          ),
        ),
      );

      lastEnd = match.end;
    }

    if (lastEnd < normalizedStep.length) {
      spans.add(TextSpan(text: normalizedStep.substring(lastEnd)));
    }

    return RichText(
      text: TextSpan(
        style: style ?? theme.textTheme.bodyMedium,
        children: spans,
      ),
    );
  }
}
