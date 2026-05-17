/// Prompts Gemini pour GeminiService.
///
/// Extrait de gemini_service.dart pour améliorer la lisibilité.
library;

// ── Prompt principal : extraction de recettes depuis scan ─────────────────────

const kGeminiScanPrompt = r'''
Tu es un expert en cuisine et en format CookLang.
Extrais TOUTES les recettes présentes dans ce document et convertis-les en format CookLang strict.

Règle FONDAMENTALE — COPIE FIDÈLE :
- Conserve le texte des étapes AUSSI PROCHE QUE POSSIBLE de l'original.
- Ne reformule PAS, ne résume PAS, ne réinterprète PAS, n'invente AUCUN ingrédient ni quantité.
- Respecte EXACTEMENT les quantités, les ingrédients et le découpage des étapes du document.
- Si l'original dit "coupez le chou en dés", écris "coupez le @chou{} en dés" — ne remplace pas par une autre formulation.
- Si une information n'est pas dans le document, ne l'invente pas.

Règles CookLang :
- Métadonnées (lignes commençant par >>) :
    >> titre: Nom de la recette
    >> page: 42
    >> portions: 4
    >> difficulté: facile|moyen|difficile
    >> temps_préparation: 20 min
    >> temps_cuisson: 35 min
    >> dish_types: liste séparée par virgules parmi : viande, volaille, poisson, fruits de mer, végétarien, vegan, dessert, pâtisserie, soupe, entrée, plat complet, snack
  Règle importante : si un numéro de page est visible dans le document (coin de page, en-tête, pied de page), indique-le dans « >> page: N ».
- Les ingrédients sont intégrés dans le texte des étapes : @nom{quantité%unité}
  Règles importantes :
  1. Utilise des ESPACES dans les noms multi-mots (jamais des underscores).
  2. Les accolades {} sont obligatoires, et TOUJOURS remplies avec quantité%unité quand connus.
  3. Si l'ingrédient est mesuré en « brin », « filet », « noisette », « pince », « pincee », « bouquet », etc., utilise ce mot comme unité même si c'est aussi le début du nom.
  4. Ne laisse JAMAIS les accolades vides si la quantité ou l'unité est connue.
  5. COHÉRENCE ABSOLUE : utilise EXACTEMENT la même orthographe pour un même ingrédient dans toutes les étapes de la recette (même forme singulier/pluriel, même ordre des mots, même casse). Ne jamais écrire @côte de veau dans une étape et @côtes de veau dans une autre.
  Exemples corrects : @oeufs{3}, @farine{200%g}, @sel{1%pincée}, @brin de romarin{1%brin}, @brin de sauge{2%brins}, @filet d'huile d'olive{1%filet}, @noisette de beurre{1%noisette}, @huile d'olive{2%cuillères à soupe}, @côtes de veau{2%pièces}
  Mauvais exemples (à éviter) : @brin_de_romarin{1}, @brin de romarin{}, @brin_de_romarin{}, écrire @côte de veau dans une étape et @côtes de veau dans une autre
- Les équipements : #nom{quantité}  Exemples : #four{}, #poêle{}, #moule à tarte{}, #moule à muffin{12}, #plaque de cuisson{}, #saladier{}, #casserole{}, #mixeur{}
  RÈGLE CRITIQUE — ustensiles vs ingrédients :
  • Un ustensile, contenant ou accessoire de cuisine est TOUJOURS un équipement (#), JAMAIS un ingrédient (@),
    même si la recette précise une quantité ou des dimensions (ex : "12 moules à muffin" → #moule à muffin{12}).
  • Les mots suivants désignent TOUJOURS des équipements (#) : moule à, plaque, casserole, poêle, saladier,
    bol, mixeur, fouet, spatule, rouleau, tamis, passoire, cocotte, wok, sauteuse, ramequin, terrine.
  • EXCEPTION : « moule » seul (sans complément) peut être le mollusque (@moule{}) ou l'ustensile selon le contexte ;
    si le texte parle de cuisine de pâtisserie/cuisson au four → équipement (#moule{}) ;
    si le texte parle de fruits de mer/plat de la mer → ingrédient (@moule{}).
  • Les températures ("180°C", "thermostat 6") sont du texte plain dans les étapes, jamais des ingrédients (@).
    Écris : "Préchauffez le #four{} à 180°C" et NON "à @180°C{}"
  INTERDIT avec @ :
  • Le plat ou produit FINAL que la recette crée ou confectionne (ex : si la recette fabrique des chaussons, des boulettes, des croquettes, des raviolis… le nom du produit fini N'EST PAS un ingrédient : n'écris JAMAIS @chaussons{}, @boulette{}, etc.).
  • Les instructions de division ou de découpe ("20 parts égales", "en portions"…) : écris-les en texte plain, jamais avec @.
  • Le résultat d'une découpe d'un ingrédient déjà listé : si la recette dit "découpez les blancs de poulet en lanières", l'ingrédient est @blanc de poulet{} ; écris "découpez en lanières" en texte plain — n'écris PAS @lanière de poulet{} séparément.
  • Les sous-préparations fabriquées dans la recette : si une étape prépare une vinaigrette, une sauce, une marinade, une pâte… cette préparation N'EST PAS un ingrédient externe. Dans les étapes suivantes, réfère-t'y en texte plain ("ajoutez la vinaigrette") et NON comme @vinaigrette{}, @sauce{}, @marinade{}.
- Les timers : ~{durée%unité}  Exemples : ~{20%minutes}, ~{1%heure}
- Sections de préparation (quand la recette a plusieurs parties distinctes) : == Nom de section ==
  Exemples : == La sauce ==, == Le montage ==, == La pâte ==
  Mets == Nom == sur sa propre ligne AVANT les étapes de cette partie.
  N'utilise PAS de section si la recette est simple et linéaire.
  GROUPES D'INGRÉDIENTS : si le livre présente les ingrédients divisés en groupes nommés
  (ex : "Pour la marinade :", "Pour le poulet :", "Pour la sauce :", "Pour la pâte :"),
  tu DOIS créer une section == Nom == pour chaque groupe et placer sous cette section
  les étapes qui utilisent ces ingrédients. Respecte l'ordre des groupes du livre.
- Notes et conseils (accompagnement, variante, astuce, conservation…) : > Texte de la note
  Exemples : > Idée d'accompagnement : servir avec une salade verte., > Conseil : peut se préparer la veille.
  Mets > Note sur sa propre ligne, après l'étape concernée ou en fin de recette.
  N'utilise PAS de note si l'information est déjà dans les étapes.
- Chaque étape est une ligne de texte plain
- Séparateur entre plusieurs recettes : ---

Exemple de sortie attendue :
>> titre: Tarte aux pommes
>> page: 42
>> portions: 6
>> difficulté: facile
>> dish_types: dessert, pâtisserie

Préchauffez le #four{} à 180°C.
Épluchez et découpez @pommes{6} en fines tranches.
Étalez la @pâte brisée{1} dans un #moule à tarte{}.
Disposez les pommes et saupoudrez de @sucre roux{2%cuillères à soupe}.
Enfournez pendant ~{35%minutes} jusqu'à coloration dorée.

---

Retourne UNIQUEMENT le contenu demandé, sans explication, sans markdown, sans ``` .
Si plusieurs recettes, sépare-les avec ---.

IMPORTANT — Gestion des pages non-recettes :
Si la page ne contient PAS de recette(s) mais présente un contenu culinaire utile (astuce ou technique culinaire, explication d'ingrédient, description de matériel, cours de cuisine, conseils, glossaire culinaire, etc.), retourne ce contenu sous cette forme exacte :
>> page_type: technique        (pour astuces/techniques culinaires)
             ou equipment       (pour descriptions de matériel/ustensiles)
             ou ingredient_note (pour explications sur les ingrédients)
             ou other           (pour tout autre contenu non-recette utile)
>> titre: Titre ou sujet de la page (5 mots max)
>> page: N   (si un numéro de page est visible)
[Texte COPIÉ MOT POUR MOT depuis le document, sans reformulation, sans résumé, sans ajout.
Respecte exactement les sauts de ligne, les listes, les tirets, les numérotations et la mise en page originale.
Si une image, un schéma ou un diagramme est présent, indique-le brièvement entre crochets : [schéma : description courte].]

Si la page est vide, une page de garde, un index, une table des matières, une publicité ou sans contenu utile : retourne exactement : NO_RECIPE
''';

// ── Prompt : conversion texte libre en CookLang ───────────────────────────────

const kGeminiFreeTextPrompt = r'''
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
  Règles importantes :
  1. Utilise des ESPACES dans les noms multi-mots (jamais des underscores).
  2. Les accolades {} sont obligatoires, et TOUJOURS remplies avec quantité%unité quand connus.
  3. Si l'ingrédient est mesuré en « brin », « filet », « noisette », « pincée », « bouquet », etc., utilise ce mot comme unité même si c'est aussi le début du nom.
  4. Ne laisse JAMAIS les accolades vides si la quantité ou l'unité est connue.
  5. COHÉRENCE ABSOLUE : utilise EXACTEMENT la même orthographe pour un même ingrédient dans toutes les étapes (même forme singulier/pluriel, même ordre des mots). Ne jamais écrire @côte de veau dans une étape et @côtes de veau dans une autre.
  Exemples corrects : @oeufs{3}, @farine{200%g}, @sel{1%pincée}, @brin de romarin{1%brin}, @brin de sauge{2%brins}, @filet d'huile d'olive{1%filet}, @noisette de beurre{1%noisette}, @huile d'olive{2%cuillères à soupe}
  Mauvais exemples (à éviter) : @brin_de_romarin{1}, @brin de romarin{}, @brin_de_romarin{}, écrire @côte de veau dans une étape et @côtes de veau dans une autre
- Les équipements : #nom{quantité}  Exemples : #four{}, #poêle{}, #moule à muffin{12}, #plaque de cuisson{}, #saladier{}
  RÈGLE CRITIQUE — ustensiles vs ingrédients :
  • Un ustensile, contenant ou accessoire de cuisine est TOUJOURS un équipement (#), JAMAIS un ingrédient (@),
    même si la recette précise une quantité ou des dimensions (ex : "12 moules à muffin" → #moule à muffin{12}).
  • Les mots suivants désignent TOUJOURS des équipements (#) : moule à, plaque, casserole, poêle, saladier,
    bol, mixeur, fouet, spatule, rouleau, tamis, passoire, cocotte, wok, sauteuse, ramequin, terrine.
  • EXCEPTION : « moule » seul peut être le mollusque (@moule{}) ou l'ustensile selon le contexte.
  • Les températures ("180°C") sont du texte plain, jamais des ingrédients (@).
    Écris : "Préchauffez le #four{} à 180°C" et NON "à @180°C{}"
  INTERDIT avec @ :
  • Le plat ou produit FINAL que la recette crée ou confectionne (ex : si la recette fabrique des chaussons, des boulettes, des croquettes, des raviolis… le nom du produit fini N'EST PAS un ingrédient : n'écris JAMAIS @chaussons{}, @boulette{}, etc.).
  • Les instructions de division ou de découpe ("20 parts égales", "en portions"…) : écris-les en texte plain, jamais avec @.
  • Le résultat d'une découpe d'un ingrédient déjà listé : si la recette dit "découpez les blancs de poulet en lanières", l'ingrédient est @blanc de poulet{} ; écris "découpez en lanières" en texte plain — n'écris PAS @lanière de poulet{} séparément.
  • Les sous-préparations fabriquées dans la recette : si une étape prépare une vinaigrette, une sauce, une marinade, une pâte… cette préparation N'EST PAS un ingrédient externe. Dans les étapes suivantes, réfère-t'y en texte plain ("ajoutez la vinaigrette") et NON comme @vinaigrette{}, @sauce{}, @marinade{}.
- Les timers : ~{durée%unité}  Exemples : ~{20%minutes}, ~{1%heure}
- Sections de préparation (quand la recette a plusieurs parties distinctes) : == Nom de section ==
  Exemples : == La sauce ==, == Le montage ==, == La pâte ==
  Mets == Nom == sur sa propre ligne AVANT les étapes de cette partie.
  N'utilise PAS de section si la recette est simple et linéaire.
  GROUPES D'INGRÉDIENTS : si le texte présente les ingrédients divisés en groupes nommés
  (ex : "Pour la marinade :", "Pour le poulet :", "Pour la sauce :", "Pour la pâte :"),
  tu DOIS créer une section == Nom == pour chaque groupe et placer sous cette section
  les étapes qui utilisent ces ingrédients. Respecte l'ordre des groupes.
- Notes et conseils (accompagnement, variante, astuce, conservation…) : > Texte de la note
  Exemples : > Idée d'accompagnement : servir avec une salade verte., > Conseil : peut se préparer la veille.
  Mets > Note sur sa propre ligne, après l'étape concernée ou en fin de recette.
  N'utilise PAS de note si l'information est déjà dans les étapes.
- Chaque étape est une ligne de texte plain

Retourne UNIQUEMENT le contenu CookLang, sans explication, sans markdown, sans ```.
Si aucune recette n'est trouvée, retourne exactement : NO_RECIPE
''';

// ── Prompt : extraction couverture de livre ───────────────────────────────────

const kGeminiBookCoverPrompt = r'''
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
''';

// ── Préfixe multi-pages ───────────────────────────────────────────────────────

const kGeminiMultiPagePrefix = r'''
IMPORTANT : Les images fournies sont des PAGES CONSÉCUTIVES d'un même document.
Traite-les comme un document continu, dans l'ordre où elles apparaissent.
Une recette peut commencer sur une page et se terminer sur la suivante : dans ce cas, reconstitue-la en une seule recette complète.
Ne retourne PAS NO_RECIPE simplement parce qu'une page seule semble incomplète.

''';
