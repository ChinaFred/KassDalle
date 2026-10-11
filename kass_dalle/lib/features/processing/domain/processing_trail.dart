import 'package:flutter/material.dart';

import 'processing_job.dart';

/// Une étape du traitement, telle qu'elle s'affiche.
class ProcessingStep {
  /// Le code écrit par le serveur dans `current_step`.
  final String code;

  final IconData icon;

  /// Un ou deux mots. Le libellé complet vit dans `formatProcessingStep` et
  /// sert à l'infobulle : c'est lui qui, affiché en clair sur un téléphone
  /// étroit, se coupait une lettre par ligne.
  final String shortLabel;

  const ProcessingStep(this.code, this.icon, this.shortLabel);
}

/// Les étapes qu'un traitement traverse **réellement**, dans l'ordre.
///
/// Elles ne sont pas une liste plausible : elles viennent des branchements de
/// `functions/src/pipeline/recipeProcessor.ts`, qui écrit `current_step` à
/// chaque passage. Une couverture de livre en traverse trois, une page de
/// recette sept. Afficher sept jalons pour une couverture promettrait un
/// travail qui n'a pas lieu, et le fil resterait bloqué aux deux tiers.
///
/// `queued` et `done` encadrent la séquence sans en faire partie : l'un précède
/// le premier jalon, l'autre l'éteint. `image_decode` existe dans le type du
/// serveur mais aucun code ne l'écrit — il n'a donc pas de jalon.
///
/// **Cette liste est un miroir.** Si `STEP_ORDER` ou un branchement change
/// côté serveur, le fil ment sans qu'aucune erreur ne le dise : il montrera un
/// jalon qui n'arrive jamais, ou sautera une étape réellement traversée.
/// `test/processing_trail_test.dart` fige les séquences.
///
/// La traduction est conditionnelle : seule une recette écrite dans une autre
/// langue la traverse. Son jalon n'apparaît que si [translated] est vrai — le
/// champ `translated` du job, posé par le serveur en même temps que
/// `current_step: "translate"`. Sans lui, l'étape tombait hors du fil et la
/// ligne perdait toutes ses icônes le temps de la traduction.
List<ProcessingStep> trailFor(
  ProcessingJobType type, {
  bool translated = false,
}) {
  const envoi = ProcessingStep(
    'import',
    Icons.cloud_download_outlined,
    'Envoi',
  );
  const lecture = ProcessingStep('gemini_call', Icons.auto_awesome, 'Lecture');
  const ecriture = ProcessingStep('save', Icons.save_outlined, 'Écriture');
  const analyse = ProcessingStep('parse', Icons.article_outlined, 'Analyse');
  const traduction = ProcessingStep('translate', Icons.translate, 'Traduction');

  switch (type) {
    case ProcessingJobType.bookCoverScan:
      // Une couverture se lit et s'enregistre : ni analyse de recette, ni
      // balisage, ni enrichissement d'ingrédients.
      return const [envoi, lecture, ecriture];

    case ProcessingJobType.recipeUrlImport:
      // Une page web : lue, lue par l'IA seulement quand elle n'a pas de
      // données structurées (le jalon est alors sauté), analysée, traduite au
      // besoin, balisée, enrichie, enregistrée, puis sa photo passe en
      // modération. `urlImport.ts` traduit APRÈS l'analyse.
      return [
        const ProcessingStep('fetch', Icons.language_outlined, 'Page'),
        lecture,
        analyse,
        if (translated) traduction,
        const ProcessingStep('tagging', Icons.sell_outlined, 'Balisage'),
        const ProcessingStep(
          'normalize',
          Icons.science_outlined,
          'Ingrédients',
        ),
        ecriture,
        const ProcessingStep('design', Icons.photo_outlined, 'Photo'),
      ];

    case ProcessingJobType.recipeScan:
    case ProcessingJobType.bookDocumentScan:
      // `recipeProcessor.ts` traduit AVANT l'analyse.
      return [
        envoi,
        lecture,
        if (translated) traduction,
        analyse,
        const ProcessingStep('design', Icons.photo_library_outlined, 'Photos'),
        const ProcessingStep('tagging', Icons.sell_outlined, 'Balisage'),
        const ProcessingStep(
          'normalize',
          Icons.science_outlined,
          'Ingrédients',
        ),
        ecriture,
      ];
  }
}

/// Position de l'étape courante dans le fil, ou `null` si elle n'y figure pas.
///
/// Le client écrit parfois un libellé en clair dans `current_step` — « Extraction
/// du texte… » pendant un scan. Il ne correspond à aucun code, et l'appelant
/// retombe alors sur le texte plutôt que d'afficher un fil faux.
int? stepIndexIn(List<ProcessingStep> trail, String? currentStep) {
  if (currentStep == null || currentStep.trim().isEmpty) return null;
  final i = trail.indexWhere((s) => s.code == currentStep);
  return i < 0 ? null : i;
}
