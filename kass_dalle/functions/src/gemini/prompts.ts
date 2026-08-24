/**
 * Prompts Gemini portés depuis lib/core/services/gemini_prompts.dart.
 *
 * Conservés à l'identique pour préserver la qualité d'extraction.
 * Toute modification doit être faite ici (côté serveur) — le client ne
 * connaît plus les prompts.
 */

// ── Prompt : conversion texte libre en CookLang ───────────────────────────────

export const GEMINI_FREE_TEXT_PROMPT = String.raw`
Tu es un expert en cuisine et en format CookLang.
L'utilisateur t'a fourni le texte brut d'une recette. Convertis-la en format CookLang strict.

Règle FONDAMENTALE — COPIE FIDÈLE :
- Conserve le texte des étapes AUSSI PROCHE QUE POSSIBLE de l'original.
- Ne reformule PAS, ne résume PAS, ne réinterprète PAS, n'invente AUCUN ingrédient ni quantité.
- Respecte EXACTEMENT les quantités, les ingrédients et le découpage des étapes.
- Ton seul travail est d'identifier les ingrédients (@), les équipements (#) et les timers (~) dans le texte existant.
- Si une information n'est pas dans le texte, ne l'invente pas.

Règles CookLang :
- Métadonnées (lignes commençant par >>) :
    >> titre: Nom de la recette
    >> portions: 4
    >> difficulté: facile|moyen|difficile
    >> temps_préparation: 20 min
    >> temps_cuisson: 35 min
- Les ingrédients sont intégrés dans le texte des étapes : @nom{quantité%unité}
  Un ingrédient est un ALIMENT, une MATIÈRE ou un CONDIMENT tangible. Les verbes d'action
  (mélanger, ajouter, éplucher, ôter, hacher, réhydrater, couper, rincer, égoutter, etc.)
  ne sont JAMAIS des ingrédients — ce sont des instructions à laisser en texte plain.
  Règles importantes sur les unités :
  - Si le texte dit « N brins/gousses/feuilles/bouquets/tiges/filets/noisettes de X » → unité = ce mot, nom = X. Ex : « 1 brin de cerfeuil frais » → @cerfeuil frais{1%brin} ; « 1 filet d'huile » → @huile{1%filet} ; « 1 noisette de beurre » → @beurre{1%noisette}.
  - Les ingrédients comptés à la pièce (blanc de poulet, escalope, filet de poulet, cuisse de poulet, côte de veau, steak, magret, échalote, oignon, poivron, aubergine, courgette…) → unité OBLIGATOIRE = « pièces ». Ex : « 2 blancs de poulet » → @blanc de poulet{2%pièces}, « 1 échalote » → @échalote{1%pièce}.
  - Quantités de contexte (« pour la cuisson », « à volonté », « qsp », « pour décorer ») → laisse la quantité VIDE : @huile{} et NON @huile{pour la cuisson}.
  - papier aluminium, film alimentaire, papier cuisson → TOUJOURS des équipements (#papier aluminium{}, #film alimentaire{}), JAMAIS des ingrédients (@).
  - N'invente pas une unité si elle n'est pas impliquée par le texte, sauf pour les deux règles ci-dessus.
- Les équipements : #nom{quantité}
- Les timers : ~{durée%unité}
- Sections : == Nom de section ==
- Notes : > Texte de la note
- Chaque étape sur une nouvelle ligne distincte.

Retourne UNIQUEMENT le contenu CookLang, sans explication, sans markdown, sans \`\`\`.
Si aucune recette n'est trouvée, retourne exactement : NO_RECIPE
`;

// ── Prompt : extraction couverture de livre ───────────────────────────────────

export const GEMINI_BOOK_COVER_PROMPT = String.raw`
Tu analyses une page de garde de livre de cuisine.
Retourne strictement un JSON valide, sans markdown, sans texte additionnel.

Schema attendu:
{
  "titre": "string",
  "sous_titre": "string|null",
  "auteur": "string",
  "editeur": "string|null",
  "serie": "string|null",
  "annee": 2024,
  "langue": "fr|en|nl",
  "isbn": "string|null",
  "description": "string|null",
  "tags": ["tag1", "tag2"]
}

Contraintes:
- "titre" et "auteur" doivent etre non vides.
- Si valeur inconnue, utilise null.
- "annee" doit etre un entier ou null.
- "langue" doit etre l'une des valeurs fr/en/nl (par defaut fr).
- "tags" doit etre une liste (vide possible).
`;

// ── Prompt : polish CookLang ──────────────────────────────────────────────────

export const GEMINI_POLISH_PROMPT = String.raw`
Tu es un expert culinaire et en format CookLang. On te donne une recette déjà formatée en CookLang.

Ton rôle est de corriger et améliorer ce contenu sans en changer la substance :

1. ORTHOGRAPHE ET GRAMMAIRE :
   - Corrige les fautes d'orthographe, de grammaire et de ponctuation dans les textes des étapes, les noms d'ingrédients et les métadonnées.
   - Corrige les accents manquants ou incorrects.
   - Corrige la capitalisation (titre en titre case, étapes en minuscules).

2. COHÉRENCE SÉMANTIQUE ET CULINAIRE :
   - Si l'ordre des étapes est manifestement illogique (ex : "enfournez" avant "préchauffez le four"), réordonne-les.
   - Corrige les unités manifestement incohérentes (ex : "200 litres de farine" → "200 g de farine").
   - Si un ingrédient est utilisé dans les étapes mais n'apparaît nulle part dans les @balisages, ajoute-le.

3. FORMAT CookLang :
   - Assure-toi que tous les ingrédients sont balisés @nom{qté%unité}.
   - Assure-toi que les équipements sont balisés #nom{}.
   - Les timers doivent être ~{durée%unité}.
   - Un même ingrédient doit toujours avoir exactement la même orthographe dans tout le document.
   - Conserve SANS MODIFICATION les blocs image de la forme ![left](url), ![right](url), ![after](url).
     Ces blocs sont des références d'images insérées par l'utilisateur — ne les supprime pas, ne les déplace pas, ne modifie pas l'URL.

4. MÉTADONNÉES (lignes >>) :
   - Corrige l'orthographe du titre et la capitalisation.
   - Ne change pas les valeurs numériques (portions, temps) sauf erreur manifeste.

Ce que tu NE dois PAS faire :
- Ajouter des ingrédients, des étapes ou des notes qui n'existent pas dans l'original.
- Changer les quantités sans raison évidente.
- Reformuler ou paraphraser les étapes (sauf correction orthographique mineure).
- Changer la structure générale (sections, ordre des sections).

Retourne UNIQUEMENT le contenu CookLang corrigé, sans explication, sans markdown, sans \`\`\`.
`;

// ── Règles communes pour generateRecipe et refineRecipe ───────────────────────

export const COOKLANG_RULES = String.raw`
Règles CookLang (OBLIGATOIRES) :
- Ingrédients : @nom{quantité%unité} — ex : @farine{200%g}, @oeufs{2}, @sel{}
- Matériel : #nom{} — ex : #four{}, #poêle{}
- Temps : ~{hh:mm:ss} — ex : ~{0:30:00} pour 30 minutes, ~{1:30:00} pour 1h30
- Sections de préparation (quand la recette a plusieurs parties distinctes) : == Nom de section ==
- Notes et conseils : > Texte de la note
- Images insérées par l'utilisateur : ![left](url), ![right](url), ![after](url) — conserve-les telles quelles.
- Chaque étape sur une nouvelle ligne distincte.
- Le texte doit être en français.
- INTERDIT : N'utilise JAMAIS ~{0:00:00} — un timer nul n'a aucun sens.
- INTERDIT : Ne mets PAS de timer pour les températures.
- INTERDIT : Les mesures d'épaisseur ou de taille dans le texte (ex: 0.5 cm) ne sont PAS des ingrédients.
- INTERDIT : Ne jamais baliser avec @ le plat ou produit FINAL que la recette crée.
- 1 aliment acheté = 1 seul @balisage chiffré dans toute la recette. Une pièce qui revient découpée ou sous un terme générique (« 4 tranches de viande » après @côte de veau{1.5%kg}, « les légumes » après @carottes{3}) s'écrit en texte plain : ce n'est pas un second achat, et le compter deux fois double les apports de la recette.
- Les timers servent UNIQUEMENT pour des durées réelles de cuisson ou d'attente.
`;
