import 'package:flutter/material.dart';

import '../../recipes/domain/storage_advice.dart';

/// Rendu du conseil de conservation produit par l'IA.
///
/// Partagé par la feuille du planning et le bandeau de la fiche recette : les
/// deux montrent le même conseil, et un écart de contenu entre les deux serait
/// une divergence invisible — chacun afficherait un texte plausible.
class StorageAdviceDetails extends StatelessWidget {
  final StorageAdvice advice;

  /// Le résumé se répète mal sous un bandeau qui dit déjà la consigne.
  final bool showResume;

  const StorageAdviceDetails({
    super.key,
    required this.advice,
    this.showResume = true,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (showResume && advice.resume.isNotEmpty) ...[
          Text(advice.resume, style: theme.textTheme.bodyMedium),
          const SizedBox(height: 16),
        ],
        storageBlock(theme, 'Refroidissement', advice.refroidissement),
        storageWindowBlock(theme, 'Réfrigérateur', advice.refrigerateur),
        if (advice.congelateur != null)
          storageWindowBlock(theme, 'Congélateur', advice.congelateur!)
        else
          storageBlock(
            theme,
            'Congélation déconseillée',
            advice.congelationDeconseillee ?? '',
          ),
        storageBlock(
          theme,
          'Réchauffage',
          [
            advice.rechauffage.summary,
            advice.rechauffage.conseil,
          ].where((s) => s.trim().isNotEmpty).join('. '),
        ),
        storageListBlock(
          theme,
          'À ajouter au dernier moment',
          advice.aAjouterAuDernierMoment,
        ),
        storageListBlock(
          theme,
          'Ne plus consommer si',
          advice.signesDAlerte,
          color: theme.colorScheme.error,
        ),
      ],
    );
  }
}

/// Un intitulé et son texte, ou rien du tout si le texte est vide.
Widget storageBlock(ThemeData theme, String label, String value) {
  if (value.trim().isEmpty) return const SizedBox.shrink();
  return Padding(
    padding: const EdgeInsets.only(bottom: 14),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: theme.textTheme.labelMedium?.copyWith(
            color: theme.colorScheme.primary,
            fontWeight: FontWeight.w700,
          ),
        ),
        const SizedBox(height: 2),
        Text(value, style: theme.textTheme.bodyMedium),
      ],
    ),
  );
}

/// Durée, contenant et conseil d'un régime de conservation, en une phrase.
Widget storageWindowBlock(ThemeData theme, String label, StorageWindow window) {
  final detail = [
    window.contenant,
    window.conseil,
  ].where((s) => s.trim().isNotEmpty).join(' ');
  final text = [
    window.duree,
    detail,
  ].where((s) => s.trim().isNotEmpty).join('. ');
  return storageBlock(theme, label, text);
}

/// Une liste à puces sous son intitulé, ou rien si elle est vide.
Widget storageListBlock(
  ThemeData theme,
  String label,
  List<String> items, {
  Color? color,
}) {
  if (items.isEmpty) return const SizedBox.shrink();
  return Padding(
    padding: const EdgeInsets.only(bottom: 14),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: theme.textTheme.labelMedium?.copyWith(
            color: color ?? theme.colorScheme.primary,
            fontWeight: FontWeight.w700,
          ),
        ),
        const SizedBox(height: 2),
        for (final item in items)
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Text('• $item', style: theme.textTheme.bodyMedium),
          ),
      ],
    ),
  );
}
