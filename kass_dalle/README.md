# Kass'Dalle — Livre de cuisine digital familial

**Version actuelle : 0.22.17**
**Web : [https://kassdale-6d948.web.app](https://kassdale-6d948.web.app)**

Un seul projet Flutter sert Android, iOS, Web et Windows. La documentation complète vit dans
[`../documentation/`](../documentation/) ; les instructions de développement dans
[`../CLAUDE.md`](../CLAUDE.md).

---

## Fonctionnalités principales

- **Import de recettes** : photo, PDF, document Word ou texte collé → CookLang, par un
  pipeline asynchrone côté serveur. Multi-pages, reprise après échec, file d'attente visible.
- **Édition** : éditeur hybride — visuel par blocs ou CookLang brut — avec rendu interactif
  en temps réel dans un panneau split.
- **Bibliothèque** : livres, couvertures, mode lecture page à page (swipe, clavier).
- **Recherche** : plein texte sur le titre et les ingrédients, filtres combinables,
  classement sémantique par l'IA.
- **Planning des repas** : cycles générés avec l'aide de l'IA, export Google Calendar,
  conseils de conservation, préparation groupée.
- **Liste de courses** : construite depuis les repas à venir, rangée par rayon, envoyée dans
  Google Tasks (rayons en tâches, articles en sous-tâches cochables).
- **Nutrition** : valeurs calculées depuis un référentiel partagé, recalculées à l'affichage
  pour le nombre de parts choisi — sans jamais écrire dans la recette partagée.
- **Illustrations** : extraites automatiquement d'une page importée — cadrage, mise à plat, remise à l'endroit, découpe — ou retouchées, générées, mises en scène.
- **Export PDF** : recette ou livre, partagé sur mobile, téléchargé ailleurs.
- **Groupes familiaux** : partage des livres et recettes validés entre membres.
- **Modération** : toute image envoyée par une personne passe par une quarantaine et par Cloud Vision avant publication.
- **Administration** : moteur d'IA, coûts, plafonds de dépense, attestation App Check,
  référentiels, file d'échecs, logs.
- **Rôles** : `pending`, `reader`, `editor`, `admin` — être connecté ne donne accès à rien.

> **Aucune clé d'IA côté client.** Ni dans le binaire, ni dans le bundle web : tous les appels
> passent par des Cloud Functions, les clés vivent en Secret Manager.

---

## Installation

### Web (PWA)

Ouvrir [https://kassdale-6d948.web.app](https://kassdale-6d948.web.app) dans Chrome.
Pour installer : icône d'installation dans la barre d'adresse (desktop) ou « Ajouter à
l'écran d'accueil » (mobile).

### Android (APK)

[https://kassdale-6d948.web.app/app-release.apk](https://kassdale-6d948.web.app/app-release.apk) —
activer « Sources inconnues », puis installer.

### Windows

```powershell
cd kass_dalle
flutter build windows --release
# → build\windows\x64\runner\Release\kass_dalle.exe
```

> Le client Windows n'atteste pas son authenticité (App Check ne le couvre pas). Si
> l'attestation passe en mode *exigé*, il perd l'accès à l'IA.

---

## Stack technique

| Couche | Technologie |
|---|---|
| Client | Flutter — Dart SDK `^3.11.4`, Riverpod, go_router |
| Backend | Firebase : Auth, Firestore, Storage, Hosting, App Check |
| Cloud Functions | Node 22 / TypeScript |
| IA — texte et lecture d'image | Google Gemini **et** Anthropic Claude, routés poste par poste depuis Firestore |
| IA — production d'image | Google Gemini |
| Modération d'images | Google Cloud Vision |

---

## Développer

```powershell
flutter analyze          # strict, bloquant en CI
flutter test
flutter run -d chrome

cd functions
npm run build            # tsc
npm run lint             # ESLint 9 — un catch dont l'erreur n'est pas utilisée fait échouer la CI
npm test                 # fixtures partagées avec les tests Dart
npm run serve            # émulateurs
```

Le déploiement passe **toujours** par `../deploy.ps1`, jamais par des commandes reconstituées
à la main.
