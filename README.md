# Kass'Dalle — Livre de cuisine digital familial

**Version actuelle : 0.22.29**  
**Démo web : [https://kassdale-6d948.web.app](https://kassdale-6d948.web.app)**  
**APK Android : [télécharger](https://kassdale-6d948.web.app/app-release.apk)**

Application multi-plateforme de gestion de recettes et de cuisine, conçue pour les familles. Permet d'importer, organiser, planifier et partager des recettes depuis n'importe quel appareil.

## Fonctionnalités principales

- **Import intelligent** : photos, PDF, documents Word ou texte libre → CookLang, par un pipeline asynchrone côté serveur
- **Format CookLang** : recettes structurées, ingrédients et étapes balisés, éditeur visuel ou brut
- **Bibliothèque** : organisation par livres, mode lecture page à page
- **Planning repas** : cycles assistés par l'IA, export Google Calendar, conseils de conservation
- **Liste de courses** : depuis les repas à venir, rangée par rayon, envoyée dans Google Tasks
- **Nutrition** : calculée depuis un référentiel partagé, recalculée pour le nombre de parts choisi
- **Illustrations** : extraites automatiquement d'une page importée — cadrage, mise à plat, remise à l'endroit, découpe — ou retouchées, générées, mises en scène
- **Export PDF** : recette ou livre, mise en forme et photos
- **Multi-utilisateurs** : partage de bibliothèque au sein d'un groupe familial
- **Modération** : toute image envoyée par une personne passe par une quarantaine et par Cloud Vision avant publication
- **Comptabilité de l'IA** : coût par poste, par moteur et par compte, plafonds quotidiens, réconciliation mensuelle
- **Rôles** : `pending`, `reader`, `editor`, `admin` — être connecté ne donne accès à rien

## Stack technique

| Couche | Technologie |
|---|---|
| Mobile (Android / iOS) | Flutter / Dart |
| Web | Flutter Web |
| Desktop (Windows) | Flutter Desktop |
| Backend BaaS | Firebase (Auth, Firestore, Storage, Hosting) |
| Cloud Functions | Node.js / TypeScript |
| IA — texte et lecture d'image | Google Gemini **et** Anthropic Claude, routés poste par poste depuis Firestore (clés en Secret Manager) |
| IA — production d'image | Google Gemini |
| Modération d'images | Google Cloud Vision |
| State management | Riverpod |
| Navigation | go_router |

## Structure du projet

```
kass_dalle/           # Projet Flutter principal
├── lib/
│   ├── core/         # Services, router, thème, providers transverses
│   └── features/     # Modules fonctionnels (auth, recipes, planning…)
├── functions/        # Cloud Functions Node.js/TypeScript
├── android/          # Configuration native Android
├── ios/              # Configuration native iOS
└── web/              # Entry point web (index.html, manifest)
```

## Documentation

Tout est dans [`documentation/`](documentation/) — sommaire :
[documentation/README.md](documentation/README.md).

| Document | Contenu |
|---|---|
| [Exigences fonctionnelles](documentation/FunctionalRequirements.md) | Intention, parcours, modules, rôles |
| [Exigences techniques](documentation/TechnicalRequirements.md) | Architecture, schéma Firestore, Security Rules, prompts Gemini |
| [Historique des versions](documentation/CHANGELOG.md) | Ce qui a changé d'une version à l'autre |
| [Architecture](documentation/architecture.html) | Composants, pipeline d'import, Cloud Functions, collections |
| [Diagramme de classes](documentation/diagramme-de-classes.html) | Modèle de domaine et couche d'accès |
| [Cas d'utilisation](documentation/cas-d-utilisation.html) | Cas par rôle et vérification des droits |
| [Diagrammes de séquence](documentation/diagrammes-de-sequence.html) | Vingt-trois opérations détaillées |

## Déploiement

- **Web** : Firebase Hosting — `https://kassdale-6d948.web.app`
- **Android** : APK disponible sur `https://kassdale-6d948.web.app/app-release.apk`
- **Windows** : `flutter build windows --release`, copié dans `Release/desktop`. Construit à la
  main, hors `deploy.ps1`, et non distribué en ligne
- **iOS** : déclaré dans le dépôt, jamais construit — voir `TechnicalRequirements.md` § 12
