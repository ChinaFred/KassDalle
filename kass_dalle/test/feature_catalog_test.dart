/// Catalogue des postes de coût.
///
/// Un poste absent du catalogue ne casse rien : son coût est compté, il
/// s'affiche seulement sous sa clé technique, rangé dans « Autres ». C'est le
/// mode de panne le plus coûteux à repérer — le chiffre est là, il ne veut
/// simplement plus rien dire. Toute la chaîne nutrition y a vécu quinze postes
/// durant.
///
/// Ce test ne peut pas savoir ce que le serveur facture — la liste vit en
/// TypeScript. Il garde ce qu'il peut garder : la cohérence des deux tables
/// entre elles.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:kass_dalle/features/admin/data/feature_catalog.dart';

void main() {
  group('catalogue des postes', () {
    test('tout poste rangé dans un processus porte un libellé', () {
      final orphans = kFeatureProcess.keys
          .where((key) => !kFeatureCatalog.containsKey(key))
          .toList();
      expect(
        orphans,
        isEmpty,
        reason:
            'ces postes sont groupés mais s\'afficheront sous leur clé '
            'technique : $orphans',
      );
    });

    test('tout poste catalogué appartient à un processus', () {
      final unfiled = kFeatureCatalog.keys
          .where((key) => !kFeatureProcess.containsKey(key))
          .toList();
      expect(
        unfiled,
        isEmpty,
        reason:
            'ces postes ont un libellé mais tomberont dans « Autres » : '
            '$unfiled',
      );
    });

    test('aucun libellé ni description vide', () {
      for (final entry in kFeatureCatalog.entries) {
        expect(
          entry.value.label.trim(),
          isNotEmpty,
          reason: '${entry.key} sans libellé',
        );
        expect(
          entry.value.description.trim(),
          isNotEmpty,
          reason: '${entry.key} sans description',
        );
      }
    });

    test('la chaîne nutrition est comptée comme un processus', () {
      // Les postes les plus fréquents de l'application : une écriture de
      // recette peut en déclencher une dizaine.
      for (final key in const [
        'detect_not_consumed',
        'detect_duplicate_ingredients',
        'estimate_fry_absorption',
        'nutrition_ingredients_enrichment_batch',
      ]) {
        expect(featureProcess(key), 'Valeurs nutritionnelles');
      }
    });

    test('un poste inconnu se rabat sur sa clé plutôt que de disparaître', () {
      expect(featureLabel('poste_qui_n_existe_pas'), 'poste_qui_n_existe_pas');
      expect(featureProcess('poste_qui_n_existe_pas'), 'Autres');
      expect(featureDescription('poste_qui_n_existe_pas'), '');
    });
  });
}
