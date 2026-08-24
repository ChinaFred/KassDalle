import 'package:flutter/material.dart';

import 'ai_pricing_section.dart';

/// Grille tarifaire des modèles d'IA, sur un écran à elle.
///
/// Elle vivait en bas de *Moteur d'IA*, après quarante-cinq postes fonctionnels
/// et la génération d'image. Il fallait franchir toute la page pour l'atteindre,
/// et rien dans le menu ne disait qu'elle s'y trouvait : le sous-titre de
/// l'entrée ne parle que de choisir un moteur. Un réglage qu'on ne trouve pas
/// est un réglage qu'on ne corrige pas — et ici, ne pas corriger un tarif fait
/// mentir tout le reporting de coûts.
///
/// Sa place est du côté de la comptabilité : c'est la même question. *Moteur
/// d'IA* répond à « quel moteur sert ce poste », cet écran à « à quel prix le
/// facture-t-on », et *Coûts de l'application* à « combien cela a coûté ». Les
/// deux derniers se lisent ensemble ; le premier se décide ailleurs.
class AiPricingScreen extends StatelessWidget {
  const AiPricingScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Grille tarifaire')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: const [AiPricingSection()],
      ),
    );
  }
}
