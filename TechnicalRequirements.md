# Spécifications Techniques — Kass'dalle
## Livre de Cuisine Digital (Flutter + Firebase)

> Version : 1.0 — Avril 2026

---

## 1. Architecture Générale

```
┌─────────────────────────────────────────────────────────────┐
│                        Clients Flutter                       │
│   ┌──────────────┐  ┌──────────────┐  ┌──────────────────┐  │
│   │   Mobile     │  │     Web      │  │    Desktop       │  │
│   │ iOS/Android  │  │   Browser    │  │  Windows/macOS   │  │
│   └──────┬───────┘  └──────┬───────┘  └────────┬─────────┘  │
└──────────┼─────────────────┼────────────────────┼────────────┘
           │                 │                    │
           └─────────────────┼────────────────────┘
                             │ Firebase SDK (FlutterFire)
           ┌─────────────────▼────────────────────────────────┐
           │                  Firebase Backend                  │
           │                                                    │
           │  ┌─────────────┐  ┌─────────────┐  ┌──────────┐  │
           │  │ Firebase    │  │  Firestore  │  │ Firebase │  │
           │  │    Auth     │  │     DB      │  │ Storage  │  │
           │  │ (Google     │  │  (recettes, │  │ (images) │  │
           │  │  Sign-In)   │  │  livres,    │  │          │  │
           │  └─────────────┘  │  users)     │  └──────────┘  │
           │                   └─────────────┘                 │
           └──────────────────────────────────────────────────┘
                             │
           ┌─────────────────▼────────────────────────────────┐
           │              Google AI (Gemini)                    │
           │        gemini-1.5-flash (Vision + Text)           │
           └──────────────────────────────────────────────────┘
```

---

## 2. Stack Technique

| Composant | Technologie | Version cible |
|---|---|---|
| Framework UI | Flutter | ≥ 3.22 |
| Langage | Dart | ≥ 3.4 |
| Authentification | Firebase Auth + Google Sign-In | FlutterFire latest |
| Base de données | Cloud Firestore | FlutterFire latest |
| Stockage fichiers | Firebase Storage | FlutterFire latest |
| IA / OCR | Google Generative AI SDK (Gemini 1.5 Flash) | `google_generative_ai` latest |
| Parsing Cooklang | `cooklang` (package Dart) | latest compatible |
| State management | Riverpod | ≥ 2.5 |
| Navigation | go_router | ≥ 14 |
| Image (mobile) | `image_picker` + `image_cropper` | latest |
| Éditeur code | `flutter_code_editor` ou `re_editor` | latest |

---

## 3. Schéma de Données Firestore

### Vue d'ensemble

```
firestore/
├── users/
│   └── {uid}/
├── books/
│   └── {bookId}/
└── recipes/
    └── {recipeId}/
        └── annotations/
            └── {annotationId}/
```

---

### 3.1 Collection `users`

Créée automatiquement à la première connexion Google.

| Champ | Type | Description |
|---|---|---|
| `uid` | `String` | UID Google Firebase (= ID du document) |
| `email` | `String` | Adresse email du compte Google |
| `display_name` | `String` | Nom d'affichage Google |
| `photo_url` | `String?` | URL de l'avatar Google |
| `role` | `String` | Enum : `admin` \| `editor` \| `reader` |
| `created_at` | `Timestamp` | Date de première connexion |
| `last_seen_at` | `Timestamp` | Date de dernière connexion active |
| `is_revoked` | `Boolean` | `true` si l'accès a été révoqué par un Admin |

**Règle de bootstrap :** lors de la création du premier document `users`, le rôle est automatiquement forcé à `admin` via une Cloud Function ou une logique client protégée par une transaction Firestore vérifiant que la collection `users` est vide.

---

### 3.2 Collection `books`

| Champ | Type | Description |
|---|---|---|
| `id` | `String` | ID auto-généré Firestore |
| `titre` | `String` | Titre du livre |
| `auteur` | `String` | Auteur(s) — champ libre |
| `annee` | `int?` | Année de publication |
| `langue` | `String` | Code ISO 639-1 (ex : `fr`, `it`, `zh`, `nl`) |
| `url_couverture` | `String?` | URL Firebase Storage vers la photo de couverture |
| `tags` | `List<String>` | Étiquettes libres (ex : `pâtisserie`, `terroir belge`) |
| `created_by` | `String` | UID de l'utilisateur créateur |
| `created_at` | `Timestamp` | Date de création |
| `updated_at` | `Timestamp` | Date de dernière modification |

---

### 3.3 Collection `recipes`

Document principal d'une recette.

| Champ | Type | Description |
|---|---|---|
| `id` | `String` | ID auto-généré Firestore |
| `titre` | `String` | Titre de la recette |
| `book_id` | `DocumentReference?` | Référence vers `books/{bookId}` (nullable si sans livre) |
| `book_titre` | `String?` | Dénormalisation du titre du livre pour les requêtes |
| `page_number` | `int?` | Numéro de page dans le livre source |
| `langue` | `String` | Code ISO 639-1 de la langue de la recette |
| `raw_cooklang` | `String` | Contenu Cooklang validé (version finale) |
| `draft_cooklang` | `String?` | Version en cours de révision (avant validation) |
| `image_urls` | `List<String>` | URLs Firebase Storage des scans originaux (multi-pages) |
| `review_status` | `String` | Enum : `draft` \| `in_review` \| `validated` |
| `tags` | `Map<String, dynamic>` | Voir structure détaillée ci-dessous |
| `ingredients_index` | `List<String>` | Liste de strings normalisés pour la recherche rapide (extraits du Cooklang) |
| `created_by` | `String` | UID du créateur |
| `created_at` | `Timestamp` | Date de création |
| `updated_at` | `Timestamp` | Date de dernière modification |

#### Détail du champ `tags` (Map imbriqué)

```json
{
  "themes":    ["Noël", "Hiver", "Festif"],
  "cuisines":  ["Belge", "Terroir"],
  "occasions": ["Anniversaire", "Fête de famille"],
  "difficulty": "medium",
  "prep_time":  30,
  "cook_time":  60
}
```

| Sous-champ | Type | Valeurs possibles |
|---|---|---|
| `themes` | `List<String>` | Libre (ex : Été, Noël, Rapide) |
| `cuisines` | `List<String>` | Libre (ex : Italien, Belge, Asiatique) |
| `occasions` | `List<String>` | Libre (ex : Anniversaire, Quotidien) |
| `difficulty` | `String?` | `easy` \| `medium` \| `hard` |
| `prep_time` | `int?` | Durée en minutes |
| `cook_time` | `int?` | Durée en minutes |

---

### 3.4 Sous-collection `recipes/{recipeId}/annotations`

| Champ | Type | Description |
|---|---|---|
| `id` | `String` | ID auto-généré |
| `uid` | `String` | UID de l'auteur de l'annotation |
| `author_name` | `String` | Nom d'affichage (dénormalisé pour affichage) |
| `text` | `String` | Contenu de l'annotation |
| `type` | `String` | Enum : `note` \| `tip` \| `correction` |
| `created_at` | `Timestamp` | Date de création |
| `updated_at` | `Timestamp?` | Date de modification |

---

### 3.5 Structure Firebase Storage

```
gs://{bucket}/
├── covers/
│   └── {bookId}/
│       └── cover.jpg
└── recipes/
    └── {recipeId}/
        ├── scan_1.jpg
        ├── scan_2.jpg
        └── ...
```

Les images sont uploadées avant l'appel Gemini. Les URLs de téléchargement Firebase sont stockées dans `recipes.image_urls`.

---

## 4. Firebase Security Rules

### Firestore Rules

```javascript
rules_version = '2';
service cloud.firestore {
  match /databases/{database}/documents {

    // Fonctions utilitaires
    function isAuthenticated() {
      return request.auth != null;
    }

    function getUserData() {
      return get(/databases/$(database)/documents/users/$(request.auth.uid)).data;
    }

    function hasRole(role) {
      return isAuthenticated() && getUserData().role == role;
    }

    function isAdmin() {
      return hasRole('admin');
    }

    function isEditor() {
      return hasRole('editor') || isAdmin();
    }

    function isReader() {
      return isAuthenticated() && !getUserData().is_revoked;
    }

    function isOwner(uid) {
      return isAuthenticated() && request.auth.uid == uid;
    }

    // Collection users
    match /users/{uid} {
      allow read: if isAuthenticated() && (request.auth.uid == uid || isAdmin());
      allow create: if isAuthenticated() && request.auth.uid == uid;
      allow update: if isAdmin() || (isAuthenticated() && request.auth.uid == uid
                      && !request.resource.data.diff(resource.data).affectedKeys()
                         .hasAny(['role', 'is_revoked']));
      allow delete: if isAdmin();
    }

    // Collection books
    match /books/{bookId} {
      allow read: if isReader();
      allow create, update, delete: if isEditor();
    }

    // Collection recipes
    match /recipes/{recipeId} {
      // Les brouillons ne sont visibles que par editors/admins
      allow read: if isReader() &&
        (resource.data.review_status == 'validated' || isEditor());
      allow create, update: if isEditor();
      allow delete: if isAdmin();

      // Annotations
      match /annotations/{annotationId} {
        allow read: if isReader();
        allow create: if isAuthenticated() && !getUserData().is_revoked;
        allow update, delete: if isOwner(resource.data.uid) || isAdmin();
      }
    }
  }
}
```

### Firebase Storage Rules

```javascript
rules_version = '2';
service firebase.storage {
  match /b/{bucket}/o {

    function isAuthenticated() {
      return request.auth != null;
    }

    // Couvertures de livres
    match /covers/{bookId}/{fileName} {
      allow read: if isAuthenticated();
      allow write: if isAuthenticated()
        && request.resource.size < 10 * 1024 * 1024   // max 10 MB
        && request.resource.contentType.matches('image/.*');
    }

    // Scans de recettes
    match /recipes/{recipeId}/{fileName} {
      allow read: if isAuthenticated();
      allow write: if isAuthenticated()
        && request.resource.size < 20 * 1024 * 1024   // max 20 MB
        && request.resource.contentType.matches('image/.*');
    }
  }
}
```

---

## 5. Authentification Google Sign-In

### Flux d'authentification

```
App Launch
    │
    ▼
Firebase Auth state listener
    │
    ├─ Non connecté ──► Écran Google Sign-In
    │                        │
    │                        ▼
    │                   GoogleSignIn.signIn()
    │                        │
    │                        ▼
    │                   Firebase Auth (credential)
    │                        │
    │                        ▼
    │                   Vérification users/{uid} dans Firestore
    │                        │
    │                   ┌────┴────────────────────────────┐
    │                   │ Nouveau ?                        │
    │                   │ → Créer document users/{uid}     │
    │                   │   role = 'reader'                │
    │                   │   (ou 'admin' si premier compte) │
    │                   └─────────────────────────────────┘
    │                        │
    └─ Connecté ──────────── ▼
                        Charger profil + rôle
                             │
                             ▼
                        Router selon rôle
```

### Bootstrap Admin

La logique de détection du "premier utilisateur" est implémentée via une **transaction Firestore** :

```dart
// Pseudo-code Dart
await firestore.runTransaction((tx) async {
  final usersCount = await firestore.collection('users').count().get();
  final role = usersCount.count == 0 ? 'admin' : 'reader';
  tx.set(firestore.collection('users').doc(uid), {
    'uid': uid,
    'role': role,
    // ...autres champs
  });
});
```

---

## 6. Intégration Gemini — Passe Unique Structurée

### Principe

Un seul appel API à `gemini-1.5-flash` avec les images en entrée. La réponse est un objet JSON structuré contenant le Cooklang et les métadonnées extraites.

### Prompt Système (system instruction)

```
Tu es un assistant spécialisé dans la numérisation de recettes de cuisine.
On te fournit une ou plusieurs photos d'une page de recette.
Tu dois extraire le contenu et le retourner EXCLUSIVEMENT sous forme d'un objet JSON valide,
sans texte supplémentaire avant ou après le JSON.
```

### Prompt Utilisateur

```
Analyse cette/ces image(s) de recette et retourne un JSON avec exactement cette structure :

{
  "titre": "Nom de la recette",
  "langue": "code ISO 639-1 (ex: fr, it, nl, en)",
  "cooklang": "Contenu complet de la recette au format Cooklang",
  "tags": {
    "themes": ["liste", "de", "thèmes"],
    "cuisines": ["type", "de", "cuisine"],
    "difficulty": "easy | medium | hard",
    "prep_time": <entier en minutes ou null>,
    "cook_time": <entier en minutes ou null>
  }
}

Règles pour le Cooklang :
- Les ingrédients sont balisés : @nom_ingrédient{quantité%unité}
- Le matériel est balisé : #nom_ustensile{}
- Les timers sont balisés : ~nom_timer{durée%unité}
- Chaque étape est un paragraphe séparé
- Le titre n'est PAS inclus dans le corps Cooklang (il est dans le champ "titre")
- Respecte la langue originale de la recette
```

### Gestion de la réponse

```dart
// Pseudo-code Dart
final response = await geminiModel.generateContent([
  Content.multi([
    TextPart(userPrompt),
    ...imageUrls.map((url) => DataPart('image/jpeg', imageBytes)),
  ])
]);

final jsonString = response.text!
    .replaceAll('```json', '').replaceAll('```', '').trim();
final Map<String, dynamic> parsed = jsonDecode(jsonString);

final draftRecipe = RecipeDraft.fromGeminiJson(parsed);
// → Naviguer vers l'écran de révision split view
```

### Gestion des erreurs Gemini

| Cas | Comportement |
|---|---|
| JSON malformé | Afficher l'éditeur brut avec le texte retourné, inviter à corriger manuellement |
| Champ `cooklang` vide ou absent | Afficher un message d'erreur et permettre une re-tentative ou une saisie manuelle |
| Timeout / erreur réseau | Retry automatique x2, puis message d'erreur avec option de saisie manuelle |
| Image illisible | Gemini retourne un texte d'explication — détecter l'absence de JSON et basculer en mode manuel |

---

## 7. Parsing et Rendu Cooklang

### Parsing

Utilisation du package Dart `cooklang` pour analyser le texte brut :

```dart
final recipe = CooklangRecipe.parse(rawCooklang);
// → recipe.ingredients : List<Ingredient>
// → recipe.steps : List<Step>
// → recipe.cookware : List<Cookware>
```

Le champ `ingredients_index` stocké en Firestore est dérivé du parsing :
```dart
final ingredients = recipe.ingredients
    .map((i) => i.name.toLowerCase().trim())
    .toList();
// Stocké dans recipes.ingredients_index pour la recherche Firestore
```

### Rendu Interactif

Le rendu Cooklang est construit en widgets Flutter :
- Chaque `Ingredient` est affiché avec sa quantité, unité et nom.
- Dans les instructions, les références aux ingrédients sont colorisées (chips inline).
- Les références au matériel sont différenciées visuellement.
- Les timers sont affichés avec une icône et peuvent déclencher un compte à rebours (V2).

---

## 8. Écran de Révision — Split View

### Layout

```
┌────────────────────────────────────────────────────────────┐
│  AppBar : [← Retour]  [Titre éditable]  [Brouillon] [✓ Valider] │
├───────────────────────────┬────────────────────────────────┤
│  ÉDITEUR COOKLANG (brut)  │  RENDU INTERACTIF             │
│                           │                                │
│  @oeufs{3}                │  Ingrédients                  │
│  @farine{200%g}           │  • 3 oeufs                   │
│  ...                      │  • 200g de farine             │
│                           │  ...                           │
│  Mélanger les             │  Instructions                  │
│  @oeufs{3} avec la        │  1. Mélanger les oeufs avec   │
│  @farine{200%g}           │     la farine...               │
│                           │                                │
│  [Saisie responsive]      │  [Lecture seule]               │
├───────────────────────────┴────────────────────────────────┤
│  [Tags] [Page] [Langue]  [📷 Voir scan original]           │
└────────────────────────────────────────────────────────────┘
```

- Sur **Mobile** : les deux panneaux sont scrollables en mode column (l'éditeur en haut, le rendu en dessous) ou en tabs.
- Sur **Web / Desktop** : les deux panneaux sont côte à côte (Row), divisés par un splitter redimensionnable.
- Le rendu se met à jour en temps réel à chaque modification du texte Cooklang (debounce 300ms).

---

## 9. Application Desktop (Windows / macOS)

### Spécificités

- Construite depuis la même codebase Flutter avec le target `flutter build windows` / `flutter build macos`.
- Fenêtre principale redimensionnable, minimum 900×600px.
- Pas d'accès caméra (module scan désactivé conditionnellement : `if (Platform.isAndroid || Platform.isIOS)`).
- Import de fichier image possible via `file_picker` (pour importer des scans déjà faits).
- Raccourcis clavier dans l'éditeur Cooklang (Ctrl+S pour sauvegarder, Ctrl+Z pour annuler).
- Écran de révision split view en mode horizontal natif (pas de tabs).

### Build Desktop

```bash
# Windows
flutter build windows --release

# macOS
flutter build macos --release
```

---

## 10. Application Web

### Spécificités

- Construite avec `flutter build web --release`.
- Hébergée via **Firebase Hosting**.
- Pas d'accès caméra (module scan désactivé).
- Import de fichier image via `file_picker` (web file input).
- Responsive : adapté aux largeurs > 768px (tablette/desktop). En dessous, affichage dégradé ou message d'invitation à utiliser le mobile.
- Le split view est rendu en `Row` avec splitter.
- Authentification Google gérée via le SDK Firebase JS (FlutterFire Web).

### Build Web

```bash
flutter build web --release --base-href /
firebase deploy --only hosting
```

---

## 11. Application Mobile (iOS / Android)

### Spécificités iOS

- `NSCameraUsageDescription` dans `Info.plist`
- `NSPhotoLibraryUsageDescription` dans `Info.plist`
- Google Sign-In configuré via `GoogleService-Info.plist`

### Spécificités Android

- Permissions `CAMERA` et `READ_MEDIA_IMAGES` dans `AndroidManifest.xml`
- Google Sign-In configuré via `google-services.json`
- SHA-1 et SHA-256 enregistrés dans la Firebase Console

### Build Mobile

```bash
# Android
flutter build apk --release
flutter build appbundle --release

# iOS
flutter build ipa --release
```

---

## 12. Architecture Flutter (Couches)

```
lib/
├── main.dart
├── firebase_options.dart          # Généré par FlutterFire CLI
├── core/
│   ├── providers/                 # Riverpod providers globaux
│   ├── router/                    # go_router configuration
│   ├── theme/                     # Thème Material 3
│   └── utils/                     # Helpers (platform, debounce, etc.)
├── features/
│   ├── auth/
│   │   ├── data/                  # AuthRepository (Firebase Auth)
│   │   ├── domain/                # User model, rôles
│   │   └── presentation/          # LoginScreen, UserManagementScreen
│   ├── books/
│   │   ├── data/                  # BooksRepository (Firestore)
│   │   ├── domain/                # Book model
│   │   └── presentation/          # BookListScreen, BookFormScreen
│   ├── recipes/
│   │   ├── data/                  # RecipesRepository, GeminiService, StorageService
│   │   ├── domain/                # Recipe model, CooklangParser wrapper
│   │   └── presentation/
│   │       ├── scan/              # ScanScreen (mobile only)
│   │       ├── review/            # SplitReviewScreen
│   │       ├── detail/            # RecipeDetailScreen
│   │       └── list/              # RecipeListScreen
│   ├── annotations/
│   │   ├── data/                  # AnnotationsRepository
│   │   ├── domain/                # Annotation model
│   │   └── presentation/          # AnnotationSection widget
│   └── admin/
│       └── presentation/          # AdminScreen, UserRoleScreen
└── shared/
    └── widgets/                   # Widgets réutilisables (CooklangRenderer, TagChip, etc.)
```

---

## 13. Roadmap Technique V2

| Fonctionnalité | Complexité | Technologie envisagée |
|---|---|---|
| Extraction auto d'illustrations dans les scans | Élevée | Gemini Vision bounding boxes + découpe image côté client |
| Mode hors-ligne | Moyenne | Firestore offline persistence + Hive pour le cache Cooklang |
| Export PDF d'une recette | Moyenne | `pdf` package Dart |
| Partage externe (lien public) | Faible | Firebase Dynamic Links ou URL personnalisée |
| Timer interactif depuis Cooklang | Faible | Flutter Timer + notifications locales |
| Liste de courses depuis recette | Faible | Extraction `ingredients_index` + UI dédiée |
