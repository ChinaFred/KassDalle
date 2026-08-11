# Kass'Dalle — Livre de cuisine digital familial

**Version actuelle : 0.18.0**  
**Démo web : [https://kassdale-6d948.web.app](https://kassdale-6d948.web.app)**  
**APK Android : [télécharger](https://kassdale-6d948.web.app/app-release.apk)**

Application multi-plateforme de gestion de recettes et de cuisine, conçue pour les familles. Permet d'importer, organiser, planifier et partager des recettes depuis n'importe quel appareil.

## Fonctionnalités principales

- **Import intelligent** : importation de recettes depuis des photos, PDFs ou texte libre via l'IA (Google Gemini via Cloud Functions sécurisées)
- **Atelier photo unifié** : retouche centralisée (cadre, lumière, détails, presets intelligents, avant/après)
- **Format CookLang** : recettes structurées avec ingrédients et étapes balisés
- **Bibliothèque personnelle** : organisation des recettes par livres
- **Mode lecture livre** : navigation recette par recette avec swipe, flèches clavier et précédent/suivant
- **Planning repas** : planification hebdomadaire et liste de courses associée
- **Export PDF** : génération de PDFs avec mise en forme et photos
- **Multi-utilisateurs** : partage de bibliothèque au sein d'un groupe familial
- **Rôles** : admin, editor, reader avec droits différenciés

## Stack technique

| Couche | Technologie |
|---|---|
| Mobile (Android / iOS) | Flutter / Dart |
| Web | Flutter Web |
| Desktop (Windows) | Flutter Desktop |
| Backend BaaS | Firebase (Auth, Firestore, Storage, Hosting) |
| Cloud Functions | Node.js / TypeScript |
| IA — Parsing recettes | Google Gemini via Cloud Functions (clé en Secret Manager) |
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
| [Architecture](documentation/architecture.html) | Composants, pipeline d'import, Cloud Functions, collections |
| [Diagramme de classes](documentation/diagramme-de-classes.html) | Modèle de domaine et couche d'accès |
| [Cas d'utilisation](documentation/cas-d-utilisation.html) | Cas par rôle et vérification des droits |
| [Diagrammes de séquence](documentation/diagrammes-de-sequence.html) | Huit opérations détaillées |

## Déploiement

- **Web** : Firebase Hosting — `https://kassdale-6d948.web.app`
- **Android** : APK disponible sur `https://kassdale-6d948.web.app/app-release.apk`
