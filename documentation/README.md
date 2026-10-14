# Documentation Kass'Dalle

Toute la documentation du projet vit ici. Rien à la racine du dépôt, hormis `README.md`
(présentation) et `CLAUDE.md` (instructions IA).

## Les documents

| Fichier | Ce qu'il contient | Format |
|---|---|---|
| [FunctionalRequirements.md](FunctionalRequirements.md) | Intention, parcours, modules, rôles et règles d'accès, couverture mobile / web / desktop | Markdown |
| [TechnicalRequirements.md](TechnicalRequirements.md) | Architecture détaillée, schéma Firestore complet (champs + types), Security Rules, routage multi-fournisseur et traitement des réponses JSON | Markdown |
| [CHANGELOG.md](CHANGELOG.md) | Historique des versions, de la plus récente à la plus ancienne : une entrée par version depuis la v0.22.104, et avant elle les 175 sections « Mise à jour release » sorties des deux specs | Markdown |
| [architecture.html](https://raw.githack.com/ChinaFred/KassDalle/master/documentation/architecture.html) ([source](architecture.html)) | Vue d'ensemble des composants, pipeline d'import, modération des images, surface des Cloud Functions, carte des collections | HTML + Mermaid |
| [diagramme-de-classes.html](https://raw.githack.com/ChinaFred/KassDalle/master/documentation/diagramme-de-classes.html) ([source](diagramme-de-classes.html)) | Modèle de domaine Dart, couche d'accès aux données, correspondance Dart ↔ Firestore | HTML + Mermaid |
| [cas-d-utilisation.html](https://raw.githack.com/ChinaFred/KassDalle/master/documentation/cas-d-utilisation.html) ([source](cas-d-utilisation.html)) | Cas d'utilisation par rôle, et où le droit est réellement vérifié | HTML + Mermaid |
| [diagrammes-de-sequence.html](https://raw.githack.com/ChinaFred/KassDalle/master/documentation/diagrammes-de-sequence.html) ([source](diagrammes-de-sequence.html)) | Vingt-trois opérations détaillées, de l'import à la réconciliation comptable — chaque flux nomme ses classes et ses fonctions réelles | HTML + Mermaid |

GitHub affiche le code d'un fichier HTML, pas la page. Le lien principal de chaque
fichier HTML passe donc par raw.githack.com, qui sert la page rendue depuis `master` ;
le lien « source » ouvre le fichier dans le dépôt.

## Les vingt-trois séquences documentées

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
11. Nommage et regroupement d'un journal — la racine du `correlationId` fait le titre
12. Import d'une page **avec ses illustrations** — les six étapes, le coût de chacune en
    euros, et le partage entre ce que fait le modèle et ce que fait le programme
13. Authentification et nomination d'un compte — trois barrières, et le rôle qui passe du document au jeton
14. Suggestion de menus — un créneau à la fois, chacun voyant les précédents
15. Liste de courses — les repas à venir, fusionnés par rayon, envoyés dans Google Tasks
16. Groupe familial — création, invitation, retrait, et ce que la confidentialité couvre
17. Plafond de dépense et alerte mensuelle — le refus arrive avant l'appel
18. Réconciliation mensuelle — l'estimé contre le facturé BigQuery
19. Reprise d'un job échoué — trois tentatives, dead letter, relance manuelle
20. Changement de moteur d'IA — une décision Firestore, effective en moins d'une minute
21. Export PDF d'une recette — sur l'appareil, sans appel serveur
22. Import d'un texte collé — la même chaîne en deux passes que la page scannée
23. Annoter et noter une recette — deux gestes voisins, deux emplacements en base

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
| Une étape de l'extraction des illustrations | `diagrammes-de-sequence.html` § 12 |
| Un flux qui change d'acteur, de garde ou d'ordre | la séquence correspondante dans `diagrammes-de-sequence.html` |
| Une route ou une redirection du routeur | `cas-d-utilisation.html`, `TechnicalRequirements.md` § 13.1 |
| Une règle Firestore ou Storage | `cas-d-utilisation.html`, `TechnicalRequirements.md` |
| Un champ de journal, un code d'erreur, une politique de reprise | `TechnicalRequirements.md` § 7 |
| Un poste d'IA ajouté ou routé autrement | `architecture.html`, `TechnicalRequirements.md` — et les trois endroits listés dans `CLAUDE.md`, sans quoi le coût devient illisible |
| Une décision déplacée du code vers Firestore | `TechnicalRequirements.md` § 3.13, `cas-d-utilisation.html` |
| Un flux utilisateur | `diagrammes-de-sequence.html`, `FunctionalRequirements.md` |

Un diagramme faux coûte plus cher qu'un diagramme absent.
