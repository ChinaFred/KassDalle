import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:kass_dalle/features/admin/domain/log_treatment_label.dart';

/// Le titre d'un groupe de journaux doit se lire.
///
/// Ce que ces tests verrouillent : un traitement porte un nom français, et
/// aucune fonction appelable ne repart sans en choisir un. Le symptôme d'un
/// oubli est silencieux — l'écran affiche « call » et regroupe correctement des
/// traitements qui n'ont rien à voir entre eux.
void main() {
  group('traduction d\'une racine de correlationId', () {
    test('une racine connue devient une phrase française', () {
      expect(
        logTreatmentName('generation_recette').display,
        'Génération d\'une recette par l\'IA',
      );
      expect(logTreatmentName('disp').display, 'Import d\'une recette');
      // La précision est traduite quand on la connaît : « Ingredients
      // modifies » sans accents se lit comme une faute, pas comme un libellé.
      expect(
        logTreatmentName('ecriture_recette:ingredients-modifies').display,
        'Après écriture d\'une recette — Ingrédients modifiés',
      );
      expect(
        logTreatmentName('ecriture_recette:rien-a-recalculer').detail,
        'Rien à recalculer',
      );
      // « Premier calcul » ne disait pas de quoi. L'ancien nom reste lisible,
      // pour les journaux déjà écrits.
      expect(
        logTreatmentName('ecriture_recette:premier-calcul').detail,
        'Nutrition et courses à calculer',
      );
    });

    test('la précision après le deux-points distingue deux départs', () {
      // Trois variantes partent en même temps : sans cette précision, l'écran
      // alignait trois titres identiques et rien ne disait pourquoi trois.
      final creative = logTreatmentName('generation_recette:creative');
      final rapide = logTreatmentName('generation_recette:rapide');
      expect(creative.detail, 'Creative');
      expect(creative.display, endsWith('— Creative'));
      expect(creative.display, isNot(rapide.display));
    });

    test('une racine inconnue est rendue telle quelle, pas masquée', () {
      // Un nom technique reste cherchable ; « Traitement inconnu » ne l'est pas.
      expect(logTreatmentName('poste_invente').display, 'poste_invente');
    });

    test(
      'un deux-points sans rien derrière ne fabrique pas de suffixe vide',
      () {
        expect(logTreatmentName('generation_recette:').detail, isNull);
        expect(
          logTreatmentName('generation_recette:').display,
          'Génération d\'une recette par l\'IA',
        );
      },
    );

    test('une racine vide ne prétend pas nommer un traitement', () {
      expect(logTreatmentName('  ').display, 'Hors traitement');
    });
  });

  group('aucun traitement anonyme côté serveur', () {
    /// Noms de traitement écrits dans les Cloud Functions.
    ///
    /// On lit le TypeScript comme du texte : c'est la seule façon, depuis Dart,
    /// de vérifier que les deux côtés parlent des mêmes traitements. Le même
    /// procédé que les fixtures partagées, en plus modeste.
    Set<String> featuresDeclareesCoteServeur() {
      final racine = Directory('functions/src');
      if (!racine.existsSync()) return {};
      final motifs = [
        RegExp(r'require(?:Auth|Admin|Editor)\(\s*req,\s*"([a-z0-9_]+)"'),
        RegExp(r'ensureAdminWithAudit\(\s*req,\s*"([a-z0-9_]+)"'),
        RegExp(r'newCorrelationId\("([a-z0-9_-]+)"\)'),
        RegExp(r'qualify\("([a-z0-9_]+)"'),
      ];
      final trouvees = <String>{};
      for (final f in racine.listSync(recursive: true).whereType<File>()) {
        if (!f.path.endsWith('.ts')) continue;
        // Les suites de tests inventent des noms de traitement pour vérifier
        // le découpage : ce ne sont pas des traitements réels, ils n'ont rien
        // à faire dans la table de traduction.
        if (_estUnTest(f.path)) continue;
        final source = f.readAsStringSync();
        for (final motif in motifs) {
          for (final m in motif.allMatches(source)) {
            trouvees.add(m.group(1)!);
          }
        }
      }
      return trouvees;
    }

    test('chaque nom écrit dans les functions a sa traduction', () {
      final declarees = featuresDeclareesCoteServeur();
      if (declarees.isEmpty) {
        // Le test tourne depuis kass_dalle/ ; ailleurs, il n'a rien à dire.
        return;
      }
      final manquantes =
          declarees.where((f) => !kLogTreatmentLabels.containsKey(f)).toList()
            ..sort();
      expect(
        manquantes,
        isEmpty,
        reason:
            'Ces traitements s\'afficheront sous leur nom technique : $manquantes. '
            'Ajouter leur libellé dans kLogTreatmentLabels.',
      );
    });

    test('plus aucune fonction ne repart sous le nom par défaut « call »', () {
      final racine = Directory('functions/src');
      if (!racine.existsSync()) return;
      final anonymes = <String>[];
      for (final f in racine.listSync(recursive: true).whereType<File>()) {
        if (!f.path.endsWith('.ts')) continue;
        // La déclaration des helpers dans _auth.ts porte le défaut lui-même :
        // c'est le seul endroit où « call » a le droit d'apparaître.
        if (f.path.endsWith('_auth.ts')) continue;
        final source = f.readAsStringSync();
        for (final m in RegExp(
          r'require(?:Auth|Admin|Editor)\(req\)',
        ).allMatches(source)) {
          anonymes.add('${f.path} : ${m.group(0)}');
        }
      }
      expect(
        anonymes,
        isEmpty,
        reason:
            'Ces appels prennent le nom par défaut « call » : leurs journaux '
            'se rangeront sous un titre qui ne dit rien. $anonymes',
      );
    });
  });
}

/// Un fichier de la suite de tests des Cloud Functions.
bool _estUnTest(String path) {
  final normalise = path.replaceAll(r'\', '/');
  return normalise.contains('/tests/') || normalise.endsWith('.test.ts');
}
