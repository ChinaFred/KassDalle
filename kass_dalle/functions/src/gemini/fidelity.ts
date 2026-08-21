/**
 * Contrôle de fidélité entre la transcription et le balisage.
 *
 * Cent cinquante lignes de prompt demandaient de ne pas réécrire la recette.
 * Aucune ligne de code ne le constatait. Une consigne que rien ne vérifie est
 * un vœu : quand le modèle raccourcissait une étape ou fusionnait deux
 * ingrédients, la recette partait en base sans que personne le sache, et l'on
 * ne s'en apercevait qu'en rouvrant le livre.
 *
 * Ces vérifications ne coûtent aucun appel. Elles comparent ce que la passe 2 a
 * rendu à ce que la passe 1 lui avait donné — deux textes que nous possédons.
 *
 * Ce qu'elles NE font pas : juger la qualité du balisage. Un ingrédient mal
 * catégorisé passe. Ce qu'elles attrapent, c'est la DISPARITION et la FUSION,
 * les deux défauts qui rendent une recette fausse sans qu'elle en ait l'air.
 */

import type { TranscribedRecipe } from "./transcription";
import type { TaggedRecipe } from "./tagging";
import { ingredientLinesOf, stepCountOf } from "./tagging";

export type FidelityLevel = "ok" | "avertissement" | "rupture";

export interface FidelityFinding {
  /** Identifiant court, pour compter les occurrences dans les journaux. */
  code: string;
  /** Ce qui ne va pas, en français, sans jargon. */
  message: string;
  /**
   * Les éléments concernés, un par entrée.
   *
   * Séparés du message parce qu'ils s'affichent en LISTE. Concaténés dans la
   * phrase avec des barres obliques, sept mots mal lus formaient un pavé qu'on
   * ne relisait pas — et une alerte qu'on ne relit pas ne sert à rien.
   */
  items?: string[];
  level: FidelityLevel;
}

export interface FidelityReport {
  level: FidelityLevel;
  findings: FidelityFinding[];
  /** Vrai quand le texte balisé ne peut pas être retenu tel quel. */
  rejette: boolean;
}

/**
 * Lignes d'étapes d'un texte CookLang : ni métadonnées, ni sections, ni notes,
 * ni lignes vides. Une continuation (« + ») appartient à l'étape précédente et
 * ne compte donc pas pour une étape de plus.
 */
export function cooklangStepLines(cooklang: string): string[] {
  return cooklang
    .split(/\r?\n/)
    .map((l) => l.trim())
    .filter(
      (l) =>
        l.length > 0 &&
        !l.startsWith(">>") &&
        !l.startsWith(">") &&
        !l.startsWith("==") &&
        !l.startsWith("+"),
    );
}

/** Lignes de note d'un texte CookLang : « > Astuce : … ». */
export function cooklangNoteLines(cooklang: string): string[] {
  return cooklang
    .split(/\r?\n/)
    .map((l) => l.trim())
    .filter((l) => l.startsWith(">") && !l.startsWith(">>"));
}

/** Titres de section d'un texte CookLang, dans l'ordre. */
export function cooklangSectionTitles(cooklang: string): string[] {
  const out: string[] = [];
  for (const raw of cooklang.split(/\r?\n/)) {
    const line = raw.trim();
    const match = /^==\s*(.+?)\s*==$/.exec(line);
    if (match) out.push(match[1].trim());
  }
  return out;
}

/**
 * Forme comparable d'un titre : casse, accents et ponctuation de bord ignorés.
 *
 * Le prompt demande le titre « caractère pour caractère », mais exiger l'égalité
 * stricte ferait échouer sur « POUR LA SAUCE » rendu « Pour la sauce » — une
 * normalisation de casse explicitement autorisée. Ce qu'on traque est la perte
 * de MOTS : « Pour la sauce à l'aneth et à la moutarde » devenu « Pour la
 * sauce ».
 */
function comparableTitle(title: string): string {
  return title
    .normalize("NFD")
    .replace(/[\u0300-\u036f]/g, "")
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, " ")
    .trim();
}

/** Tolérance sur le nombre d'étapes, en proportion de l'original. */
const TOLERANCE_ETAPES = 0.2;

/**
 * Retire la SYNTAXE CookLang en gardant tout le texte, accolades comprises.
 *
 * `@aneth frais{4%c. à soupe}` redevient « aneth frais 4 c. à soupe ».
 *
 * Jeter le contenu des accolades serait l'erreur : les quantités quittent
 * légitimement la phrase pour y entrer. « mélangée à deux cuillères à café de
 * miel » balisé en « mélangée à @miel{2%c. à café} » perdrait alors « deux »,
 * « cuillères » et « café » d'un coup — et un balisage parfaitement fidèle se
 * verrait accusé d'avoir perdu un tiers de la page.
 */
export function stripCooklangTags(cooklang: string): string {
  return cooklang
    .replace(/~\{([^}]*)\}/g, " $1 ")
    .replace(/[@#]([^@#~{}]+)\{([^}]*)\}/g, " $1 $2 ")
    .replace(/^\s*>>.*$/gm, " ")
    .replace(/%/g, " ");
}

/**
 * Mots porteurs de sens d'un texte : au moins quatre lettres, sans accent,
 * en minuscules.
 *
 * On écarte les mots courts (articles, prépositions) et tout ce qui contient un
 * chiffre : une quantité écrite « deux » dans la phrase peut légitimement
 * devenir « 2 » dans une accolade, et l'inverse. Ce qu'on traque ici est la
 * disparition d'un CONTENU — « miel », « aneth », « frais » — pas une
 * réécriture de forme.
 */
export function significantWords(text: string): Set<string> {
  const normalized = text
    .normalize("NFD")
    .replace(/[\u0300-\u036f]/g, "")
    .toLowerCase();
  const out = new Set<string>();
  for (const word of normalized.split(/[^a-z]+/)) {
    if (word.length >= 4 && !MOTS_DE_MESURE.has(word)) out.add(word);
  }
  return out;
}

/**
 * Mots que le balisage transforme L\u00c9GITIMEMENT, et qu'on ne compte donc pas.
 *
 * \u00ab deux cuill\u00e8res \u00e0 caf\u00e9 \u00bb devient \u00ab 2 c. \u00e0 caf\u00e9 \u00bb : trois mots sur quatre
 * changent de forme sans que rien ne soit perdu. Les compter revenait \u00e0
 * accuser un balisage correct \u2014 et une accusation \u00e0 tort finit par se faire
 * ignorer, ce qui co\u00fbte plus cher que de ne rien v\u00e9rifier.
 *
 * La liste est courte et ferm\u00e9e \u00e0 dessein : les nombres \u00e9crits en lettres et
 * les mesures qui poss\u00e8dent une abr\u00e9viation d'usage. Tout le reste \u2014 les
 * aliments, les gestes, les contenants \u2014 doit se retrouver.
 */
const MOTS_DE_MESURE = new Set([
  "deux",
  "trois",
  "quatre",
  "cinq",
  "sept",
  "huit",
  "neuf",
  "onze",
  "douze",
  "demi",
  "demie",
  "quart",
  "cuiller",
  "cuillere",
  "cuilleres",
  "cuilleree",
  "cuillerees",
  "grammes",
  "gramme",
  "kilos",
  "kilo",
  "litres",
  "litre",
  "minutes",
  "minute",
  "heures",
  "heure",
  "secondes",
]);

/** Part des mots de `source` que l'on retrouve dans `cible`. */
export function wordCoverage(source: string, cible: string): number {
  const attendus = significantWords(source);
  if (attendus.size === 0) return 1;
  const presents = significantWords(cible);
  let trouves = 0;
  for (const word of attendus) if (presents.has(word)) trouves += 1;
  return trouves / attendus.size;
}

/** Tout le texte transcrit d'une recette : étapes et notes, sans les titres. */
function transcribedProse(recipe: TranscribedRecipe): string {
  return [
    recipe.introduction,
    ...recipe.sectionsEtapes.flatMap((s) => s.etapes),
    ...recipe.notes.map((n) => n.texte),
  ]
    .filter((t) => t.length > 0)
    .join(" ");
}

/**
 * Seuils de couverture — mesurés, pas devinés.
 *
 * Un balisage FIDÈLE perd tout de même quelques mots : « cuillères » devient
 * « c. », un mot de liaison saute. Sur les cas réels, cette perte légitime
 * tourne autour de quinze pour cent. Une étape amputée de sa moitié — « la
 * moutarde mélangée à deux cuillères à café de miel » réduite à « la
 * moutarde » — en perd plus de soixante-dix.
 *
 * L'écart entre les deux est large : on se place au milieu, en laissant
 * délibérément passer les pertes modestes. Ce contrôle traque la DISPARITION
 * d'un morceau de recette, pas la virgule manquante — accuser sur un doute
 * priverait l'utilisateur d'un balisage correct.
 */
const COUVERTURE_RUPTURE = 0.55;
const COUVERTURE_ALERTE = 0.7;

/**
 * Confronte la transcription à ce que le modèle avait déclaré voir.
 *
 * Tous les autres contrôles comparent la passe 2 à la passe 1. Aucun ne peut
 * voir ce que la passe 1 elle-même a perdu : une page dont la première section
 * n'aurait jamais été recopiée produit une chaîne cohérente de bout en bout, et
 * personne ne s'en aperçoit avant de rouvrir le livre.
 *
 * L'inventaire ferme ce trou sans coûter un appel. Le modèle annonce ce qu'il
 * voit avant de le recopier, et l'on compare l'annonce au résultat. Le verdict
 * reste un AVERTISSEMENT : cette déclaration est elle-même produite par le
 * modèle, et se fier à elle pour jeter un travail reviendrait à lui demander de
 * s'auto-condamner. Elle sert à alerter, pas à trancher.
 */
export function checkTranscriptionInventory(recipe: TranscribedRecipe): FidelityFinding[] {
  const findings: FidelityFinding[] = [];

  // ── Les mots que le modèle dit avoir eu du mal à lire ────────────────────
  //
  // La seule prise que nous ayons sur l'erreur de LECTURE. Tous les autres
  // contrôles comparent la passe 2 à la passe 1 : quand la passe 1 a mal lu,
  // elle EST la référence, et rien en aval ne peut s'en apercevoir. « peau en
  // dessous » lu « peu profonde en dessous » rend une phrase impeccable qui ne
  // dit plus la même chose, et aucun décompte ne s'en émeut.
  //
  // Ce n'est pas une garantie — un modèle sûr de lui ne signale rien — mais un
  // doute affiché se vérifie en dix secondes, là où le même doute tu se
  // découvre en ratant le plat.
  if (recipe.lecturesIncertaines.length > 0) {
    findings.push({
      code: "lecture_incertaine",
      message: "Mot(s) que le modèle dit avoir mal lu(s), à vérifier sur le livre :",
      items: recipe.lecturesIncertaines,
      level: "avertissement",
    });
  }

  const inventaire = recipe.inventaire;
  if (!inventaire) return findings;

  const titresRendus = [
    ...recipe.sectionsIngredients.map((s) => s.titre),
    ...recipe.sectionsEtapes.map((s) => s.titre),
  ]
    .filter((t) => t.length > 0)
    .map(comparableTitle);
  // Les titres viennent de l'inventaire déclaré : on les affiche tels que le
  // modèle les a lus sur la page, accents compris. La forme comparable ne sert
  // qu'au rapprochement.
  const manquantes = inventaire.sections
    .filter((t) => t.trim().length > 0)
    .filter((t) => !titresRendus.includes(comparableTitle(t)));
  if (manquantes.length > 0) {
    findings.push({
      code: "section_non_transcrite",
      message: "Section(s) vue(s) sur la page mais absente(s) de la transcription :",
      items: manquantes,
      level: "avertissement",
    });
  }

  const lignes = ingredientLinesOf(recipe).length;
  if (inventaire.lignesIngredients != null && lignes < inventaire.lignesIngredients) {
    findings.push({
      code: "lignes_non_transcrites",
      message: `${lignes} ligne(s) d'ingrédients transcrite(s) pour ${inventaire.lignesIngredients} annoncée(s) sur la page.`,
      level: "avertissement",
    });
  }

  const etapes = stepCountOf(recipe);
  if (inventaire.etapes != null && etapes < inventaire.etapes) {
    findings.push({
      code: "etapes_non_transcrites",
      message: `${etapes} étape(s) transcrite(s) pour ${inventaire.etapes} annoncée(s) sur la page.`,
      level: "avertissement",
    });
  }

  return findings;
}

/**
 * Confronte le balisage à la transcription.
 *
 * Deux niveaux, et la distinction compte : un « avertissement » se journalise
 * et laisse passer, une « rupture » fait retomber la recette sur le texte
 * verbatim de la transcription. On ne jette une sortie que lorsqu'elle est
 * démontrablement amputée — refuser sur un doute reviendrait à priver
 * l'utilisateur d'un balisage correct pour une virgule.
 */
export function checkFidelity(
  transcribed: TranscribedRecipe,
  tagged: TaggedRecipe,
): FidelityReport {
  const findings: FidelityFinding[] = [...checkTranscriptionInventory(transcribed)];

  // ── Chaque ligne du livre doit avoir AU MOINS une entrée ────────────────
  //
  // La règle était « une ligne, une entrée », et elle était fausse : une ligne
  // peut en nommer deux. « 2 cuil. à café de moutarde à l'ancienne mélangée à
  // 2 cuil. à café de miel » est un achat de moutarde ET un achat de miel. La
  // règle du compte exact obligeait à en choisir un — le miel disparaissait de
  // la liste de courses et du calcul, sans un mot.
  //
  // On vérifie donc une COUVERTURE, pas une égalité : aucune ligne ne peut
  // rester orpheline. Deux entrées pour une ligne sont légitimes ; zéro ne
  // l'est jamais.
  const lignes = ingredientLinesOf(transcribed);
  if (lignes.length > 0) {
    // On COMPTE les occurrences, on ne se contente pas de la présence.
    //
    // « 1 bouquet d'aneth » peut figurer dans deux sections : c'est deux achats,
    // pas un. Vérifier que la ligne « existe quelque part » laisserait passer
    // la fusion des deux — celle-là même que ce contrôle existe pour attraper.
    const compter = (textes: string[]): Map<string, number> => {
      const out = new Map<string, number>();
      for (const t of textes) {
        const clef = comparableTitle(t);
        if (!clef) continue;
        out.set(clef, (out.get(clef) ?? 0) + 1);
      }
      return out;
    };

    const attendues = compter(lignes);
    const rendues = compter(tagged.ingredients.map((i) => i.brut));

    // Où se trouve chaque ligne, et comment le livre l'écrit : le message doit
    // permettre de poser le doigt sur la page.
    const situation = new Map<string, string>();
    let rang = 0;
    for (const section of transcribed.sectionsIngredients) {
      for (const ligne of section.lignes) {
        rang += 1;
        const clef = comparableTitle(ligne);
        if (!clef || situation.has(clef)) continue;
        situation.set(
          clef,
          section.titre
            ? `« ${ligne} » (ingrédient ${rang}, ${section.titre})`
            : `« ${ligne} » (ingrédient ${rang})`,
        );
      }
    }

    // Aucun `brut` exploitable : on retombe sur le décompte brut. Mieux vaut un
    // contrôle grossier qu'aucun.
    if (rendues.size === 0) {
      if (tagged.ingredients.length < lignes.length) {
        findings.push({
          code: "ingredients_compte",
          message: `${tagged.ingredients.length} ingrédient(s) normalisé(s) pour ${lignes.length} ligne(s) dans le livre.`,
          level: "rupture",
        });
      }
    } else {
      const manquantes: string[] = [];
      for (const [clef, attendu] of attendues) {
        const rendu = rendues.get(clef) ?? 0;
        if (rendu < attendu) {
          manquantes.push(`${situation.get(clef) ?? clef} — ${rendu} sur ${attendu} attendue(s)`);
        }
      }
      if (manquantes.length > 0) {
        findings.push({
          code: "ingredients_compte",
          message: "Ligne(s) du livre sans ingrédient correspondant :",
          items: manquantes,
          level: "rupture",
        });
      }
    }
  }

  // ── Les étapes : autant en sortie qu'en entrée ───────────────────────────
  const etapesAttendues = stepCountOf(transcribed);
  const etapesRendues = cooklangStepLines(tagged.cooklang).length;
  if (etapesAttendues > 0) {
    const ecart = Math.abs(etapesRendues - etapesAttendues) / etapesAttendues;
    if (ecart > TOLERANCE_ETAPES) {
      findings.push({
        code: "etapes_compte",
        message: `${etapesRendues} étape(s) balisée(s) pour ${etapesAttendues} transcrite(s).`,
        // Où chercher : le découpage en sections de la transcription, pour
        // comparer section par section plutôt que de relire toute la page.
        items: transcribed.sectionsEtapes.map(
          (sec) => `${sec.titre || "sans titre"} : ${sec.etapes.length} étape(s) sur la page`,
        ),
        // Un résumé enlève des étapes ; c'est le défaut grave. En ajouter est
        // le plus souvent un découpage de phrase, gênant mais pas faux.
        level: etapesRendues < etapesAttendues ? "rupture" : "avertissement",
      });
    }
  }

  // ── Les titres de section : aucun mot perdu ──────────────────────────────
  // La forme comparable sert à COMPARER, jamais à afficher.
  //
  // Elle est mise à plat — sans accents, sans apostrophes — pour que « POUR LA
  // SAUCE » et « Pour la sauce » se reconnaissent. L'afficher rendait « sauce a
  // l aneth et a la moutarde », qu'on lit comme une faute de frappe et non
  // comme le titre du livre.
  const titreOriginal = new Map<string, string>();
  for (const section of [...transcribed.sectionsIngredients, ...transcribed.sectionsEtapes]) {
    if (section.titre.length > 0 && !titreOriginal.has(comparableTitle(section.titre))) {
      titreOriginal.set(comparableTitle(section.titre), section.titre);
    }
  }
  const titresRendus = cooklangSectionTitles(tagged.cooklang).map(comparableTitle);
  const manquants = [...titreOriginal.entries()]
    .filter(([clef]) => !titresRendus.includes(clef))
    .map(([, original]) => original);
  if (manquants.length > 0) {
    findings.push({
      code: "sections_titres",
      message: "Titre(s) de section absent(s) ou raccourci(s) :",
      items: manquants,
      // Raccourcir « Pour la sauce à l'aneth et à la moutarde » en « Pour la
      // sauce » ne casse aucun écran — mais deux sauces d'une même recette
      // deviennent indiscernables, et leurs ingrédients se confondent.
      level: "avertissement",
    });
  }

  // ── Le TEXTE lui-même, pas seulement le nombre de lignes ────────────────
  //
  // Compter les étapes ne dit rien de leur contenu : une phrase amputée de sa
  // moitié reste une phrase. « la moutarde mélangée à deux cuillères à café de
  // miel » devenue « la moutarde » ne change pas le décompte, et fait
  // disparaître un ingrédient de la recette comme des courses.
  //
  // On compare donc les mots porteurs de sens de la transcription à ceux du
  // texte balisé, balises retirées. Ce qui manque ici a été perdu entre les
  // deux passes.
  const prose = transcribedProse(transcribed);
  if (prose.trim().length > 0) {
    const couverture = wordCoverage(prose, stripCooklangTags(tagged.cooklang));
    if (couverture < COUVERTURE_ALERTE) {
      const perdus = Math.round((1 - couverture) * 100);
      findings.push({
        code: "texte_perdu",
        message: `${perdus} % des mots de la page ne se retrouvent pas dans le texte balisé.`,
        level: couverture < COUVERTURE_RUPTURE ? "rupture" : "avertissement",
      });
    }
  }

  // ── Les notes : une astuce perdue ne se voit nulle part ──────────────────
  //
  // Elles n'ont pas de décompte ailleurs : ni les étapes, ni les ingrédients ne
  // les portent. Une « Astuce » ou un « Conseil du chef » que le balisage
  // oublie disparaît sans laisser de trace — et c'est souvent la seule phrase
  // du livre qui dit comment réussir le plat.
  if (transcribed.notes.length > 0) {
    const rendues = cooklangNoteLines(tagged.cooklang).length;
    if (rendues < transcribed.notes.length) {
      findings.push({
        code: "notes_perdues",
        message: `${rendues} note(s) dans le texte balisé pour ${transcribed.notes.length} lue(s) sur la page :`,
        // Le genre et le début du texte suffisent à retrouver laquelle manque.
        items: transcribed.notes.map(
          (n) =>
            `${n.genre || "Note"} — « ${n.texte.slice(0, 60)}${n.texte.length > 60 ? "…" : ""} »`,
        ),
        level: "avertissement",
      });
    }
  }

  // ── Un nom d'ingrédient que sa propre ligne ne justifie pas ──────────────
  //
  // « 4 cuil. à soupe d'aneth frais » ne peut pas donner « aneth en poudre ».
  // Ce n'est pas une reformulation, c'est un autre produit : il ne s'achète pas
  // au même rayon et ne pèse pas la même chose. La ligne du livre est conservée
  // dans `brut` précisément pour rendre ce contrôle possible — chaque mot du
  // nom doit s'y trouver.
  //
  // Le contrôle est volontairement borné aux lignes NON vides : une entrée sans
  // `brut` vient d'un chemin qui n'a pas transcrit de liste, et se comparer au
  // néant condamnerait tout le monde.
  const inventes: string[] = [];
  for (const ing of tagged.ingredients) {
    if (!ing.brut.trim() || !ing.nom.trim()) continue;
    if (wordCoverage(ing.nom, ing.brut) < 1) {
      inventes.push(`« ${ing.nom} » absent de « ${ing.brut} »`);
    }
  }
  if (inventes.length > 0) {
    findings.push({
      code: "ingredient_invente",
      message: "Nom(s) d'ingrédient que la page ne dit pas :",
      items: inventes,
      // Avertissement et non rupture : le repli remplace le TEXTE, pas la
      // liste — il ne corrigerait donc rien ici. Ce qui aide, c'est de nommer
      // précisément la ligne fautive pour qu'elle se corrige d'un geste.
      level: "avertissement",
    });
  }

  // ── Ce que la ligne disait en plus, et qui n'est allé nulle part ────────
  //
  // « 1 filet de saumon de 1,8 kg avec la peau mais écaillée » se sépare en une
  // quantité et une précision. Quand la seconde reste vide, les mots « peau »,
  // « écaillée » ne sont plus dans le nom, plus dans la note, plus nulle part —
  // et rien ne le signalait : la ligne compte pour une, le nom est correct, la
  // quantité aussi. Le seul témoin est la ligne du livre elle-même, conservée
  // en `brut` à cette fin.
  //
  // On ne compte que les mots porteurs de sens : « de », « à », « la » ne
  // manquent à personne. Et il en faut DEUX pour alerter — un mot isolé est
  // presque toujours un article ou une variante d'orthographe.
  const precisionsPerdues: string[] = [];
  for (const [index, ing] of tagged.ingredients.entries()) {
    if (!ing.brut.trim()) continue;
    const dits = significantWords(`${ing.nom} ${ing.unite} ${ing.note}`);
    const restants = [...significantWords(ing.brut)].filter((mot) => !dits.has(mot));
    if (restants.length >= 2) {
      const ou = ing.section
        ? `ingrédient ${index + 1}, ${ing.section}`
        : `ingrédient ${index + 1}`;
      precisionsPerdues.push(`${ing.nom} (${ou}) : ${restants.join(", ")}`);
    }
  }
  if (precisionsPerdues.length > 0) {
    findings.push({
      code: "precision_perdue",
      message: "Précision(s) de la page qui ne sont ni dans le nom ni dans la note :",
      items: precisionsPerdues,
      level: "avertissement",
    });
  }

  // ── Un texte balisé vide n'est pas un texte ──────────────────────────────
  if (tagged.cooklang.trim().length === 0) {
    findings.push({
      code: "cooklang_vide",
      message: "Le balisage n'a rendu aucun texte.",
      level: "rupture",
    });
  }

  const level: FidelityLevel = findings.some((f) => f.level === "rupture")
    ? "rupture"
    : findings.some((f) => f.level === "avertissement")
      ? "avertissement"
      : "ok";

  return { level, findings, rejette: level === "rupture" };
}

/**
 * Texte CookLang de repli, bâti depuis la seule transcription.
 *
 * Sans balise : mieux vaut une recette exacte et non balisée qu'une recette
 * balisée et fausse. Les ingrédients restent exploitables — ils viennent de la
 * transcription, pas du balisage rejeté — et l'utilisateur peut relancer un
 * raffinage depuis l'éditeur.
 */
export function verbatimCooklang(recipe: TranscribedRecipe): string {
  const out: string[] = [];
  out.push(`>> titre: ${recipe.titre}`);
  if (recipe.page != null) out.push(`>> page: ${recipe.page}`);
  if (recipe.portions != null) out.push(`>> portions: ${recipe.portions}`);
  if (recipe.difficulte) out.push(`>> difficulté: ${recipe.difficulte}`);
  if (recipe.tempsPreparation) out.push(`>> temps_préparation: ${recipe.tempsPreparation}`);
  if (recipe.tempsCuisson) out.push(`>> temps_cuisson: ${recipe.tempsCuisson}`);
  out.push("");

  // Le chapeau se lit en premier, parce que le livre le met en premier.
  if (recipe.introduction) {
    out.push(`> ${recipe.introduction}`);
    out.push("");
  }

  for (const section of recipe.sectionsEtapes) {
    if (section.titre) out.push(`== ${section.titre} ==`);
    for (const etape of section.etapes) out.push(etape);
    out.push("");
  }

  for (const note of recipe.notes) {
    out.push(`> ${note.genre ? `${note.genre} : ` : ""}${note.texte}`);
  }

  return out.join("\n").trim();
}
