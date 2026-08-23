# Documentation Kass'Dalle

Toute la documentation du projet vit ici. Rien à la racine du dépôt, hormis `README.md`
(présentation) et `CLAUDE.md` (instructions IA).

## Les documents

| Fichier | Ce qu'il contient | Format |
|---|---|---|
| [FunctionalRequirements.md](FunctionalRequirements.md) | Intention, parcours, modules, rôles et règles d'accès, couverture mobile / web / desktop | Markdown |
| [TechnicalRequirements.md](TechnicalRequirements.md) | Architecture détaillée, schéma Firestore complet (champs + types), Security Rules, routage multi-fournisseur et traitement des réponses JSON | Markdown |
| [architecture.html](architecture.html) | Vue d'ensemble des composants, pipeline d'import, modération des images, surface des Cloud Functions, carte des collections | HTML + Mermaid |
| [diagramme-de-classes.html](diagramme-de-classes.html) | Modèle de domaine Dart, couche d'accès aux données, correspondance Dart ↔ Firestore | HTML + Mermaid |
| [cas-d-utilisation.html](cas-d-utilisation.html) | Cas d'utilisation par rôle, et où le droit est réellement vérifié | HTML + Mermaid |
| [diagrammes-de-sequence.html](diagrammes-de-sequence.html) | Dix opérations détaillées, de l'import à la publication d'une image | HTML + Mermaid |
| [uc-lire-recette-mode-livre.html](uc-lire-recette-mode-livre.html) | Description textuelle du cas UC-A02 « Lire une recette en mode livre » : identification, scénario nominal, alternatives, exceptions | HTML + Mermaid |
| [import-page-illustrations.html](import-page-illustrations.html) | Séquence détaillée de l'import d'une page **avec extraction des illustrations** : les six étapes, le coût de chacune en euros, et le partage entre ce que fait le modèle et ce que fait le programme | HTML + Mermaid |

## Les dix séquences documentées

1. Import d'une page de livre — quarantaine, Cloud Tasks, pipeline, dead letters
2. Chargement d'un brouillon — flux temps réel et garde d'initialisation du formulaire
3. Raffinement d'un brouillon par IA
4. Sauvegarde en recette — validation « telle quelle »
5. Modification d'une recette — normalisation des référentiels
6. Recalcul nutritionnel automatique — et son coupe-circuit de récursion
7. Recherche de recettes — trois pistes en parallèle
8. Génération d'une recette par IA — trois variantes et déduplication
9. Conseil de dressage et visuels de montage — un appel par recette, une image par clic
10. Publication d'une image — quarantaine, Cloud Vision, verdict, revue humaine

## Versions publiées en ligne

Les quatre pages HTML sont aussi publiées et navigables entre elles :

- [Architecture](https://claude.ai/code/artifact/f7d480e3-bc41-4649-a23c-82e701536dbe)
- [Diagramme de classes](https://claude.ai/code/artifact/c9193a37-1895-4a21-89c6-8dbff3289077)
- [Cas d'utilisation](https://claude.ai/code/artifact/8e471107-ae92-4037-a3c5-2a02418e5ce1)
- [Diagrammes de séquence](https://claude.ai/code/artifact/55b3ec9d-c68e-463b-a304-0313ae0c7170)

Ces pages sont privées par défaut. La barre de navigation en tête de chaque page HTML pointe
vers ces URLs, y compris dans les fichiers locaux.

## Lire les pages HTML

Elles s'ouvrent directement dans un navigateur : les diagrammes sont rendus par
[Mermaid](https://mermaid.js.org/) chargé depuis un CDN, une connexion Internet est donc
nécessaire au premier affichage. Publiées en Artifact sur claude.ai, elles rendent les
diagrammes nativement, sans CDN.

Chaque page est autonome : sa feuille de style est incluse en tête. Si vous modifiez les jetons
de couleur ou la typographie, répercutez-les dans les quatre pages.

## Tenir la documentation à jour

Un changement qui touche l'une de ces zones met à jour le document correspondant **dans le même
commit** :

| Ce qui change | Ce qui doit suivre |
|---|---|
| Un champ d'un modèle `domain/` | `diagramme-de-classes.html`, `TechnicalRequirements.md` |
| Une méthode de repository ou de service | `diagramme-de-classes.html` |
| Une Cloud Function ajoutée, supprimée ou dont la garde change | `architecture.html` |
| Une étape du pipeline d'import | `architecture.html`, `diagrammes-de-sequence.html` |
| Une étape de l'extraction des illustrations | `import-page-illustrations.html`, `diagrammes-de-sequence.html` |
| Une route ou une redirection du routeur | `cas-d-utilisation.html` |
| Une règle Firestore ou Storage | `cas-d-utilisation.html`, `TechnicalRequirements.md` |
| Un poste d'IA ajouté ou routé autrement | `architecture.html`, `TechnicalRequirements.md` — et les trois endroits listés dans `CLAUDE.md`, sans quoi le coût devient illisible |
| Une décision déplacée du code vers Firestore | `TechnicalRequirements.md` § 3.13, `cas-d-utilisation.html` |
| Un flux utilisateur | `diagrammes-de-sequence.html`, `FunctionalRequirements.md` |

Un diagramme faux coûte plus cher qu'un diagramme absent.
