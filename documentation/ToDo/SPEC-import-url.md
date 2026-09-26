# Kass'Dalle — Spec : import de recettes depuis une URL

> Statut : proposition · Cible : 0.20.x · Auteur : Frédéric
> Ce document décrit le **quoi** et le **pourquoi**. Les choix d'implémentation détaillés (noms de classes, découpage des fichiers) restent à l'appréciation de l'implémenteur, dans le respect des conventions existantes du dépôt.

---

## 1. Objectif

Permettre à un utilisateur (rôle `editor` ou `admin`) d'importer une recette publiée sur un site web à partir de son URL, depuis **toutes les plateformes** (APK Android, iOS, Windows desktop, Web/Chrome). La recette doit arriver :

- **traduite en français** si la source est dans une autre langue ;
- **convertie en système métrique**, avec les unités françaises (g, kg, ml, cl, l, c. à s., c. à c., °C, cm) ;
- sous forme de **brouillon à relire** avant enregistrement, passé par le pipeline de normalisation existant (catalogue canonique, `nutrition_units`, anti-doublons).

### Hors périmètre

- Aucun crawl de site entier, aucune importation en masse automatique : **une URL = une action utilisateur**.
- Pas de copie des photos du site dans Storage (voir §9).
- Pas de contournement de paywall, de connexion ou de protection anti-bot côté serveur.

---

## 2. Points d'entrée par plateforme

Tous les points d'entrée aboutissent au **même écran** : `Importer › Depuis une page web`, avec l'URL pré-remplie quand elle est connue. Route go_router dédiée, par exemple `/import/url?u=<url encodée>`.

| Plateforme | Points d'entrée | Phase |
|---|---|---|
| Toutes | Menu **Importer › Depuis une page web** : champ URL, bouton « Coller », détection d'une URL dans le presse-papiers à l'ouverture (proposition, jamais d'import automatique) | V1 |
| Android (APK) | **Partager → Kass'Dalle** depuis n'importe quel navigateur (intent `ACTION_SEND`, `text/plain`). Le texte partagé contient souvent titre + URL : extraire la première URL http(s) | V1 |
| Web (Chrome) | Lien profond `/import/url?u=…` ; **bookmarklet** « → Kass'Dalle » fourni dans les réglages, qui ouvre l'appli web avec l'URL de la page courante | V1.1 |
| Windows desktop | Coller, **glisser-déposer** une URL depuis le navigateur sur la fenêtre ou l'écran d'import | V1.1 |
| iOS | Share Extension (cible Xcode dédiée + App Group) | V2 |
| Web (Chrome Android, PWA installée) | `share_target` dans le manifest | V2 |
| Android, iOS, Windows | **Navigateur intégré** « Parcourir et importer » : l'utilisateur ouvre le site dans une WebView, le bouton « Importer cette page » extrait les données **côté client** (voir §4.2). Sert de repli pour les sites qui bloquent le fetch serveur | V2 |

Le Web ne peut pas avoir de WebView (les sites interdisent l'iframe) : son repli est le texte collé (import texte libre existant) ou, en V2, un bookmarklet enrichi qui transmet le JSON-LD extrait de la page.

---

## 3. Parcours utilisateur

1. L'utilisateur fournit une URL, par n'importe quel point d'entrée.
2. Kass'Dalle vérifie les **doublons** (URL canonique déjà importée dans le groupe) et prévient : « Déjà importée dans *Livre X* le 12/09 — ouvrir / importer quand même ».
3. Il choisit le **livre de destination** (par défaut : livre « Web », créé au besoin) et laisse cochée l'option **Traduire en français**, cochée par défaut et sans effet si la source est déjà en français.
4. Un job d'import démarre. L'écran affiche la progression par étape (récupération → extraction → analyse → traduction → conversion) et reste utilisable : l'utilisateur peut quitter l'écran, le job continue.
5. **Écran de relecture** (brouillon) :
   - titre, portions, temps, ingrédients, étapes, dans la présentation habituelle de l'éditeur ;
   - chaque ligne d'ingrédient convertie affiche un badge : `converti`, `estimé` (conversion volume → poids par densité) ou `à vérifier` (non résolu) ; un appui montre le texte d'origine (« 1 cup plain flour ») ;
   - liste des avertissements en haut (unités résiduelles dans les étapes, ingrédient inconnu du catalogue, portions absentes…) ;
   - bascule **Voir l'original** : texte source complet, non traduit ;
   - lien et attribution de la source.
6. L'utilisateur corrige si besoin puis **Enregistre** ; la recette rejoint le livre choisi. Il peut aussi **Abandonner** le brouillon.

Erreurs affichées en français, chacune avec une action proposée :

| Cas | Message et action |
|---|---|
| Site bloquant (403, anti-bot) | « Ce site refuse l'accès automatique. » → *Ouvrir dans le navigateur intégré* (mobile/desktop) ou *Coller le texte de la recette* |
| Pas de recette détectée | « Aucune recette trouvée sur cette page. » → *Coller le texte* |
| Paywall ou connexion requise | Même traitement que le site bloquant |
| Quota atteint | « Limite d'imports atteinte pour aujourd'hui (N/jour). » |

---

## 4. Architecture

### 4.1 Vue d'ensemble

```
App (toutes plateformes)
  └─ callable startUrlImport({ url, bookId, translate, clientPayload? })
       └─ crée import_jobs/{jobId} (status=queued) → renvoie jobId
App écoute import_jobs/{jobId} (Firestore snapshot)

Trigger onCreate import_jobs/{jobId}  → worker
  1. acquire    : fetch serveur sécurisé OU clientPayload
  2. extract    : JSON-LD → microdata → repli LLM
  3. parse      : lignes d'ingrédients → {quantité, unité, ingrédient, note}
  4. translate  : LLM, sortie structurée, glossaire culinaire
  5. resolve    : ingrédients → catalogue canonique (pipeline existant)
  6. convert    : déterministe, via nutrition_units + densités
  7. normalize  : pipeline existant → CookLang + validation
  8. status = ready_for_review (draft complet dans le job)

App : écran de relecture → saveImportedRecipe(jobId, draft édité)
```

Pourquoi un job asynchrone plutôt qu'une callable synchrone : l'étape LLM peut dépasser quelques secondes ; le client doit survivre à une mise en arrière-plan ; ce modèle servira aussi au futur import de photos par lot.

**Un seul chemin serveur pour toutes les plateformes.** Les différences entre plateformes s'arrêtent à la façon de fournir l'URL ou le `clientPayload`.

### 4.2 Acquisition

**Fetch serveur** (chemin par défaut)
- Schémas `http`/`https` uniquement, ports 80/443.
- **Protection SSRF** : résolution DNS puis refus des IP privées, loopback, link-local et metadata (IPv4 et IPv6), **re-vérification à chaque redirection**, 3 redirections au maximum.
- Délai maximal 10 s, taille maximale 3 Mo, `Content-Type` HTML obligatoire.
- User-Agent honnête, par exemple `KassDalle/0.20 (+url du site)`, pas d'usurpation de navigateur.
- Le HTML brut est stocké dans Storage (`imports/{jobId}/source.html`) pour le débogage et la ré-exécution, puis purgé après 30 jours.

**`clientPayload`** (navigateur intégré, bookmarklet V2)
- Contenu : `{ url, jsonLd: [...], pageText, lang }`, extrait par un script dans la WebView.
- Traité comme **donnée non fiable** : taille plafonnée (500 Ko), validation de schéma, jamais interprété comme HTML ou comme code.

### 4.3 Extraction (ordre de priorité)

1. **JSON-LD** : parcourir tous les `<script type="application/ld+json">`, gérer `@graph`, les tableaux, les `@type` multiples ; retenir l'objet `Recipe`.
   Correspondances : `name`, `recipeYield`, `prepTime`/`cookTime`/`totalTime` (durées ISO 8601 → minutes), `recipeIngredient[]`, `recipeInstructions` (chaîne, `HowToStep[]` ou `HowToSection[]` → sections), `author`, `image`, `inLanguage`, `recipeCategory`, `recipeCuisine`, `keywords`.
2. **Microdata** `itemtype=schema.org/Recipe`, en repli.
3. **LLM** sur le texte principal nettoyé (navigation, publicités et commentaires retirés), avec une sortie contrainte au même schéma que (1).

Le job consigne la méthode utilisée (`jsonld` | `microdata` | `llm`), utile pour les KPI admin.

*Option à évaluer* : la bibliothèque Python `recipe-scrapers` (gère des centaines de sites), dans une Cloud Function Python isolée. V1 : extracteur TypeScript maison pour rester sur une seule stack ; décision à revoir si le taux de repli LLM est élevé.

### 4.4 Analyse des ingrédients

Chaque ligne (« 1 x 400g tin of chopped tomatoes », « 2–3 tbsp olive oil », « ½ bunch of fresh coriander ») devient :
`{ qty, qtyMax?, unitRaw, ingredientRaw, note, sourceText }`

- Parseur déterministe d'abord : fractions Unicode et textuelles (`½`, `1 1/2`), plages (`2-3`, `2 to 3`), multiplicateurs (`1 x 400g`), quantités vagues (`a pinch`, `to taste`, `une pincée`).
- Les lignes non comprises partent au LLM, **dans le même appel** que la traduction, pour éviter un aller-retour.

### 4.5 Traduction

- Détection de la langue source : `inLanguage`, `<html lang>`, sinon détection par le LLM. Si la source est déjà en français, cette étape est sautée.
- Un seul appel LLM avec **sortie JSON structurée** : titre, ingrédients (nom et note), étapes, conseils. Les quantités ne sont jamais modifiées par le LLM ; il ne reçoit que les textes.
- **Glossaire culinaire** stocké dans Firestore (`translation_glossary`), éditable depuis l'écran admin et injecté dans le prompt. Exemples de faux amis et de termes régionaux :
  - *plain flour* → farine T55 ; *self-raising flour* → farine à levure incorporée ;
  - *caster sugar* → sucre semoule fin ; *icing sugar* → sucre glace ;
  - *single / double cream* → crème liquide / crème épaisse (≥ 30 %) ;
  - *courgette / zucchini* → courgette ; *aubergine / eggplant* → aubergine ;
  - *coriander* → coriandre (feuilles) ; *ground coriander* → coriandre moulue ;
  - *spring onion / scallion* → oignon nouveau ; *stock cube* → cube de bouillon.
- Consigne explicite au LLM : dans les étapes, **ne garder que des unités métriques** (voir §4.6, vérification finale).
- Le texte d'origine complet est conservé dans `recipe.original` pour permettre une nouvelle traduction plus tard.

### 4.6 Conversion d'unités (déterministe, pas de LLM)

La conversion se fait **après la résolution de l'ingrédient** dans le catalogue canonique, parce que la conversion volume → poids dépend de l'ingrédient.

| Source | Cible | Règle |
|---|---|---|
| oz, lb | g, kg | 1 oz = 28,35 g ; 1 lb = 453,6 g |
| fl oz, pint, quart, gallon | ml, cl, l | **selon la locale du site** : pint UK = 568 ml, pint US = 473 ml ; fl oz UK = 28,4 ml, US = 29,6 ml |
| cup | g (ingrédients secs, si densité connue) sinon ml | cup US = 240 ml, cup métrique AU/NZ = 250 ml ; volume × densité de l'ingrédient |
| tbsp, tsp | c. à s., c. à c. | conservées en cuillères françaises : c. à s. = 15 ml, c. à c. = 5 ml (tbsp australien = 20 ml → convertir en ml) |
| stick (of butter) | g | 1 stick = 113 g |
| °F | °C | arrondi à 5 °C près (350 °F → 180 °C) |
| gas mark | °C | table : 4 → 180 °C, 6 → 200 °C, etc. |
| inch | cm | arrondi au cm (9-inch tin → moule de 23 cm) |

- **Densités** : nouvelle table ou champ `density_g_per_ml` sur les ingrédients canoniques (farine ≈ 0,53 ; sucre semoule ≈ 0,85 ; riz ≈ 0,78 ; beurre ≈ 0,91…). En l'absence de densité : conversion en ml et badge `à vérifier`.
- **Arrondis lisibles** : < 20 g → au gramme ; 20–250 g → à 5 g près ; > 250 g → à 10 g près ; même logique pour les ml. Pas de « 113 g », mais « 115 g » (sauf beurre en stick si l'on veut garder la précision — paramétrable).
- Chaque conversion porte une **confiance** : `exact` (masse ou volume direct), `estimated` (par densité), `unresolved`.
- **Vérification finale des étapes** : une expression régulière détecte les unités impériales restantes dans le texte traduit (`°F`, `oz`, `cup`, `inch`, `pint`, `lb`). S'il en reste, un avertissement est affiché ; si la conversion est non ambiguë (température, dimension de moule), elle est appliquée automatiquement.
- Ce module est **partagé** : il s'intègre au pipeline de normalisation commun et bénéficie ainsi aux imports photo, PDF et texte (livres anglais scannés).

### 4.7 Normalisation et sortie

Le brouillon traduit et converti passe dans le **pipeline existant** (résolution, fallback, CookLang, validation, anti-doublons). Aucun chemin parallèle : l'import par URL n'est qu'une nouvelle *source* du pipeline.

### 4.8 Fournisseur LLM

Les appels passent par une **interface fournisseur** (Gemini aujourd'hui, Anthropic possible demain). Chaque job enregistre `provider`, `model`, `inputTokens`, `outputTokens` et le coût estimé : cela alimente directement la comparaison de coût Gemini / Anthropic.

Sécurité des prompts : le contenu de la page est passé au LLM comme **donnée**, dans un bloc délimité, avec une consigne qui ignore toute instruction qu'il contiendrait. La sortie est validée par schéma ; en cas d'échec, le job passe en `failed` avec la raison.

---

## 5. Modèle de données

### `import_jobs/{jobId}`

```
status        : queued | fetching | extracting | parsing | translating
                | converting | ready_for_review | saved | failed | discarded
step          : libellé de progression (pour l'UI)
createdBy     : uid        groupId : id du groupe familial
createdAt / updatedAt / expiresAt (TTL 30 jours si non enregistré)
request       : { url, bookId, translate, via: menu|share|deeplink|bookmarklet|dragdrop|webview }
source        : { url, canonicalUrl, urlHash, domain, siteName, author, lang, locale }
acquisition   : { method: server|client, httpStatus, bytes, storagePath }
extraction    : { method: jsonld|microdata|llm }
draft         : recette complète au format interne (avant enregistrement)
lines         : [{ sourceText, qty, unit, ingredientId, confidence, converted:{from,to} }]
warnings      : [{ code, message, lineIndex? }]
llm           : { provider, model, inputTokens, outputTokens, costEstimate }
error         : { code, message }   (si failed)
recipeId      : id de la recette créée (si saved)
```

### Recette (champs ajoutés)

```
source   : { type: 'web', url, canonicalUrl, siteName, author, importedAt, importJobId }
original : { lang, title, ingredients[], instructions[] }   // texte non traduit
imageUrl : lien vers l'image source (non copiée)
```

### Autres

- `url_cache/{urlHash}` : résultat d'extraction brut (avant traduction), TTL 30 jours — évite de recharger une page importée par un autre membre.
- `translation_glossary/{id}` : `{ en, fr, note }`, éditable en admin.
- Densités : champ sur les ingrédients canoniques, ou table dédiée — à trancher selon la structure actuelle de `nutrition_units`.

### Anti-doublons

Clé = hash de l'**URL canonique** (`<link rel=canonical>` sinon URL nettoyée : sans paramètres `utm_*`, sans fragment, en minuscules pour l'hôte). La vérification se fait **avant** le fetch (sur l'URL fournie) et **après** (sur l'URL canonique).

---

## 6. Sécurité et règles

- Callable `startUrlImport` : authentification obligatoire, **App Check**, rôle `editor` ou `admin`.
- **Quota** par utilisateur (défaut 30/jour, paramétrable en admin) et par groupe.
- Règles Firestore : un job n'est lisible que par son créateur et les admins du groupe ; écriture réservée au serveur (sauf `status = discarded` par le créateur).
- `saveImportedRecipe` revalide le brouillon côté serveur : le client ne peut pas injecter une recette hors schéma via ce chemin.
- Journalisation : domaine, méthode, durée, statut — **pas** le contenu des pages dans les logs.

---

## 7. Écran d'administration et KPI

Ajouts à l'écran admin existant :
- imports par jour, taux de succès, répartition par méthode d'extraction (jsonld / microdata / llm) ;
- top des domaines, et domaines en échec récurrent (403 → candidats au navigateur intégré) ;
- taux de lignes `estimated` / `unresolved` : oriente l'enrichissement des densités et du catalogue ;
- coût LLM cumulé par fournisseur ;
- édition du glossaire de traduction et du quota.

---

## 8. Tests

- **Fixtures HTML** enregistrées (pas d'appel réseau en test) : jamieoliver.com, bbcgoodfood.com, allrecipes.com (cups US), une page australienne (cup 250 ml, tbsp 20 ml), marmiton.org, 750g.com, une page sans JSON-LD, une page avec `@graph`, une page avec `HowToSection`.
- **Tests unitaires du parseur** : table de cas (fractions, plages, multiplicateurs, quantités vagues, FR et EN).
- **Tests unitaires du convertisseur** : table de cas avec résultat attendu et confiance, y compris UK / US, arrondis, °F et gas mark, inches.
- **Tests SSRF** : IP privées, IPv6 loopback, redirection vers une IP interne, schéma `file:`, port non standard.
- **Test de bout en bout** : URL → job → brouillon → enregistrement, sur l'émulateur Firebase avec un LLM simulé.

---

## 9. Attribution et usage

- La source (site, auteur, lien) est affichée en mode lecture et dans l'export PDF.
- L'image n'est pas copiée : affichage par lien, et l'utilisateur peut la remplacer par sa propre photo (retouche intégrée existante).
- Usage limité au groupe familial ; aucune fonction de republication publique.

---

## 10. Critères d'acceptation (V1)

- [ ] Depuis Android, « Partager → Kass'Dalle » sur une recette jamieoliver.com ouvre l'écran d'import avec l'URL et produit un brouillon en français, avec des ingrédients en g / ml / c. à s. / c. à c. et des températures en °C.
- [ ] Le même import fonctionne en collant l'URL sur Windows, sur le Web (Chrome) et sur l'APK.
- [ ] Une recette en « 1 cup plain flour » donne « 120 g de farine T55 » avec le badge `estimé`, et l'original est consultable.
- [ ] Aucune unité impériale ne subsiste dans les étapes, ou un avertissement est affiché.
- [ ] Une URL déjà importée dans le groupe déclenche l'avertissement de doublon.
- [ ] Un site bloquant produit un message clair avec une alternative, sans plantage.
- [ ] Une URL vers une IP privée est refusée.
- [ ] Le job enregistre la méthode d'extraction, le fournisseur LLM et les tokens consommés.
- [ ] Un utilisateur `reader` ne voit pas l'option et la callable le refuse.

---

## 11. Découpage proposé

| Phase | Contenu |
|---|---|
| **V1** | Menu Importer › Depuis une page web (toutes plateformes) · partage Android · job asynchrone · fetch serveur sécurisé · JSON-LD + microdata + repli LLM · parseur · traduction + glossaire · conversion + densités · écran de relecture · anti-doublons · quotas · KPI de base |
| **V1.1** | Lien profond web + bookmarklet · glisser-déposer Windows · cache d'URL · édition du glossaire en admin |
| **V2** | Navigateur intégré (Android / iOS / Windows) avec `clientPayload` · Share Extension iOS · `share_target` PWA · évaluation de `recipe-scrapers` |
