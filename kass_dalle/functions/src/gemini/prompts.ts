/**
 * Prompts Gemini portés depuis lib/core/services/gemini_prompts.dart.
 *
 * Conservés à l'identique pour préserver la qualité d'extraction.
 * Toute modification doit être faite ici (côté serveur) — le client ne
 * connaît plus les prompts.
 */

// ── Prompt principal : extraction de recettes depuis scan ─────────────────────

// ── Prompt 1/2 : classification de la page (appel court, retourne JSON) ──────

export const GEMINI_CLASSIFY_PROMPT = String.raw`
Tu es un expert en analyse de documents culinaires.
Analyse le contenu de cette page et détermine son type.

Règle unique pour identifier une RECETTE :
  Une recette = une SÉQUENCE D'ÉTAPES DE FABRICATION d'un plat (mélanger, cuire, faire revenir, incorporer...).
  Ce n'est PAS une recette si :
    - La page présente ou décrit des ingrédients (origine, saveur, comment les choisir, à quoi ils servent)
    - La page liste des produits à avoir dans son placard ou à acheter
    - Les verbes présents DÉCRIVENT l'ingrédient (ex: "s'utilise dans", "se conserve", "apporte une saveur")
    → Dans tous ces cas : c'est "ingredient_note", pas "recipe".

Types disponibles :
  "recipe"          → séquence de préparation complète pour fabriquer un plat
  "ingredient_note" → présentation/liste d'ingrédients, placard, courses, produits de base
  "technique"       → technique gestuelle (pliage, façonnage, découpe...) sans recette complète
  "equipment"       → description de matériel ou ustensiles
  "other"           → introduction, conseils généraux, glossaire, biographie...
  "no_recipe"       → page vide, de garde, index, table des matières, pub, photo sans texte

Retourne UNIQUEMENT un JSON valide (sans markdown, sans texte additionnel).
IMPORTANT : écris d'abord "reasoning" (ta justification) AVANT "page_type".

⚠️ RÈGLE DE COHÉRENCE ABSOLUE :
Si ton reasoning dit que la page n'a pas d'étapes de préparation ("sans séquence", "sans étape", "liste d'ingrédients", etc.),
alors page_type DOIT être "ingredient_note" (ou un autre type non-recette) — JAMAIS "recipe".
Un LLM qui écrit "sans étapes" dans son reasoning et "recipe" dans page_type commet une ERREUR.

{
  "reasoning": "<une phrase : quelle preuve concrète justifie ce type ? cite un élément du texte>",
  "page_type": "<type>",
  "titre": "<titre court de la page, 5 mots max>",
  "page": <numéro de page si visible dans le document, sinon null>
}
`;

// ── Prompt 2/2a : extraction CookLang (uniquement si page_type = recipe) ─────

export const GEMINI_SCAN_PROMPT = String.raw`
Tu es un expert en cuisine et en format CookLang.
Cette page a déjà été classifiée comme contenant une ou plusieurs RECETTES.
Extrais TOUTES les recettes présentes et convertis-les en format CookLang strict.

Règle FONDAMENTALE — TRANSCRIPTION, PAS RÉÉCRITURE :
Ton travail est de TRANSCRIRE puis de BALISER. Ce n'est pas d'écrire une recette.
Le seul changement autorisé sur le texte du livre est l'ajout des balises @ # ~ .
Tu n'as le droit de rien retirer, rien fusionner, rien raccourcir, rien reformuler.

**Cette règle porte sur les ÉTAPES — le texte de la méthode. Pas sur la liste d'ingrédients.**
Une page de livre a deux parties : une LISTE d'ingrédients (souvent en colonne, à puces) et des ÉTAPES.
- La LISTE ne se transcrit JAMAIS telle quelle. Elle n'apparaît nulle part en tant que bloc, ni au début, ni à la fin. Elle sert uniquement à connaître les QUANTITÉS.
- Les ÉTAPES se transcrivent mot pour mot, et c'est DANS elles que chaque ingrédient est balisé, avec la quantité lue dans la liste.
- Conséquence : chaque ingrédient apparaît **une seule fois** dans ta sortie — à sa première mention dans les étapes. Ni deux, ni trois.
- Si tu écris une phrase qui ressemble à « Ingrédients : 500 g de… », tu t'es trompé : cette phrase n'existe pas en CookLang.

- **Phrase par phrase.** Si une étape du livre compte six phrases, ton étape en compte six. Recopie-les dans l'ordre, avec leurs précisions : températures, durées, contenants, gestes, mises en garde, « si nécessaire… », « jusqu'à ce que… ».
- **Étape par étape.** Si le livre numérote ses étapes, ta sortie a EXACTEMENT le même nombre d'étapes, dans le même ordre, avec les mêmes numéros. Jamais deux étapes fondues en une.
- **Aucune méthode de cuisson inventée ni remplacée.** Si le livre fait blanchir dans une casserole d'eau, tu ne le fais pas revenir à la poêle. Le geste écrit est le geste, même s'il te paraît inhabituel, long ou inutile.
- Si l'original dit "coupez le chou en dés", écris "coupez le @chou{} en dés" — le mot à mot, plus une balise.
- Si une information n'est pas dans le document, ne l'invente pas.

CONTRE-EXEMPLE — le défaut le plus grave, à ne jamais reproduire :
  Le livre écrit :
    « Mettez la poitrine dans une casserole, recouvrez d'eau et portez à ébullition.
      Filtrez, rincez sous l'eau froide et retirez la couenne. Découpez en petits
      morceaux que vous ferez frire et dorer. Égouttez sur un papier absorbant.
      Dans une casserole, mettez les oignons, le sucre et le beurre juste recouverts
      d'eau. Portez à ébullition et laissez mijoter jusqu'à ce que toute l'eau se
      soit évaporée. »
  Sortie INTERDITE (résumé, méthode changée, sept phrases devenues deux) :
    « Faites revenir la @poitrine fumée{185%g} dans une #poêle{}. Ajoutez les
      @oignons grelots{200%g} et le @sucre{20%g}, laissez mijoter. »
  Sortie ATTENDUE : les sept phrases, dans l'ordre, chacune balisée.
  Une recette raccourcie n'est pas une recette « propre » : c'est une recette FAUSSE,
  qui ne donnera pas le plat du livre.

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
  0. TOUT ingrédient de la liste du livre doit être balisé dans une étape, et chacun une seule fois. Avant de répondre, reprends la liste du livre ligne à ligne et vérifie que chacune se retrouve balisée quelque part dans tes étapes. Un ingrédient acheté et jamais balisé est un ingrédient qui manquera à la liste de courses.
     Cas particulier : si un ingrédient de la liste n'est utilisé dans AUCUNE étape du livre, ajoute en fin de sa section une ligne « Prévoir également @nom{quantité%unité}. » — une ligne, à sa place, plutôt qu'un bloc inventé.
  1. Utilise des ESPACES dans les noms multi-mots (jamais des underscores).
  2. Les accolades {} sont obligatoires, et TOUJOURS remplies avec quantité%unité quand connus.
  3. Si le nom de l'ingrédient commence par une unité de mesure (« brin », « brins », « gousse », « gousses », « filet », « noisette », « pincée », « bouquet », etc.), utilise CE MOT comme unité et le reste comme nom. Ex : « 1 brin de cerfeuil frais » → @cerfeuil frais{1%brin} ; « 2 gousses d'ail » → @ail{2%gousse}.
  4. Les ingrédients comptés à la pièce (blanc de poulet, filet de poulet, escalope, cuisse de poulet, côte de veau, steak, magret de canard…) → unité OBLIGATOIRE = « pièces ». Ex : @blanc de poulet{2%pièces}.
  5. Ne laisse JAMAIS les accolades vides si la quantité ou l'unité est connue. Si la quantité n'est qu'une indication de contexte (« pour la cuisson », « pour décorer », « à volonté », « qsp », « au goût », « un peu »), laisse la quantité VIDE : @huile{} et NON @huile{pour la cuisson}.
  6. Les légumes et aromates comptés entiers (échalote, oignon, poivron, aubergine, courgette…) → unité = « pièces ». Ex : @échalote{1%pièce}.
  7. COHÉRENCE ABSOLUE ET ANTI-DOUBLONS : utilise EXACTEMENT la même orthographe pour un même ingrédient dans toutes les étapes. INTERDIT de créer deux @-balisages différents pour le même aliment physique : si @blancs de poulet{2%pièces} est déjà déclaré, n'écris JAMAIS @poulet{} ailleurs — utilise @blancs de poulet{}. Si @cerfeuil frais{1%brin} est déjà déclaré, n'écris JAMAIS @brins de cerfeuil frais{} ni @cerfeuil{} ailleurs. Règle : 1 aliment = 1 orthographe unique dans toute la recette.
  Exemples corrects : @oeufs{3}, @farine{200%g}, @sel{1%pincée}, @cerfeuil frais{1%brin}, @ail{2%gousse}, @blanc de poulet{2%pièces}, @huile{1%filet}, @beurre{1%noisette}, @huile d'olive{2%c.à.s.}, @côtes de veau{2%pièces}
  Mauvais exemples (à éviter) : @brin_de_romarin{1}, @brin de cerfeuil frais{1}, @blanc de poulet{2} (sans unité), @filet d'huile{1%filet} ("filet" reste dans le nom), @noisette de beurre{1%noisette} (écrire à la place @beurre{1%noisette}), écrire @côte de veau dans une étape et @côtes de veau dans une autre
- Les équipements : #nom{quantité}  Exemples : #four{}, #poêle{}, #moule à tarte{}, #moule à muffin{12}, #plaque de cuisson{}, #saladier{}, #casserole{}, #mixeur{}, #papier aluminium{}, #film alimentaire{}, #papier cuisson{}
  RÈGLE CRITIQUE — ustensiles vs ingrédients :
  • Un ustensile, contenant ou accessoire de cuisine est TOUJOURS un équipement (#), JAMAIS un ingrédient (@),
    même si la recette précise une quantité ou des dimensions (ex : "12 moules à muffin" → #moule à muffin{12}).
  • Les mots suivants désignent TOUJOURS des équipements (#) : moule à, plaque, casserole, poêle, saladier,
    bol, mixeur, fouet, spatule, rouleau, tamis, passoire, cocotte, wok, sauteuse, ramequin, terrine,
    papier aluminium, aluminium, film alimentaire, papier cuisson, papier sulfurisé.
  • EXCEPTION : « moule » seul (sans complément) peut être le mollusque (@moule{}) ou l'ustensile selon le contexte ;
    si le texte parle de cuisine de pâtisserie/cuisson au four → équipement (#moule{}) ;
    si le texte parle de fruits de mer/plat de la mer → ingrédient (@moule{}).
  • Les températures ("180°C", "thermostat 6") sont du texte plain dans les étapes, jamais des ingrédients (@).
    Écris : "Préchauffez le #four{} à 180°C" et NON "à @180°C{}"
  INTERDIT avec @ :
  • Les verbes d'action culinaire : des mots comme mélanger, ajouter, éplucher, ôter, garder, hacher, réhydrater, couper, rincer, égoutter, ciseler, émincer, dorer, faire revenir, incorporer, fouetter, pétrir, etc. sont des INSTRUCTIONS, JAMAIS des ingrédients. Un ingrédient est toujours un ALIMENT, une MATIÈRE ou un CONDIMENT tangible qu'on ajoute à la recette. Si une ligne de texte commence par ou contient principalement un verbe à l'infinitif ou à l'impératif, c'est une étape, pas un ingrédient.
  • Le plat ou produit FINAL que la recette crée ou confectionne (ex : si la recette fabrique des chaussons, des boulettes, des croquettes, des raviolis… le nom du produit fini N'EST PAS un ingrédient : n'écris JAMAIS @chaussons{}, @boulette{}, etc.).
  • Les instructions de division ou de découpe ("20 parts égales", "en portions"…) : écris-les en texte plain, jamais avec @.
  • Le résultat d'une découpe d'un ingrédient déjà listé : si la recette dit "découpez les blancs de poulet en lanières", l'ingrédient est @blanc de poulet{} ; écris "découpez en lanières" en texte plain — n'écris PAS @lanière de poulet{} séparément.
  • Les morceaux / tranches / portions issus d'un ingrédient déjà listé NE SONT PAS un nouvel ingrédient, même quand l'étape de montage les compte. Si l'étape précédente dit "coupez les @saucisses{8} en 3", et qu'une étape ultérieure dit "alternez 24 morceaux de saucisse avec les tteoks", écris cette dernière en texte plain ("alternez les morceaux de saucisse avec les @tteoks{24}") — n'écris JAMAIS @morceau de saucisse{24} ni @morceaux{24} en plus de @saucisses{8}. Règle générale : si la même chose physique apparaît deux fois dans la recette sous deux formes (entière puis découpée), elle ne doit être balisée @ qu'UNE SEULE FOIS, dans sa forme d'origine listée.
  • Quand une étape de découpe précise un nombre de morceaux par unité (« coupez chaque saucisse en 3 », « détaillez chaque pomme en 4 quartiers »), garde la quantité originale dans le @balisage (@saucisses{8}, @pommes{4}) et laisse le nombre de morceaux issus de cette découpe en texte plain. Ne crée pas un ingrédient séparé pour les morceaux ni n'additionne les quantités.
  • Les TERMES GÉNÉRIQUES qui désignent un ingrédient déjà listé sous son nom précis : « la viande », « le poisson », « la volaille », « les légumes », « le fromage », « la pâte », « la garniture ». Une recette qui a déjà déclaré @côte de veau{1.5%kg} et qui écrit plus loin « disposez 4 tranches de viande sur l'assiette » parle de CETTE côte, pas d'un second achat : écris cette étape en texte plain. Le piège est d'autant plus fréquent au DRESSAGE, où la pièce cuite revient sous un nom générique et découpée. Règle : avant de baliser un terme générique, vérifie s'il désigne quelque chose que la recette a déjà acheté — si oui, texte plain.
  • Les sous-préparations fabriquées dans la recette : si une étape prépare une vinaigrette, une sauce, une marinade, une pâte… cette préparation N'EST PAS un ingrédient externe. Dans les étapes suivantes, réfère-t'y en texte plain ("ajoutez la vinaigrette") et NON comme @vinaigrette{}, @sauce{}, @marinade{}.
  • Matériaux d'emballage et supports de cuisson : @aluminium, @papier aluminium, @film alimentaire, @papier cuisson, @papier sulfurisé sont TOUJOURS des équipements (#), JAMAIS des ingrédients (@).
  • Les ingrédients « ambiants » trop communs ne doivent JAMAIS être balisés @, même s'ils sont utilisés dans une étape : eau (sous toutes ses formes : eau, eau bouillante, eau chaude, eau froide, eau glacée, eau salée), glaçons, glace pilée, air. Écris-les en texte plain ("plongez dans une grande quantité d'eau bouillante salée", "rincez à l'eau froide"). EXCEPTION : si la recette mentionne explicitement l'eau dans sa LISTE D'INGRÉDIENTS avec une quantité précise (ex : « 250 ml d'eau » pour une pâte ou un sirop), alors et seulement alors tu peux écrire @eau{250%ml}.
- Les timers : ~{durée%unité}  Exemples : ~{20%minutes}, ~{1%heure}
- Sections de préparation (quand la recette a plusieurs parties distinctes) : == Nom de section ==
  Exemples : == La sauce ==, == Le montage ==, == La pâte ==
  Mets == Nom == sur sa propre ligne AVANT les étapes de cette partie.
  NOM DE SECTION : recopié MOT POUR MOT depuis le livre. Seule la casse peut être
  normalisée. « POUR LA SAUCE À L'ANETH ET À LA MOUTARDE » donne
  == Pour la sauce à l'aneth et à la moutarde ==, jamais == Pour la sauce à la moutarde ==.
  Raccourcir un titre de section, c'est perdre un ingrédient de son nom — et souvent
  celui qui distingue cette sauce de toutes les autres.
  N'utilise PAS de section si la recette est simple et linéaire.
  GROUPES D'INGRÉDIENTS OBLIGATOIRES : si le livre présente les ingrédients divisés en groupes nommés
  (ex : "Pour la marinade :", "Pour le poulet :", "Pour la sauce :", "Pour la pâte :"),
  tu DOIS créer une section == Nom == pour chaque groupe et placer sous cette section
  les étapes qui utilisent ces ingrédients. Respecte l'ordre des groupes du livre.
  C'est OBLIGATOIRE même si les étapes de préparation sont mélangées dans le texte original.
  Ne JAMAIS fusionner les groupes d'ingrédients en un seul bloc.
  DÉTECTION DES EN-TÊTE DE GROUPE : les livres de cuisine signalent un groupe d'ingrédients
  par un titre en MAJUSCULES ou en gras (ex : "POUR LA SAUCE", "POUR LA MARINADE",
  "Pour la pâte", "Pour la garniture :"). Ce titre = une section == Nom ==.
  EXEMPLE CONCRET (Gyoza) :
    Texte du livre :
      POUR LES GYOZAS : • 250 g de porc haché • 2½ c. à soupe de sauce soja claire
                         • 1 c. à soupe d'huile de sésame
      POUR LA SAUCE DE TREMPAGE : • 6 c. à soupe de sauce soja claire
                                   • 1 c. à café d'huile de sésame
      Mélangez le porc, la sauce soja et l'huile de sésame. Farcissez les gyozas.
      Préparez la sauce en mélangeant la sauce soja claire et l'huile de sésame.
    CookLang CORRECT :
      == Pour les gyozas ==
      Mélangez @porc haché{250%g}, @sauce soja claire{2½%c. à soupe} et @huile de sésame{1%c. à soupe}.
      Farcissez les galettes et formez les gyozas.
      == Pour la sauce de trempage ==
      Mélangez @sauce soja claire{6%c. à soupe} et @huile de sésame{1%c. à café}.
    CookLang INCORRECT #1 — section manquante :
      == Pour les gyozas ==
      Mélangez @porc haché{250%g}, @sauce soja claire{2½%c. à soupe} et @huile de sésame{1%c. à soupe}.
      Préparez la sauce : mélangez @sauce soja claire{6%c. à soupe} et @huile de sésame{1%c. à café}.
      ← FAUX : "POUR LA SAUCE DE TREMPAGE" n'a pas été converti en section == Pour la sauce de trempage ==.
        Conséquence : sauce soja claire apparaît EN DOUBLE dans "Pour les gyozas" (2½ c.s. ET 6 c.s.)
        car l'application ne peut pas distinguer les deux usages. La section == Pour la sauce de trempage == est OBLIGATOIRE.
    CookLang INCORRECT #2 — ingrédients en texte plain dans la section :
      == Pour les gyozas ==
      Mélangez @porc haché{250%g}, @sauce soja claire{2½%c. à soupe} et @huile de sésame{1%c. à soupe}.
      == Pour la sauce de trempage ==
      Mélangez la sauce soja claire et l'huile de sésame.
      ← FAUX : "sauce soja claire" et "huile de sésame" sont écrits en TEXTE PLAIN, pas en @notation.
        L'application ne peut PAS les détecter comme ingrédients de la section sauce.
        Même s'ils ont déjà été déclarés dans "Pour les gyozas", ILS DOIVENT être @-déclarés
        dans "Pour la sauce" avec leurs quantités spécifiques pour cette section :
        @sauce soja claire{6%c. à soupe} et @huile de sésame{1%c. à café}.
  INGRÉDIENT IDENTIQUE DANS PLUSIEURS SECTIONS : dans CHAQUE section, TOUT ingrédient
  listé dans le livre pour cette section DOIT être écrit en @notation{quantité%unité},
  qu'il ait été déclaré ou non dans une section précédente.
  Ne JAMAIS écrire en texte plain un ingrédient qui possède une quantité dans le livre pour cette section.
  Respecte EXACTEMENT les quantités du livre section par section.
  MATÉRIEL : ne crée JAMAIS de section == Matériel == ni == Ustensiles ==. Les ustensiles
  sont systématiquement balisés #ustensile{} directement dans la première étape où ils
  apparaissent ; si la recette d'origine présente un encart matériel séparé, intègre simplement
  ces #ustensiles{} dans les étapes correspondantes (sans recopier la liste dans le corps).
- Notes et conseils (accompagnement, variante, astuce, conservation…) : > Texte de la note
  Exemples : > Idée d'accompagnement : servir avec une salade verte., > Conseil : peut se préparer la veille.
  Mets > Note sur sa propre ligne, après l'étape concernée ou en fin de recette.
  N'utilise PAS de note si l'information est déjà dans les étapes.
- Chaque étape est une ligne de texte plain
- Continuation d'étape (même étape numérotée, retour à la ligne visuel) : commencer la ligne par "+ " (plus espace).
  Utilise "+" quand une étape longue se découpe naturellement en plusieurs sous-actions sans créer une nouvelle étape.
  Exemple :
  Pétrir la @pâte{} pendant ~{10%minutes}.
  + La pâte doit être lisse, souple et ne plus coller aux mains.
  + Former une boule et couvrir d'un torchon humide.
- Images / schémas dans le corps de la recette : si une photo, une illustration ou un schéma accompagne une étape, insère un marqueur [schéma : description courte] à l'endroit le plus logique du texte. Le pipeline remplacera ensuite ce marqueur par l'image.
- Images dans le corps de la recette : ![position](url) où position est left, right ou after.
  Ne génère JAMAIS de bloc image — les images sont insérées manuellement par l'utilisateur.
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

Retourne UNIQUEMENT le contenu demandé, sans explication, sans markdown, sans \`\`\`.
Si plusieurs recettes, sépare-les avec ---.

RÈGLE CRITIQUE — Une sous-préparation N'EST PAS une recette :
Une vinaigrette, une sauce, une marinade, une pâte, une farce, un coulis, une crème, une garniture, un accompagnement ou un dressage qui SERT le plat de cette page en fait PARTIE. Ce n'est pas une seconde recette.
- Elle reste dans le MÊME bloc CookLang que le plat, sous une section == Nom == (== La vinaigrette ==, == La sauce ==).
- Ne la sépare JAMAIS par --- : le séparateur ne sert qu'à deux plats DISTINCTS, chacun avec son propre titre et se mangeant seul.
- INTERDIT ABSOLU : rendre la sous-préparation et OUBLIER le plat principal. Si tu extrais une vinaigrette, le plat qu'elle assaisonne doit être là, dans le même bloc, et c'est LUI qui donne le titre.
- Le titre du bloc est celui du plat servi (« Ceviche de daurade »), jamais celui de sa sauce.
- Dans le doute : UNE seule recette. Deux recettes ne se justifient que si la page présente visiblement deux plats séparés.

RÈGLE CRITIQUE — Définition d'une recette :
Une RECETTE est une préparation culinaire qui comporte obligatoirement des ÉTAPES DE PRÉPARATION (verbes d'action : mélanger, cuire, éplucher, etc.).
Une simple LISTE D'ALIMENTS sans étapes de préparation n'est PAS une recette, même si elle contient des ingrédients.
Exemples de pages NON-recette à ne JAMAIS traiter comme une recette :
- « Les ingrédients indispensables dans votre placard »
- « Ma liste de courses / ma liste de base »
- « Les produits essentiels de ma cuisine »
- « Ingrédients à toujours avoir »
Ces pages doivent être traitées comme ingredient_note (voir ci-dessous).

RÈGLE TECHNIQUE — Pages de technique gestuelle avec schémas :
Si la page illustre UNE TECHNIQUE (pliage, façonnage, découpe, dressage, assemblage, boĲtage) avec des schémas ou illustrations numérotés étape par étape, c'est une page TECHNIQUE (page_type: technique), même si :
- elle contient des références à des ingrédients (feuille, farce, pâte…)
- elle a des étapes numérotées (1. 2. 3.)
- elle utilise des verbes d'action culinaire
La différence clé : une RECETTE produit un plat complet du début à la fin. Une page TECHNIQUE explique UN GESTE ou UNE MÉTHODE (ex : « comment plier des raviolis », « technique de laminage », « comment façonner une baguette », « comment dresser une assiette »).
Pour ces pages, retourne le format technique ci-dessous (PAS de CookLang) et écris le texte en Markdown (listes numérotées avec 1. 2. 3. et pour chaque schéma présent : [schéma : description courte]).

IMPORTANT — Gestion des pages non-recettes :
Si la page ne contient PAS de recette(s) mais présente un contenu culinaire utile (astuce ou technique culinaire, explication d'ingrédient, description de matériel, cours de cuisine, conseils, glossaire culinaire, liste de placard, liste de courses, liste de produits de base, etc.), retourne ce contenu sous cette forme exacte :
>> page_type: technique        (pour astuces/techniques culinaires)
             ou equipment       (pour descriptions de matériel/ustensiles)
             ou ingredient_note (pour explications sur les ingrédients, listes de placard, listes de courses, produits de base)
             ou other           (pour tout autre contenu non-recette utile)
>> titre: Titre ou sujet de la page (5 mots max)
>> page: N   (si un numéro de page est visible)
[Texte COPIÉ MOT POUR MOT depuis le document, sans reformulation, sans résumé, sans ajout.
Respecte exactement les sauts de ligne, les listes, les tirets, les numérotations et la mise en page originale.
Si une image, un schéma ou un diagramme est présent, indique-le brièvement entre crochets : [schéma : description courte].]

Si la page est vide, une page de garde, un index, une table des matières, une publicité, sans contenu utile, ou une page purement décorative / illustrée / photographique sans texte ni contenu culinaire textuel (ex : photo pleine page, double-page illustrée, image de présentation sans recette ni technique) : retourne exactement : NO_RECIPE

DERNIÈRE VÉRIFICATION, avant de répondre :
1. Compte les étapes du livre, compte les tiennes : les deux nombres sont-ils égaux ?
2. Prends l'étape la plus longue du livre : as-tu gardé TOUTES ses phrases ?
3. Chaque geste que tu as écrit figure-t-il tel quel dans le livre ?
4. Reprends la liste d'ingrédients du livre ligne à ligne : chacune est-elle balisée @ dans une étape ?
5. Aucun ingrédient n'est balisé deux fois, et aucun bloc « Ingrédients : … » ne traîne au début ni à la fin ?
6. Chaque titre de section est-il celui du livre, en entier ?
Si l'une des six réponses est non, ta sortie est fausse : recommence en transcrivant.
`;

// ── Prompt 2/2b : extraction document verbatim (si page_type ≠ recipe) ───────

export const GEMINI_DOCUMENT_EXTRACT_PROMPT = String.raw`
Tu es un expert en analyse de documents culinaires.
Retranscris le contenu de cette page MOT POUR MOT.

Règles strictes :
- Ne reformule PAS, ne résume PAS, n'ajoute rien, ne supprime rien.
- Respecte exactement les sauts de ligne, les listes, les tirets, les numérotations et la mise en page originale.
- Si une image, un schéma ou un diagramme est présent, indique-le entre crochets : [schéma : description courte].
- N'inclus PAS les numéros de page, en-têtes courants, pieds de page ou tout autre élément de mise en page éditorial (folios, titres de chapitre répétés en haut/bas de page, etc.).
- Retourne UNIQUEMENT le contenu textuel principal de la page, sans explication, sans markdown.
`;

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

// ── Préfixe multi-pages (images séparées) ────────────────────────────────────

export const GEMINI_MULTI_PAGE_PREFIX = String.raw`
IMPORTANT : Les images fournies sont des PAGES CONSÉCUTIVES d'un même document.
Traite-les comme un document continu, dans l'ordre où elles apparaissent.
Une recette peut commencer sur une page et se terminer sur la suivante : dans ce cas, reconstitue-la en une seule recette complète.
Ne retourne PAS NO_RECIPE simplement parce qu'une page seule semble incomplète.

`;

// ── Préfixe document PDF (toutes les pages dans un seul fichier) ──────────────

export const GEMINI_PDF_PREFIX = String.raw`
IMPORTANT : Le fichier fourni est un document PDF qui peut contenir PLUSIEURS PAGES et PLUSIEURS RECETTES.
Tu dois impérativement parcourir et analyser TOUTES les pages de ce document, de la première à la dernière.
- Si le PDF contient plusieurs recettes (sur des pages différentes ou sur la même page), extrais-les TOUTES.
- Une recette peut s'étendre sur plusieurs pages consécutives : dans ce cas, reconstitue-la en une seule recette complète.
- Ne t'arrête pas après la première recette trouvée — continue jusqu'à la dernière page.
- Sépare chaque recette extraite avec --- sur sa propre ligne.
- Une sous-préparation (vinaigrette, sauce, marinade, pâte, garniture) qui sert un plat n'est PAS une recette séparée : elle reste dans le bloc de son plat, sous une section == Nom ==.

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
