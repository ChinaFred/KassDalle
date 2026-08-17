import 'package:flutter_test/flutter_test.dart';
import 'package:kass_dalle/features/recipes/domain/storage_text.dart';

/// Retrait de la section de conservation héritée du texte d'une recette.
///
/// Ce code touche le **texte** des recettes, celui que la famille lit et
/// modifie. Retirer une ligne de trop y est irréversible et silencieux : la
/// recette reste valide, il lui manque simplement un morceau. D'où ces cas.
void main() {
  group('détection', () {
    test('la section insérée est reconnue', () {
      const cooklang = '''
Faire revenir la @viande{}.

## Conservation et réchauffage
Ce plat supporte mal l'attente.
> Réfrigérateur : 24 heures maximum.
''';
      expect(hasStorageSection(cooklang), isTrue);
    });

    test('une recette sans section n\'est pas concernée', () {
      expect(hasStorageSection('Faire revenir la @viande{}.'), isFalse);
    });

    test('une ligne vide finale ne passe pas pour une section', () {
      // Le piège : le retrait supprime aussi les lignes vides de fin. Détecter
      // par écart de longueur ferait réécrire toutes les recettes.
      expect(hasStorageSection('Faire revenir la @viande{}.\n\n'), isFalse);
    });

    test('une section « Conservation » écrite à la main est épargnée', () {
      const cooklang = '''
Faire revenir la @viande{}.

## Conservation
Se garde deux jours.
''';
      expect(hasStorageSection(cooklang), isFalse);
      expect(removeStorageSection(cooklang), cooklang.trimRight());
    });
  });

  group('retrait', () {
    test('la section part, la préparation reste', () {
      const cooklang = '''
## Préparation
Faire revenir la @viande{}.

## Conservation et réchauffage
Ce plat supporte mal l'attente.
> Réfrigérateur : 24 heures maximum.
''';

      final result = removeStorageSection(cooklang);

      expect(result, contains('Faire revenir'));
      expect(result, contains('## Préparation'));
      expect(result, isNot(contains('Conservation et réchauffage')));
      expect(result, isNot(contains('Réfrigérateur')));
      expect(hasStorageSection(result), isFalse);
    });

    test('une section qui suit la conservation est conservée', () {
      const cooklang = '''
Faire revenir la @viande{}.

## Conservation et réchauffage
> Réfrigérateur : 24 heures maximum.

## Dressage
Servir dans une assiette creuse.
''';

      final result = removeStorageSection(cooklang);

      expect(result, contains('## Dressage'));
      expect(result, contains('assiette creuse'));
      expect(result, isNot(contains('Réfrigérateur')));
    });

    test('la forme « == Titre == » de l\'éditeur visuel est reconnue', () {
      const cooklang = '''
Faire revenir la @viande{}.

== Conservation et réchauffage ==
> Réfrigérateur : 24 heures maximum.
''';

      final result = removeStorageSection(cooklang);

      expect(result, isNot(contains('Réfrigérateur')));
      expect(result, contains('Faire revenir'));
    });

    test('un texte sans section traverse sans perdre une ligne', () {
      const cooklang = 'Faire revenir la @viande{}.\nAjouter l\'@eau{}.';
      expect(removeStorageSection(cooklang), cooklang);
    });
  });
}
