/**
 * Passe 1 — transcription d'une page de livre.
 *
 * Un seul appel de modèle rend le TYPE de la page et son contenu recopié. Trois
 * appels vivaient ici : classifier, extraire une recette, extraire un document.
 * Le premier posait une question à laquelle les deux autres répondaient déjà.
 *
 * Ce que cette passe rend n'est PAS du CookLang : c'est la page, en JSON, telle
 * qu'elle est écrite. Aucune balise, aucune décision de placement. Le modèle
 * recopie deux listes et des phrases — le travail qu'il fait bien.
 */

import { extractJsonObject } from "./client";
import { logAiText, logError } from "../logging";
import { callModel } from "../ai/router";
import { attachmentPart } from "../ai/attachment";
import { filePart, textPart, type ModelCallContext, type ModelCallResult } from "../ai/types";
import {
  bookWindowPreamble,
  TEXT_TRANSCRIPTION_PREAMBLE,
  TRANSCRIPTION_PROMPT,
  type BookWindowInfo,
} from "./promptsExtraction";
/** Une page de livre peut être longue, et la transcription ne résume rien. */
const TRANSCRIPTION_MAX_TOKENS = 24_000;

/**
 * Une page supplémentaire d'un même scan, jointe à l'appel principal.
 *
 * Déclarée ici depuis que l'ancienne extraction a disparu : ces deux types ne
 * servent plus qu'à la transcription, et les laisser dans `extractor.ts`
 * obligeait à garder ouvert un fichier qui ne les emploie pas.
 */
export interface ExtraPage {
  bytes: Buffer;
  mimeType: string;
}

/** Nature de la page, telle que la transcription la tranche. */
export type PageType =
  "recipe" | "ingredient_note" | "technique" | "equipment" | "other" | "no_recipe";

/** Un groupe d'ingrédients du livre : « Pour la marinade » et ses lignes. */
export interface TranscribedIngredientSection {
  titre: string;
  lignes: string[];
}

/** Un groupe d'étapes du livre. */
export interface TranscribedStepSection {
  titre: string;
  etapes: string[];
}

/** Une astuce, un conseil du chef, une variante — pas une étape. */
export interface TranscribedNote {
  genre: string;
  texte: string;
}

/**
 * Ce que le modèle déclare AVOIR VU, avant de recopier.
 *
 * Le contrôle de fidélité compare la passe 2 à la passe 1 : il est aveugle à
 * ce que la passe 1 elle-même a perdu. Une page dont la première section
 * n'aurait jamais été transcrite produit une chaîne parfaitement cohérente de
 * bout en bout, et personne ne s'en aperçoit avant de rouvrir le livre.
 *
 * Cet inventaire ferme le trou sans coûter un appel : le modèle annonce ce
 * qu'il voit avant de le recopier, et le code compare l'annonce au résultat.
 * Un modèle qui déclare trois sections et en rend deux est pris en défaut par
 * sa propre déclaration.
 */
export interface TranscriptionInventory {
  sections: string[];
  lignesIngredients: number | null;
  etapes: number | null;
}

/**
 * Ce que la traduction a remplacé : la langue de la page et la recette telle
 * qu'elle y était écrite. Présent seulement sur une recette traduite.
 */
export interface RecipeTranslationOrigin {
  /** Code ISO 639-1 de la langue d'origine. */
  langue: string;
  recette: TranscribedRecipe;
}

/** Une recette telle qu'elle est écrite dans le livre. */
export interface TranscribedRecipe {
  /** Absent des transcriptions antérieures à ce contrôle. */
  inventaire?: TranscriptionInventory;

  /**
   * Code ISO 639-1 de la langue des étapes, lu par la transcription.
   *
   * Absent des transcriptions antérieures à la traduction : elles valent "fr".
   * Une recette traduite porte "fr" et garde son origine dans `traduction`.
   */
  langue?: string;

  /** La recette d'origine, quand celle-ci est une traduction. */
  traduction?: RecipeTranslationOrigin;

  /**
   * Le paragraphe d'ouverture de la recette, quand le livre en porte un.
   *
   * « Une méthode scandinave pour fumer le saumon dans le sel… » : il dit d'où
   * vient le plat et pourquoi il vaut la peine. C'est du contenu, et il se
   * perdait — la consigne de ne pas recopier les en-têtes de page l'emportait
   * sur lui, alors qu'un titre courant se répète de page en page tandis que ce
   * paragraphe n'appartient qu'à cette recette.
   */
  introduction: string;

  /**
   * Mots que le modèle dit avoir eu du mal à lire.
   *
   * La seule prise que nous ayons sur l'erreur de LECTURE. Tous les contrôles
   * de fidélité comparent la passe 2 à la passe 1 : quand la passe 1 a mal lu,
   * elle est la référence corrompue, et rien en aval ne peut le voir. « peau en
   * dessous » lu « peu profonde en dessous » rend une phrase impeccable qui ne
   * dit plus la même chose — aucun décompte, aucune couverture de mots ne
   * s'en émeut.
   *
   * Ce n'est pas une garantie : un modèle sûr de lui ne signalera rien. C'est
   * un doute rendu visible, et un doute signalé se vérifie en dix secondes.
   */
  lecturesIncertaines: string[];
  titre: string;
  page: number | null;
  portions: number | null;
  tempsPreparation: string | null;
  tempsCuisson: string | null;
  /** Marinade, réfrigération, levée — presque toujours enfoui dans une étape. */
  tempsRepos: string | null;
  difficulte: string | null;
  sectionsIngredients: TranscribedIngredientSection[];
  sectionsEtapes: TranscribedStepSection[];
  notes: TranscribedNote[];
}

export interface PageTranscription {
  pageType: PageType;
  titre: string;
  page: number | null;
  /** Raison invoquée par le modèle pour son verdict de type. */
  raison: string;
  /** Texte recopié d'une page NON-recette. Vide pour une recette. */
  document: string;
  recettes: TranscribedRecipe[];
}

function asString(value: unknown): string {
  return typeof value === "string" ? value.trim() : "";
}

function asNumberOrNull(value: unknown): number | null {
  if (typeof value === "number" && Number.isFinite(value)) return value;
  if (typeof value === "string" && value.trim()) {
    const parsed = Number(value.replace(",", "."));
    return Number.isFinite(parsed) ? parsed : null;
  }
  return null;
}

function asStringOrNull(value: unknown): string | null {
  const out = asString(value);
  return out.length > 0 ? out : null;
}

/**
 * Code de langue lu par la transcription, ramené à deux lettres minuscules.
 *
 * Toute valeur illisible vaut "fr" : traduire à tort réécrirait une recette
 * française, alors qu'une recette étrangère laissée telle quelle se corrige à
 * la main.
 */
export function normalizeLanguageCode(value: unknown): string {
  const code = asString(value).toLowerCase().split(/[-_]/)[0];
  return /^[a-z]{2}$/.test(code) ? code : "fr";
}

/** Vrai quand la recette est écrite dans une autre langue que le français. */
export function needsTranslation(recette: TranscribedRecipe): boolean {
  return normalizeLanguageCode(recette.langue) !== "fr";
}

/** L'inventaire déclaré, ou `undefined` si le modèle n'en a pas rendu. */
function parseInventory(value: unknown): TranscriptionInventory | undefined {
  if (!value || typeof value !== "object") return undefined;
  const raw = value as Record<string, unknown>;
  const sections = asStringList(raw.sections);
  const lignes = asNumberOrNull(raw.nombre_lignes_ingredients);
  const etapes = asNumberOrNull(raw.nombre_etapes);
  if (sections.length === 0 && lignes == null && etapes == null) return undefined;
  return { sections, lignesIngredients: lignes, etapes };
}

function asStringList(value: unknown): string[] {
  if (!Array.isArray(value)) return [];
  return value.map(asString).filter((s) => s.length > 0);
}

const KNOWN_PAGE_TYPES: readonly PageType[] = [
  "recipe",
  "ingredient_note",
  "technique",
  "equipment",
  "other",
  "no_recipe",
];

/**
 * Type de page, avec le garde-fou de cohérence hérité de la classification.
 *
 * Un modèle qui écrit « aucune étape de préparation » dans sa justification et
 * « recipe » dans son verdict se contredit. On suit la justification : elle est
 * écrite avant, et c'est elle qui décrit ce qui a été lu.
 */
export function resolvePageType(rawType: unknown, raison: string): PageType {
  const candidate = asString(rawType).toLowerCase() as PageType;
  const pageType = KNOWN_PAGE_TYPES.includes(candidate) ? candidate : "other";
  if (pageType !== "recipe") return pageType;

  const r = raison.toLowerCase();
  const contredit =
    r.includes("n'est pas une recette") ||
    r.includes("pas une recette") ||
    r.includes("ne contient pas de recette") ||
    r.includes("ne présente pas de recette") ||
    (r.includes("aucune étape") && r.includes("aucun ingrédient"));
  return contredit ? "ingredient_note" : "recipe";
}

/** Reconstruit une transcription depuis le JSON du modèle, sans rien inventer. */
export function parseTranscription(json: Record<string, unknown>): PageTranscription {
  const raison = asString(json.raison);
  const recettesRaw = Array.isArray(json.recettes) ? json.recettes : [];

  const recettes: TranscribedRecipe[] = recettesRaw
    .filter((r): r is Record<string, unknown> => !!r && typeof r === "object")
    .map((r) => ({
      titre: asString(r.titre),
      langue: normalizeLanguageCode(r.langue),
      introduction: asString(r.introduction),
      inventaire: parseInventory(r.inventaire),
      lecturesIncertaines: asStringList(r.lectures_incertaines),
      page: asNumberOrNull(r.page),
      portions: asNumberOrNull(r.portions),
      tempsPreparation: asStringOrNull(r.temps_preparation),
      tempsCuisson: asStringOrNull(r.temps_cuisson),
      tempsRepos: asStringOrNull(r.temps_repos),
      difficulte: asStringOrNull(r.difficulte),
      sectionsIngredients: (Array.isArray(r.sections_ingredients) ? r.sections_ingredients : [])
        .filter((s): s is Record<string, unknown> => !!s && typeof s === "object")
        .map((s) => ({ titre: asString(s.titre), lignes: asStringList(s.lignes) }))
        .filter((s) => s.lignes.length > 0),
      sectionsEtapes: (Array.isArray(r.sections_etapes) ? r.sections_etapes : [])
        .filter((s): s is Record<string, unknown> => !!s && typeof s === "object")
        .map((s) => ({ titre: asString(s.titre), etapes: asStringList(s.etapes) }))
        .filter((s) => s.etapes.length > 0),
      notes: (Array.isArray(r.notes) ? r.notes : [])
        .filter((n): n is Record<string, unknown> => !!n && typeof n === "object")
        .map((n) => ({ genre: asString(n.genre), texte: asString(n.texte) }))
        .filter((n) => n.texte.length > 0),
    }))
    .filter((r) => r.sectionsEtapes.length > 0 || r.sectionsIngredients.length > 0);

  const pageType = resolvePageType(json.page_type, raison);

  return {
    // Une page annoncée « recette » sans une seule étape recopiée n'en est pas
    // une : on suit ce qui a été lu, pas l'étiquette.
    pageType: pageType === "recipe" && recettes.length === 0 ? "other" : pageType,
    titre: asString(json.titre) || "Page sans titre",
    page: asNumberOrNull(json.page),
    raison,
    document: asString(json.document),
    recettes,
  };
}

/**
 * Transcrit une page (image, PDF, DOCX) et dit ce qu'elle contient.
 *
 * Une transcription illisible n'est PAS rattrapée par un repli optimiste. Le
 * code précédent, faute de JSON valide, supposait « recipe » pour ne pas perdre
 * de contenu — et fabriquait une recette vide qu'il fallait ensuite retrouver
 * dans les brouillons. On lève : le job passe en erreur, visible, relançable.
 */
export async function transcribePage(
  bytes: Buffer,
  mimeType: string,
  ctx: ModelCallContext,
  additionalPages: ExtraPage[] = [],
  bookWindow?: BookWindowInfo,
): Promise<PageTranscription> {
  // `TRANSCRIPTION_PROMPT` passe en PREMIER, marqué `cache: true` : c'est le
  // seul fragment identique d'un appel à l'autre, sur toutes les pages de
  // tous les livres, et Anthropic ne met en cache que ce qui précède un
  // fragment marqué — jamais ce qui le suit. Le mettre après la pièce jointe
  // (l'image, différente à chaque page) empêcherait tout cache : ce serait
  // déjà divergent avant même d'atteindre le prompt. Le préambule de tranche
  // vient ensuite, non mis en cache — il varie avec le livre — puis la pièce
  // jointe, qui varie à chaque page.
  const parts = [
    textPart(TRANSCRIPTION_PROMPT, { cache: true }),
    ...(bookWindow ? [textPart(bookWindowPreamble(bookWindow))] : []),
    await attachmentPart(mimeType, bytes, ctx),
    ...additionalPages.map((p) => filePart(p.mimeType, p.bytes)),
  ];

  const result = await callModel({
    parts,
    ctx: {
      ...ctx,
      feature: "transcription_page",
      timeoutMs: 5 * 60 * 1000,
      // Lire une page de livre demande du soin, pas de la vitesse. Le réglage
      // par défaut — `low` — venait de la chaîne nutrition, où deviner des
      // calories ne réclame aucun raisonnement. Appliqué ici, il donnait un
      // modèle pressé : « en poudre » recollé au mauvais ingrédient, une
      // énumération de grains de poivre et de graines de coriandre résumée en
      // « les épices ». Des phrases élégantes, et fausses.
      effort: "high",
    },
    maxTokens: TRANSCRIPTION_MAX_TOKENS,
  });

  return lireTranscription(result, {
    ctx,
    feature: "transcription_page",
    message: "Page recopiée par le modèle, avant tout balisage",
    extra: { pages: 1 + additionalPages.length, mimeType, tranche: bookWindow?.kind ?? null },
    echec: "La transcription de la page n'a pas pu être lue.",
  });
}

/**
 * Transcrit un texte collé par l'utilisateur.
 *
 * Même prompt que la page, précédé du préambule qui dit ce qui change — voir
 * `TEXT_TRANSCRIPTION_PREAMBLE`. Cette passe ne produit pas de CookLang : elle
 * rend la recette telle qu'elle est écrite, en JSON, exactement comme un scan.
 * C'est ce qui permet à la passe 2 et au contrôle de fidélité de s'appliquer
 * sans une ligne de code de plus.
 *
 * Le poste de coût reste `text_extraction` : c'est le même travail, vu du
 * comptable — convertir un texte libre en recette — et lui donner un nouveau
 * nom aurait fait disparaître le poste des mois déjà comptabilisés.
 *
 * `feature` vaut `url_import_fallback` pour le texte principal d'une page web
 * sans données structurées : même travail, poste à part, pour que le coût de
 * l'import par lien se lise seul.
 */
export async function transcribeText(
  freeText: string,
  ctx: ModelCallContext,
  feature = "text_extraction",
): Promise<PageTranscription> {
  const result = await callModel({
    parts: [
      textPart(`${TEXT_TRANSCRIPTION_PREAMBLE}\n\n${TRANSCRIPTION_PROMPT}\n\n---\n${freeText}`),
    ],
    // Même soin que pour une page : c'est la passe qui décide de ce qui est
    // recopié et de ce qui est perdu.
    ctx: { ...ctx, feature, timeoutMs: 2 * 60 * 1000, effort: "high" },
    maxTokens: TRANSCRIPTION_MAX_TOKENS,
  });

  return lireTranscription(result, {
    ctx,
    feature,
    message:
      feature === "text_extraction"
        ? "Texte collé recopié par le modèle, avant tout balisage"
        : "Texte de la page web recopié par le modèle, avant tout balisage",
    extra: { longueurTexte: freeText.length },
    echec: "La transcription du texte n'a pas pu être lue.",
  });
}

/**
 * Journalise la réponse du modèle puis la lit, ou lève.
 *
 * Le journal AVANT la lecture, toujours : une réponse illisible est justement
 * celle qu'on veut relire, et la ranger après le `JSON.parse` revenait à ne la
 * garder que quand elle ne servait à rien.
 */
async function lireTranscription(
  result: ModelCallResult,
  args: {
    ctx: ModelCallContext;
    feature: string;
    message: string;
    extra: Record<string, unknown>;
    echec: string;
  },
): Promise<PageTranscription> {
  const { ctx } = args;
  const text = result.text.trim();
  await logAiText({
    stage: "transcription",
    text,
    message: args.message,
    feature: args.feature,
    provider: result.provider,
    model: result.model,
    moduleType: "IMPORT",
    correlationId: ctx.correlationId,
    scanId: ctx.scanId,
    callId: result.callId,
    jobId: ctx.jobId,
    userId: ctx.userId,
    extra: args.extra,
  });

  try {
    return parseTranscription(JSON.parse(extractJsonObject(text)) as Record<string, unknown>);
  } catch (err) {
    await logError({
      message: `${args.feature}: réponse illisible`,
      errorDescription: err instanceof Error ? err.message : String(err),
      moduleType: "IMPORT",
      correlationId: ctx.correlationId,
      jobId: ctx.jobId,
      userId: ctx.userId,
      extra: { longueur: text.length },
    });
    throw new Error(args.echec);
  }
}
