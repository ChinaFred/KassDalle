import 'package:flutter/material.dart';

import '../domain/experiment.dart';
import 'experiments/image_import_screen.dart';

/// La liste des expériences du bac à sable.
///
/// Ajouter une expérience, c'est ajouter une entrée ici et un écran sous
/// `experiments/`. Rien d'autre : ni route, ni tuile de menu.
final List<Experiment> kExperiments = <Experiment>[
  Experiment(
    id: 'image-import',
    title: 'Importation d\'image',
    subtitle:
        'Portée dans l\'import de livre — cette copie a pu diverger depuis. '
        'Choisir un fichier ou prendre une photo, puis valider chaque étape '
        'du traitement avant d\'ajouter la suivante.',
    icon: Icons.add_photo_alternate_outlined,
    builder: (_) => const SandboxImageImportScreen(),
  ),
];

/// Retrouve une expérience par son identifiant, `null` si elle n'existe pas
/// (ou plus : une expérience validée est retirée d'ici).
Experiment? experimentById(String id) {
  for (final experiment in kExperiments) {
    if (experiment.id == id) return experiment;
  }
  return null;
}
