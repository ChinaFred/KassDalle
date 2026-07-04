# Kass'Dalle — Livre de cuisine digital familial

**Version actuelle : 0.16.08**  
**Démo web : [https://kassdale-6d948.web.app](https://kassdale-6d948.web.app)**

---

## Fonctionnalités principales

- **Recettes** : création, édition, suppression avec éditeur visuel WYSIWYG ou Markdown
- **IA Gemini** : génération automatique de recettes à partir d'une description textuelle
- **Export PDF** : export de recettes en PDF avec bouton « Ouvrir » sur mobile
- **Bibliothèque de livres** : organisation des recettes par livre, effet 3D animé
- **Mode lecture livre** : feuilletage des recettes et pages du livre avec swipe, clavier et navigation directe
- **Planning repas** : planification hebdomadaire avec liste de courses générée par IA
- **Explorateur** : navigation par ingrédients, catégories et saisons
- **Pipeline image** : recadrage, compression et stockage Firebase Storage
- **Comptabilité** : suivi des dépenses alimentaires avec analyse IA
- **Multi-plateforme** : iOS/Android, Web (PWA installable), Desktop (Windows)
- **Rôles** : admin, editor, reader — avec règles d'accès Firestore

---

## Installation

### Web (PWA)

Ouvrir [https://kassdale-6d948.web.app](https://kassdale-6d948.web.app) dans Chrome.  
Pour installer : cliquer sur l'icône d'installation dans la barre d'adresse (Chrome desktop) ou « Ajouter à l'écran d'accueil » (mobile).

### Mobile Android (APK)

Télécharger l'APK depuis la page web : [https://kassdale-6d948.web.app/app-release.apk](https://kassdale-6d948.web.app/app-release.apk)  
Activer « Sources inconnues » dans les paramètres Android, puis installer l'APK.

### Desktop (Windows)

1. Cloner le dépôt
2. Créer un fichier `kass_dalle/.env` avec `GEMINI_API_KEY=<votre_clé>`
3. Exécuter :
   ```powershell
   cd kass_dalle
   flutter build windows --release --dart-define=GEMINI_API_KEY=<votre_clé>
   ```
4. L'exécutable se trouve dans `build\windows\x64\runner\Release\kass_dalle.exe`

---

## Stack technique

- **Flutter** 3.41.9 / Dart 3.11.5
- **Firebase** : Firestore, Auth, Storage, Hosting, Functions
- **IA** : Google Gemini API
- **Plateformes** : Android, Web, Windows (Linux/macOS en cours)
