/**
 * Passe 2 — balisage CookLang et normalisation de la liste d'ingrédients.
 *
 * Cette passe ne voit jamais l'image : elle travaille sur ce que la passe 1 a
 * recopié. C'est ce qui rend la fidélité VÉRIFIABLE — on peut confronter sa
 * sortie à son entrée, ligne à ligne, sans appeler personne (voir `fidelity`).
 *
 * Elle rend aussi la liste normalisée, une entrée par ligne du livre, avec la
 * note explicative que le balisage inline ne pouvait pas porter : « 1 filet de
 * saumon de 1,8 kg avec la peau mais écaillée » devient un ingrédient de 1,8 kg
 * et une note « avec la peau mais écaillée », sans que la phrase du livre soit
 * touchée.
 */

import { extractJsonObject } from "./client";
import { logAiText, logError, logInfo, logWarn } from "../logging";
import { requestShapeFor } from "../ai/anthropic";
import { callModel } from "../ai/router";
import { textPart, type ModelCallContext, type ModelCallResult } from "../ai/types";
import { TAGGING_PROMPT } from "./promptsExtraction";
import {
  parseMealRoleFields,
  type MainProtein,
  type MainStarch,
  type MealComponent,
  type MealRole,
  type RecipeStyle,
} from "./mealRole";
import type { TranscribedRecipe } from "./transcription";
import { noteDitQuelqueChose, noteFromRawLine } from "../nutrition/ingredientNote";
import { isUtensil, isUtensilLine, retagUtensils } from "../nutrition/utensils";

/**
 * Plafond de sortie du balisage, réflexion comprise.
 *
 * Il valait 24 000, et il était trop court. Sur un Gravlax, Claude a dépensé
 * les 24 000 en réflexion et n'a pas écrit un caractère : `stop_reason` à
 * `max_tokens`, réponse vide, `JSON.parse("")` qui lève « Unexpected end of
 * JSON input ». La reprise automatique est passée, mais de justesse — 21 693
 * jetons, dont environ 20 000 de réflexion pour 1 700 de réponse.
 *
 * 36 000 laisse 16 000 à la réponse si la réflexion reste autour de 20 000,
 * soit neuf fois ce qu'elle a demandé. C'est un **palier d'essai**, pas une
 * certitude : la réflexion est en mode `adaptive`, et personne ne sait encore
 * si elle grandit avec le budget qu'on lui laisse. Les journaux le diront.
 *
 * Si un appel cale de nouveau à 36 000, le levier n'est pas le plafond : il
 * faut borner la réflexion elle-même (`thinking: { type: "enabled",
 * budget_tokens }`), qui garantit alors `max_tokens - budget` à la réponse.
 *
 * Ce plafond BORNE, il ne réserve pas : une réponse courte se facture courte.
 * Ce qui double avec lui, c'est le prix d'un échec — 0,47 € à 36 000 contre
 * 0,32 € à 24 000, pour rien dans les deux cas.
 *
 * La transcription reste à 24 000 : elle n'a jamais dépassé le quart de son
 * plafond.
 */
const TAGGING_MAX_TOKENS = 36_000;

type Effort = NonNullable<ModelCallContext["effort"]>;

/**
 * Effort de réflexion du balisage.
 *
 * Il valait `high`, par analogie avec la transcription : « baliser sans rien
 * perdre demande le même soin que transcrire ». L'import du livre de Jamie
 * Oliver (26 septembre 2026, 75 appels) l'a mesuré : 28 000 jetons de sortie en
 * moyenne, dont environ 4 000 de réponse. Le reste était de la réflexion,
 * facturée au tarif de sortie : 0,30 $ par appel, et 0,38 $ pour les 40 appels
 * sur 75 qui butaient sur le plafond et ne rendaient rien de lisible.
 *
 * Les deux passes ne se ressemblent pas. La transcription lit une image : le
 * soin y évite de recoller « en poudre » au mauvais ingrédient. Le balisage
 * recopie un texte déjà lu, et `checkFidelity` le compare à cette entrée sans
 * appeler personne : une erreur de balisage se voit, une erreur de lecture, non.
 * Le soin se dépense donc dans la transcription, qui reste à `high`.
 *
 * **Mesuré le 26 septembre 2026, sur les mêmes transcriptions rejouées à `low` :**
 * 33 recettes, aucune rupture de fidélité de plus, même contrôle
 * `checkFidelity` qu'à `high`. `low` sort ~10 000 jetons contre ~28 000 —
 * 0,118 $ l'appel contre 0,298 $ — pour un texte recopié tout aussi fidèlement.
 *
 * Ce qui se perd : dans les ÉTAPES, `low` remplit environ 27 % de quantités en
 * moins (21 recettes sur 27). Sans conséquence tant que la LISTE
 * d'ingrédients — vérifiée séparément, elle ne varie pas avec cet effort —
 * porte déjà le nombre : un cuisinier qui l'a lue une fois n'a besoin de rien
 * de plus dans l'étape. Le cas qui compte est celui où l'étape est la SEULE
 * source du nombre, la liste ne le portant pas : rejoué deux fois sur la même
 * recette (une pincée de sel de mer, quatre fois dans les étapes, absente de
 * la liste), `low` l'a perdu les deux fois. C'est le risque accepté de ce
 * réglage — un ingrédient d'assaisonnement sans indication de dose, dans les
 * recettes où le livre ne la donne qu'une fois, en passant.
 *
 * Avec `TAGGING_RETRY_EFFORT` déjà à `low`, `taggingEfforts()` ne tente plus
 * qu'un seul effort : il n'y a rien de plus bas où retomber si la réponse est
 * coupée au plafond. Le risque de coupure recule aussi avec l'effort — 0 appel
 * coupé sur 33 mesurés à `low`, contre 40 sur 75 à `high`.
 */
export const TAGGING_EFFORT: Effort = "low";

/**
 * Effort de la reprise quand la réponse a été coupée au plafond.
 *
 * Un balisage coupé ne dit rien de lisible : il est refait une fois, avec le
 * moins de réflexion possible, plutôt que relancé à l'identique.
 */
export const TAGGING_RETRY_EFFORT: Effort = "low";

/** Les efforts essayés dans l'ordre, sans répéter deux fois le même. */
export function taggingEfforts(): Effort[] {
  return TAGGING_EFFORT === TAGGING_RETRY_EFFORT
    ? [TAGGING_EFFORT]
    : [TAGGING_EFFORT, TAGGING_RETRY_EFFORT];
}

/**
 * Le fournisseur s'est arrêté sur le plafond de sortie.
 *
 * Claude écrit `max_tokens`, Gemini `MAX_TOKENS`. Sur un JSON, une réponse
 * arrêtée là est coupée en plein milieu : elle ne se lit pas.
 */
export function isTruncatedStop(stopReason: string | undefined): boolean {
  return stopReason === "max_tokens" || stopReason === "MAX_TOKENS";
}

/**
 * Le balisage a été coupé au plafond à tous les efforts essayés.
 *
 * Un type à part : le pipeline ne relance pas ce job à l'identique. Cloud Tasks
 * rejouerait les deux mêmes appels, et le résultat serait le même.
 */
export class TaggingTruncatedError extends Error {
  constructor() {
    super(
      "Le balisage de la recette a dépassé la longueur permise, même avec un raisonnement réduit.",
    );
    this.name = "TaggingTruncatedError";
  }
}

/**
 * Appelle le modèle à chaque effort tour à tour, jusqu'à une réponse non coupée.
 *
 * Seule une réponse arrêtée sur le plafond déclenche l'essai suivant. Une
 * réponse complète mais illisible n'est pas reprise ici : la refaire au même
 * prix ne change pas ce que le modèle sait écrire, et `tagAndNormalize` la
 * signale.
 */
export async function runTaggingAttempts<T extends { stopReason?: string }>(args: {
  efforts: readonly Effort[];
  call: (effort: Effort) => Promise<T>;
  onTruncated?: (effort: Effort, result: T) => Promise<void> | void;
  /**
   * Vrai quand le modèle qui a répondu reçoit l'effort demandé. Faux : l'essai
   * suivant partirait identique, il n'a pas lieu. Absent : toujours vrai.
   */
  effortApplies?: (result: T) => boolean;
  /** Appelé quand l'essai suivant est sauté parce que l'effort ne s'applique pas. */
  onRetrySkipped?: (effort: Effort, result: T) => Promise<void> | void;
}): Promise<T> {
  for (let i = 0; i < args.efforts.length; i++) {
    const effort = args.efforts[i];
    const result = await args.call(effort);
    if (!isTruncatedStop(result.stopReason)) return result;
    await args.onTruncated?.(effort, result);
    const hasNext = i < args.efforts.length - 1;
    if (hasNext && args.effortApplies && !args.effortApplies(result)) {
      await args.onRetrySkipped?.(effort, result);
      break;
    }
  }
  throw new TaggingTruncatedError();
}

/**
 * Le modèle qui a répondu reçoit-il l'effort ?
 *
 * Non pour Gemini, dont l'appel ne transmet pas `ctx.effort`, ni pour un
 * modèle Claude qui le refuse (Haiku 4.5, voir `requestShapeFor`). Pour eux,
 * refaire un balisage coupé à un autre effort enverrait la même requête, et
 * l'appel serait facturé une seconde fois pour le même résultat.
 */
export function effortReachesModel(result: { provider: string; model: string }): boolean {
  return result.provider === "anthropic" && requestShapeFor(result.model).effort !== null;
}

/** Une ligne d'ingrédient du livre, séparée en ce qui se compte et ce qui se dit. */
export interface NormalizedIngredientLine {
  /** La ligne du livre, inchangée — la pièce à conviction. */
  brut: string;
  /** Titre de la section d'ingrédients d'où vient la ligne, ou vide. */
  section: string;
  nom: string;
  qte: string;
  unite: string;
  /** « avec la peau mais écaillée », « dégermées » — vide s'il n'y a rien à dire. */
  note: string;
}

export interface TaggedRecipe {
  cooklang: string;
  ingredients: NormalizedIngredientLine[];
  cuisines: string[];
  dishTypes: string[];
  /** Rôle dans un repas, reconnu par la même passe ; `null` si le modèle n'a pas su. */
  mealRole: MealRole | null;
  contains: MealComponent[];
  suggestedSides: string[];
  /** Protéine et féculent principaux d'un plat ou d'un accompagnement ; `null` sinon. */
  mainProtein: MainProtein | null;
  mainStarch: MainStarch | null;
  /** Le modèle a répondu sur la protéine et le féculent (`parseMainProteinStarch`). */
  mainIngredientsChecked: boolean;
  /** Styles reconnus par la même passe (`parseRecipeStyles`). */
  styles: RecipeStyle[];
  /** Le modèle a répondu sur le style, même sans en retenir aucun. */
  stylesChecked: boolean;
  /**
   * Entrées retirées de `ingredients` parce qu'elles nomment un ustensile de
   * la liste fermée (`nutrition/utensils.ts`), et que leur ligne du livre en
   * est une aussi. Gardées pour le journal ; le contrôle de fidélité ne les
   * lit pas.
   */
  ustensilesEcartes?: NormalizedIngredientLine[];
}

/**
 * Retire de la sortie du balisage les ustensiles écrits comme ingrédients.
 *
 * Un nom de la liste fermée (« papier sulfurisé », « piques à brochette »…)
 * sort de la liste d'ingrédients, et son `@nom{…}` devient `#nom{…}` dans le
 * texte. Sans ce retrait, l'import créait une fiche `nutrition_ingredients`
 * pour le papier sulfurisé et lui cherchait des valeurs nutritionnelles.
 * S'applique à l'import d'une page, au texte collé et à l'import par lien, qui
 * passent tous par `tagAndNormalize`.
 */
export function withoutUtensils(tagged: TaggedRecipe): TaggedRecipe {
  // Le nom ET la ligne du livre doivent désigner un ustensile. Une entrée
  // « papier sulfurisé » rattachée à « 50 g de cacahuètes » reste dans la liste :
  // le contrôle de fidélité signale alors la ligne d'arachide sans entrée, au
  // lieu de la laisser disparaître.
  const estEcartee = (i: NormalizedIngredientLine): boolean =>
    isUtensil(i.nom) && (i.brut.trim().length === 0 || isUtensilLine(i.brut));
  const ecartes = tagged.ingredients.filter(estEcartee);
  return {
    ...tagged,
    cooklang: retagUtensils(tagged.cooklang),
    ingredients:
      ecartes.length > 0 ? tagged.ingredients.filter((i) => !estEcartee(i)) : tagged.ingredients,
    ...(ecartes.length > 0
      ? { ustensilesEcartes: [...(tagged.ustensilesEcartes ?? []), ...ecartes] }
      : {}),
  };
}

/**
 * Ce qu'on écrit à la place d'un titre de section absent.
 *
 * Le marqueur valait « -- section : (sans titre) », et le modèle le recopiait.
 * Le prompt lui demande de reprendre les titres de section « CARACTÈRE POUR
 * CARACTÈRE » : il a obéi. Les recettes sortaient avec une section réellement
 * nommée « (sans titre) », affichée telle quelle dans le livre et dans
 * l'éditeur d'ingrédients.
 *
 * Même faute que l'exemple rempli dans un prompt : tout ce qui ressemble à une
 * valeur finit recopié. Le marqueur ne porte donc plus de nom du tout — il
 * marque une frontière, il ne propose rien à reprendre.
 */
const SECTION_SANS_TITRE = "-- section --";

/**
 * Les libellés qu'un titre de section ne doit jamais garder.
 *
 * Le premier est celui qu'on a nous-mêmes semé pendant des semaines ; les
 * autres sont ses cousins, qu'un modèle produit spontanément quand on lui
 * demande un titre qui n'existe pas.
 */
const TITRES_DE_SECTION_VIDES = new Set([
  "(sans titre)",
  "sans titre",
  "(aucun)",
  "aucun",
  "-",
  "—",
]);

/** Un titre de section qui n'en est pas un devient vide. */
export function nettoyerTitreSection(titre: string): string {
  return TITRES_DE_SECTION_VIDES.has(titre.trim().toLowerCase()) ? "" : titre;
}

/**
 * Retire du CookLang les en-têtes de section qui ne nomment rien.
 *
 * `== (sans titre) ==` sur sa propre ligne n'apporte aucune information et
 * s'affiche pourtant comme un intertitre, dans le livre comme dans l'éditeur.
 * La ligne part entière : une section sans nom est l'absence de section.
 */
export function nettoyerSectionsCooklang(cooklang: string): string {
  return cooklang
    .split("\n")
    .filter((ligne) => {
      const nu = ligne.trim();
      if (!nu.startsWith("==") || !nu.endsWith("==")) return true;
      return nettoyerTitreSection(nu.replaceAll("=", "").trim()) !== "";
    })
    .join("\n");
}

function asString(value: unknown): string {
  return typeof value === "string" ? value.trim() : "";
}

function asStringList(value: unknown): string[] {
  if (!Array.isArray(value)) return [];
  return value.map(asString).filter((s) => s.length > 0);
}

/** Toutes les lignes d'ingrédients de la transcription, sections aplaties. */
export function ingredientLinesOf(recipe: TranscribedRecipe): string[] {
  return recipe.sectionsIngredients.flatMap((s) => s.lignes);
}

/** Le nombre d'étapes recopiées, toutes sections confondues. */
export function stepCountOf(recipe: TranscribedRecipe): number {
  return recipe.sectionsEtapes.reduce((total, s) => total + s.etapes.length, 0);
}

/** Met la transcription sous une forme que le modèle relit sans ambiguïté. */
export function renderTranscriptionForTagging(recipe: TranscribedRecipe): string {
  const out: string[] = [];
  out.push(`TITRE : ${recipe.titre}`);
  if (recipe.introduction) out.push(`INTRODUCTION : ${recipe.introduction}`);
  if (recipe.page != null) out.push(`PAGE : ${recipe.page}`);
  if (recipe.portions != null) out.push(`PORTIONS : ${recipe.portions}`);
  if (recipe.tempsPreparation) out.push(`TEMPS DE PRÉPARATION : ${recipe.tempsPreparation}`);
  if (recipe.tempsCuisson) out.push(`TEMPS DE CUISSON : ${recipe.tempsCuisson}`);
  // Le maillon le plus facile à oublier : ce n'est pas un prompt, mais il en
  // fabrique l'entrée. Sans cette ligne, la passe 2 ne voit jamais le repos que
  // la passe 1 a trouvé, et le champ reste vide sans trace.
  if (recipe.tempsRepos) out.push(`TEMPS DE REPOS : ${recipe.tempsRepos}`);
  if (recipe.difficulte) out.push(`DIFFICULTÉ : ${recipe.difficulte}`);

  out.push("");
  out.push("═══ LISTE D'INGRÉDIENTS ═══");
  // Numérotées : le modèle doit rendre autant d'entrées, dans le même ordre, et
  // un numéro rend l'écart immédiatement lisible dans les journaux.
  let n = 0;
  for (const section of recipe.sectionsIngredients) {
    out.push(section.titre ? `-- section : ${section.titre}` : SECTION_SANS_TITRE);
    for (const ligne of section.lignes) {
      n += 1;
      out.push(`${n}. ${ligne}`);
    }
  }
  // Un titre suivi de rien se lit comme une transcription incomplète. La page
  // écrite en prose n'a pas de liste, et le prompt a une règle pour ce cas : il
  // faut la lui annoncer, pas la lui laisser deviner.
  if (n === 0) out.push("(aucune : la recette est écrite en prose)");

  out.push("");
  out.push("═══ ÉTAPES ═══");
  let e = 0;
  for (const section of recipe.sectionsEtapes) {
    out.push(section.titre ? `-- section : ${section.titre}` : SECTION_SANS_TITRE);
    for (const etape of section.etapes) {
      e += 1;
      out.push(`${e}. ${etape}`);
    }
  }

  if (recipe.notes.length > 0) {
    out.push("");
    out.push("═══ NOTES ═══");
    for (const note of recipe.notes) {
      out.push(`${note.genre || "Note"} : ${note.texte}`);
    }
  }

  return out.join("\n");
}

/** Reconstruit le résultat depuis le JSON du modèle, sans rien inventer. */
export function parseTagged(json: Record<string, unknown>): TaggedRecipe {
  const ingredientsRaw = Array.isArray(json.ingredients) ? json.ingredients : [];
  return {
    // Le modèle recopie encore parfois un titre de section vide, même sans
    // marqueur à reprendre. Les deux nettoyages sont donc des garde-fous, pas
    // des corrections : la vraie correction est en amont, dans le marqueur.
    cooklang: nettoyerSectionsCooklang(
      typeof json.cooklang === "string" ? json.cooklang.trim() : "",
    ),
    ingredients: ingredientsRaw
      .filter((i): i is Record<string, unknown> => !!i && typeof i === "object")
      .map((i) => {
        const ligne = {
          brut: asString(i.brut),
          section: nettoyerTitreSection(asString(i.section)),
          nom: asString(i.nom),
          qte: asString(i.qte),
          unite: asString(i.unite),
          note: asString(i.note),
        };
        // La note ne dépend plus de la bonne volonté du modèle.
        //
        // Il la laisse vide plus souvent qu'il ne devrait, et « avec la peau
        // mais écaillée » disparaissait alors du livre. Or elle se CALCULE :
        // c'est ce que la ligne dit après avoir nommé l'aliment et sa
        // quantité. Une soustraction, pas un jugement.
        //
        // On garde la sienne quand il en propose une : il sait reformuler un
        // lien — « mélangée au miel » — là où la soustraction rendrait une
        // bribe. Mais son silence ne fait plus perdre le texte.
        // Une note qui ne porte aucun mot est rejetée AVANT le calcul.
        // Le modèle rendait « à 3 » pour le miel — la fin de « 2 à 3 cuil. à
        // café », dont le parseur n a gardé que 2. Une bribe de quantité
        // présentée comme précision du livre fait douter des vraies.
        if (!noteDitQuelqueChose(ligne.note)) ligne.note = "";
        if (!ligne.note) ligne.note = noteFromRawLine(ligne);
        return ligne;
      })
      .filter((i) => i.nom.length > 0),
    cuisines: asStringList(json.cuisines),
    dishTypes: asStringList(json.dish_types),
    // Le rôle dans un repas, lu par le même garde-fou que partout ailleurs :
    // seules les valeurs admises passent, le reste vaut « pas su ».
    ...parseMealRoleFields(json),
  };
}

/**
 * Balise une recette transcrite et normalise sa liste d'ingrédients.
 *
 * Un seul appel rend le texte balisé, la liste, et les tags — ces derniers
 * coûtaient un appel séparé pour une question à laquelle le texte répond déjà.
 *
 * `feature` nomme le poste de coût : `recipe_tagging` pour une page ou un texte
 * collé, `url_import` pour une recette lue sur une page web — même prompt, mais
 * un poste à part pour que l'import par lien se lise seul dans la comptabilité.
 */
export async function tagAndNormalize(
  recipe: TranscribedRecipe,
  ctx: ModelCallContext,
  feature = "recipe_tagging",
): Promise<TaggedRecipe> {
  const transcription = renderTranscriptionForTagging(recipe);
  // Deux blocs, pas un seul texte concaténé : Anthropic ne met en cache
  // qu'un bloc ENTIER, jamais un fragment d'une chaîne. `TAGGING_PROMPT` ne
  // varie ni avec la recette ni avec le livre — c'est le prompt le plus
  // rejoué du projet, une fois par recette balisée depuis toujours — et passe
  // donc seul, marqué `cache: true` ; la transcription, différente à chaque
  // appel, reste dans son propre bloc.
  const parts = [
    textPart(TAGGING_PROMPT, { cache: true }),
    // Les deux sauts de ligne reproduisent l'espacement de l'ancien bloc
    // unique — deux blocs concaténés par Anthropic ne portent aucun séparateur
    // implicite.
    textPart(`\n\n═══════════ TRANSCRIPTION ═══════════\n${transcription}`),
  ];

  const result = await runTaggingAttempts<ModelCallResult>({
    efforts: taggingEfforts(),
    call: (effort) =>
      callModel({
        parts,
        ctx: { ...ctx, feature, timeoutMs: 3 * 60 * 1000, effort },
        maxTokens: TAGGING_MAX_TOKENS,
      }),
    onTruncated: (effort, truncated) =>
      logWarn({
        message: `Balisage coupé au plafond de ${TAGGING_MAX_TOKENS} jetons à l'effort ${effort}`,
        moduleType: "IMPORT",
        correlationId: ctx.correlationId,
        scanId: ctx.scanId,
        jobId: ctx.jobId,
        userId: ctx.userId,
        callId: truncated.callId,
        extra: { titre: recipe.titre, effort, outputTokens: truncated.usage.outputTokens },
      }),
    effortApplies: effortReachesModel,
    onRetrySkipped: (effort, truncated) =>
      logWarn({
        message: `Balisage coupé : reprise à un autre effort sautée, le modèle ${truncated.model} ne reçoit pas l'effort`,
        moduleType: "IMPORT",
        correlationId: ctx.correlationId,
        scanId: ctx.scanId,
        jobId: ctx.jobId,
        userId: ctx.userId,
        callId: truncated.callId,
        provider: truncated.provider,
        model: truncated.model,
        feature,
        extra: { titre: recipe.titre, effort },
      }),
  });

  const text = result.text.trim();
  await logAiText({
    stage: "balisage",
    text,
    message: "Recette balisée et liste normalisée",
    feature,
    provider: result.provider,
    model: result.model,
    moduleType: "IMPORT",
    correlationId: ctx.correlationId,
    scanId: ctx.scanId,
    callId: result.callId,
    jobId: ctx.jobId,
    userId: ctx.userId,
    extra: {
      titre: recipe.titre,
      lignesRecues: ingredientLinesOf(recipe).length,
      etapesRecues: stepCountOf(recipe),
    },
  });

  try {
    const tagged = parseTagged(JSON.parse(extractJsonObject(text)) as Record<string, unknown>);
    // La ligne du livre est rattachée ICI, depuis la transcription — pas
    // demandée au modèle. Voir `attachSourceLines`. Les ustensiles sortent
    // ensuite de la liste : leur ligne d'origine les accompagne, pour que le
    // contrôle de fidélité la compte comme couverte.
    const cleaned = withoutUtensils({
      ...tagged,
      ingredients: attachSourceLines(ingredientLinesOf(recipe), tagged.ingredients),
    });
    if (cleaned.ustensilesEcartes && cleaned.ustensilesEcartes.length > 0) {
      await logInfo({
        message: `Balisage : ${cleaned.ustensilesEcartes.length} ustensile(s) retiré(s) de la liste d'ingrédients`,
        moduleType: "IMPORT",
        correlationId: ctx.correlationId,
        scanId: ctx.scanId,
        jobId: ctx.jobId,
        userId: ctx.userId,
        extra: { titre: recipe.titre, ustensiles: cleaned.ustensilesEcartes.map((i) => i.nom) },
      });
    }
    return cleaned;
  } catch (err) {
    await logError({
      message: "tagAndNormalize: réponse illisible",
      errorDescription: err instanceof Error ? err.message : String(err),
      moduleType: "IMPORT",
      correlationId: ctx.correlationId,
      jobId: ctx.jobId,
      userId: ctx.userId,
      extra: { titre: recipe.titre, longueur: text.length },
    });
    throw new Error("Le balisage de la recette n'a pas pu être lu.");
  }
}

/**
 * Rattache à chaque ingrédient la ligne du livre dont il vient, puis en déduit
 * la note.
 *
 * Le défaut de conception que ceci corrige : `brut` était demandé au MODÈLE,
 * qui devait recopier la ligne dans sa réponse. Quand il ne le faisait pas —
 * et il ne le faisait pas toujours — la ligne était perdue, la note ne pouvait
 * plus s'en déduire, et l'écran n'avait rien à montrer. Trois versions de suite
 * ont cherché la panne ailleurs.
 *
 * Or cette ligne, nous l'avons déjà : c'est la transcription. La demander au
 * modèle était l'erreur. On la rattache ici, par le rang quand les comptes
 * concordent, par le nom sinon.
 *
 * Ce que la fonction ne fait PAS : inventer un rattachement. Un ingrédient
 * qu'aucune ligne ne réclame reste sans source — et le contrôle de fidélité le
 * dira, plutôt qu'une association plausible et fausse.
 */
export function attachSourceLines(
  lignes: string[],
  ingredients: NormalizedIngredientLine[],
): NormalizedIngredientLine[] {
  if (ingredients.length === 0) return ingredients;

  // Comptes égaux : le modèle a probablement rendu une entrée par ligne, dans
  // l'ordre. « Probablement » seulement — une ligne qui nomme deux aliments et
  // une autre qu'il a fondue donnent le même total sans le même ordre. Le rang
  // est donc VÉRIFIÉ avant d'être cru : l'aliment doit se retrouver dans la
  // ligne qu'on s'apprête à lui attribuer.
  //
  // Sans cette vérification, la moutarde héritait de la ligne du sel : une
  // note plausible, attachée au mauvais ingrédient, et personne pour s'en
  // douter.
  const parRang = lignes.length === ingredients.length;

  return ingredients.map((ing, index) => {
    let brut = ing.brut;
    if (!brut) {
      const candidate = parRang ? (lignes[index] ?? "") : "";
      brut = nomFigureDans(candidate, ing.nom)
        ? candidate
        : (meilleureLigne(lignes, ing.nom) ?? "");
    }
    const note = ing.note || noteFromRawLine({ ...ing, brut });
    return { ...ing, brut, note };
  });
}

/**
 * La ligne qui nomme cet aliment, s'il n'y en a qu'une.
 *
 * Deux lignes candidates — « aneth » pour le saumon et « aneth » pour la sauce —
 * ne se départagent pas par le nom seul : on rend `null` plutôt que de choisir
 * au hasard. Une note attachée au mauvais ingrédient serait pire qu'aucune
 * note, parce qu'on la croirait.
 */
/**
 * L'aliment se retrouve-t-il dans cette ligne ?
 *
 * Comparaison sur le mot le plus long du nom : « moutarde à l'ancienne » se
 * reconnaît par « moutarde », même si la ligne l'écrit autrement autour. Un nom
 * trop court — « ail », « sel » — n'est pas discriminant, mais un faux positif
 * n'est ici pas grave : il confirme un rang qu'on tenait déjà pour probable.
 */
function nomFigureDans(ligne: string, nom: string): boolean {
  if (!ligne) return false;
  const mots = nom
    .toLowerCase()
    .split(/[^a-zà-ÿ]+/)
    .filter((m) => m.length >= 3)
    .sort((a, b) => b.length - a.length);
  if (mots.length === 0) return false;
  return ligne.toLowerCase().includes(mots[0]);
}

function meilleureLigne(lignes: string[], nom: string): string | null {
  const cible = nom.trim().toLowerCase();
  if (cible.length < 3) return null;
  const candidates = lignes.filter((l) => l.toLowerCase().includes(cible));
  return candidates.length === 1 ? candidates[0] : null;
}
