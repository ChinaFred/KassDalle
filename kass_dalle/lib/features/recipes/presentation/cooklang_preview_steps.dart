import 'package:flutter/material.dart';

import '../../../core/utils/recipe_portion_scaler.dart';
import 'cooklang_preview_helpers.dart';
import '../../../core/theme/app_icon_size.dart';
import '../../../core/widgets/app_network_image.dart';

/// Rendu d'une étape de préparation.
///
/// Cette famille de fonctions — numérotation, images flottantes, notes, jetons
/// en ligne — occupait 500 lignes dans la classe d'état de l'aperçu, alors
/// qu'aucune d'elles ne touchait à cet état. C'étaient des fonctions déguisées
/// en méthodes : les sortir ne change rien à ce qu'elles font, et rend enfin
/// lisible ce que la classe, elle, fait vraiment.

final _reImageLine = RegExp(r'^!\[([^\]]*)\]\(([^)]+)\)$');

/// Dernière étape rendue, pour rattacher une image flottante à celle qui la
/// précède (look-back).
class _RenderedStep {
  final String text;
  final int num;
  const _RenderedStep(this.text, this.num);
}

List<Widget> cooklangBuildFlatSteps(
  BuildContext context,
  List<String> steps, {
  required double scaleFactor,
}) {
  final (widgets, _) = cooklangBuildGroupStepWidgets(
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
(List<Widget>, int) cooklangBuildGroupStepWidgets(
  BuildContext context,
  List<String> steps,
  int startStepNum, {
  required double scaleFactor,
}) {
  final theme = Theme.of(context);
  final widgets = <Widget>[];
  int stepNum = startStepNum;
  _RenderedStep? lastStep;
  int i = 0;

  while (i < steps.length) {
    final step = steps[i];

    if (step.startsWith('>')) {
      widgets.add(
        cooklangBuildNoteWidget(
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
            cooklangBuildFloatRow(
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
              cooklangBuildFloatRow(
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
              cooklangBuildImageWidget(
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
            cooklangBuildImageWidget(
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
          cooklangBuildImageWidget(
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
            child: cooklangBuildStepText(
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
Widget cooklangBuildImageWidget(
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
          child: Semantics(
            image: true,
            // Une illustration de recette n'a pas de texte alternatif saisi :
            // le plus honnête est de dire ce qu'elle est et à quelle étape
            // elle se rattache, plutôt que de rester muette.
            label: 'Illustration de la recette',
            child: ClipRRect(
              borderRadius: BorderRadius.circular(10),
              child: AppNetworkImage(
                imageUrl: url,
                width: imageWidth,
                fit: BoxFit.cover,
                placeholder: (_, _) => SizedBox(
                  width: imageWidth,
                  height: isFloat ? 80 : 160,
                  child: const Center(child: CircularProgressIndicator()),
                ),
                errorWidget: (_, _, _) => Container(
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
        ),
      );
    },
  );
}

/// Ligne flottante : image + étape numérotée côte à côte.
Widget cooklangBuildFloatRow(
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
        child: AppNetworkImage(
          imageUrl: url,
          width: imageWidth,
          fit: BoxFit.cover,
          placeholder: (_, _) => SizedBox(
            width: imageWidth,
            height: 100,
            child: const Center(child: CircularProgressIndicator()),
          ),
          errorWidget: (_, _, _) => Container(
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
            child: cooklangBuildStepText(
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

List<Widget> cooklangBuildSectionedSteps(
  BuildContext context,
  List<CooklangStepGroup> groups, {
  required double scaleFactor,
}) {
  final theme = Theme.of(context);
  int globalStepNum = 0;
  final widgets = <Widget>[];

  for (final group in groups) {
    if (group.steps.isEmpty) continue;

    if (group.name != null) {
      final (stepWidgets, newCount) = cooklangBuildGroupStepWidgets(
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
            side: BorderSide(color: theme.colorScheme.outlineVariant, width: 1),
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
                      size: AppIconSize.inline,
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
      final (stepWidgets, newCount) = cooklangBuildGroupStepWidgets(
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

Widget cooklangBuildNoteWidget(
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
          size: AppIconSize.inline,
          color: theme.colorScheme.secondary,
        ),
        const SizedBox(width: 8),
        Expanded(
          child: cooklangBuildStepText(
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

Widget cooklangBuildStepText(
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
      spans.add(TextSpan(text: normalizedStep.substring(lastEnd, match.start)));
    }
    final token = match.group(0)!;
    String display;
    Color bgColor;

    if (token.startsWith('@')) {
      final name = token.substring(1, token.indexOf('{')).trim();
      final content = token.substring(token.indexOf('{') + 1, token.length - 1);
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

  return Text.rich(
    TextSpan(style: style ?? theme.textTheme.bodyMedium, children: spans),
  );
}
