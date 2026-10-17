/**
 * Doublons à l'import : une recette déjà présente dans le livre.
 *
 * Un scan à la volée produit parfois une page déjà importée, ou la même page
 * deux fois de suite. Le critère est volontairement simple et sans appel de
 * modèle : même livre, même titre normalisé, et des numéros de page qui ne se
 * contredisent pas. Deux numéros connus et différents écartent le doublon :
 * « Pâte brisée » revient souvent dans plusieurs chapitres d'un même livre.
 *
 * La référence est cherchée à deux endroits :
 *  - les recettes du livre, brouillons et validées, quel que soit leur auteur
 *    (`titre_key`, posé par le serveur) ;
 *  - les imports du même livre encore en file ou en cours. Le balisage dure
 *    jusqu'à sept minutes : sans eux, la même page scannée deux fois de suite
 *    passerait, parce que le premier brouillon n'existe pas encore quand le
 *    second a fini sa transcription. Le plus ancien sert de référence — sauf si
 *    le plus récent a déjà passé sa vérification : les transcriptions peuvent
 *    finir dans l'ordre inverse des scans, et celui qui a déjà passé va écrire
 *    son brouillon. C'est alors l'import qui vérifie en second qui attend.
 */

import { getFirestore, Timestamp } from "firebase-admin/firestore";

import { COLL_PROCESSING_JOBS, COLL_RECIPES } from "../config";

/**
 * Le titre sous la forme comparée : minuscules, sans accents, ponctuation
 * remplacée par une espace, espaces réduites. Chaîne vide quand rien ne reste.
 */
export function titleKey(titre: string | null | undefined): string {
  if (typeof titre !== "string") return "";
  return titre
    .normalize("NFD")
    .replace(/[̀-ͯ]/g, "")
    .toLowerCase()
    .replace(/œ/g, "oe")
    .replace(/æ/g, "ae")
    .replace(/[^\p{L}\p{N}]+/gu, " ")
    .trim();
}

/** Deux numéros connus et différents écartent le doublon ; un numéro absent ne l'écarte pas. */
export function pagesCompatible(
  a: number | null | undefined,
  b: number | null | undefined,
): boolean {
  if (a == null || b == null) return true;
  return a === b;
}

/** Ce qu'une recette en cours d'import a de comparable. */
export interface DuplicateCandidate {
  titre: string;
  page: number | null;
}

/** La référence trouvée pour un doublon possible. */
export interface DuplicateMatch {
  /** Titre de la recette en cours d'import. */
  titre: string;
  /** Titre et page de la référence. */
  existingTitre: string;
  existingPage: number | null;
  /** Recette existante du livre, brouillon ou validée. */
  recipeId: string | null;
  /** Import plus ancien encore en cours, dont la recette n'existe pas encore. */
  jobId: string | null;
}

/** Une recette du livre telle que la requête la rend. */
export interface ExistingRecipe {
  id: string;
  titre: string;
  page: number | null;
}

/** Un import du même livre tel que la requête le rend. */
export interface InFlightJob {
  id: string;
  status: string;
  createdAtMs: number;
  titreKeys: string[];
  titreKeyPages: (number | null)[];
  titres: string[];
  /** L'import a passé sa vérification et continue (`duplicate_checked`). */
  checked: boolean;
}

/**
 * Choisit la référence d'un candidat, ou `null`. Fonction pure : la lecture de
 * Firestore est faite à côté, pour que la décision se teste sans émulateur.
 *
 * Une recette existante l'emporte sur un import en cours. Un import n'est une
 * référence que s'il est en file ou en cours, et créé avant celui-ci (à date
 * égale, l'identifiant départage) ou déjà vérifié : un import terminé a écrit
 * ses recettes, que la première source couvre ; un import en erreur ou lui-même
 * en attente de doublon ne produira rien tant qu'on ne le relance pas. Un
 * import plus récent pas encore vérifié verra celui-ci à sa propre vérification.
 */
export function pickDuplicate(args: {
  candidate: DuplicateCandidate;
  recipes: ExistingRecipe[];
  jobs: InFlightJob[];
  self: { jobId: string; createdAtMs: number; createdRecipeIds: string[] };
}): DuplicateMatch | null {
  const key = titleKey(args.candidate.titre);
  if (!key) return null;
  const own = new Set(args.self.createdRecipeIds);
  const recipe = args.recipes.find(
    (r) =>
      !own.has(r.id) && titleKey(r.titre) === key && pagesCompatible(r.page, args.candidate.page),
  );
  if (recipe) {
    return {
      titre: args.candidate.titre,
      existingTitre: recipe.titre,
      existingPage: recipe.page,
      recipeId: recipe.id,
      jobId: null,
    };
  }
  const earlier = (j: InFlightJob) =>
    j.createdAtMs < args.self.createdAtMs ||
    (j.createdAtMs === args.self.createdAtMs && j.id < args.self.jobId);
  for (const job of args.jobs) {
    if (job.id === args.self.jobId) continue;
    if (job.status !== "queued" && job.status !== "processing") continue;
    if (!earlier(job) && !job.checked) continue;
    const index = job.titreKeys.indexOf(key);
    if (index < 0) continue;
    const page = job.titreKeyPages[index] ?? null;
    if (!pagesCompatible(page, args.candidate.page)) continue;
    return {
      titre: args.candidate.titre,
      existingTitre: job.titres[index] ?? args.candidate.titre,
      existingPage: page,
      recipeId: null,
      jobId: job.id,
    };
  }
  return null;
}

/**
 * Cherche la référence de chaque candidat dans le livre. Deux requêtes par
 * titre distinct, servies par les index : `book_id` + `titre_key` sur les
 * recettes, `book_id` + `titre_keys` sur les imports.
 */
export async function findDuplicates(args: {
  bookId: string;
  candidates: DuplicateCandidate[];
  self: { jobId: string; createdAtMs: number; createdRecipeIds: string[] };
}): Promise<(DuplicateMatch | null)[]> {
  const db = getFirestore();
  const keys = [...new Set(args.candidates.map((c) => titleKey(c.titre)).filter((k) => k))];
  const recipes: ExistingRecipe[] = [];
  const jobs: InFlightJob[] = [];
  await Promise.all(
    keys.map(async (key) => {
      const [recipeSnap, jobSnap] = await Promise.all([
        db
          .collection(COLL_RECIPES)
          .where("book_id", "==", args.bookId)
          .where("titre_key", "==", key)
          .get(),
        db
          .collection(COLL_PROCESSING_JOBS)
          .where("book_id", "==", args.bookId)
          .where("titre_keys", "array-contains", key)
          .get(),
      ]);
      for (const doc of recipeSnap.docs) {
        const data = doc.data();
        recipes.push({
          id: doc.id,
          titre: typeof data.titre === "string" ? data.titre : "",
          page: typeof data.page_number === "number" ? data.page_number : null,
        });
      }
      for (const doc of jobSnap.docs) {
        const data = doc.data();
        const createdAt = data.created_at;
        jobs.push({
          id: doc.id,
          status: typeof data.status === "string" ? data.status : "",
          createdAtMs: createdAt instanceof Timestamp ? createdAt.toMillis() : Number.MAX_VALUE,
          titreKeys: asStringList(data.titre_keys),
          titreKeyPages: asPageList(data.titre_key_pages),
          titres: asStringList(data.titre_key_titres),
          checked: data.duplicate_checked === true,
        });
      }
    }),
  );
  return args.candidates.map((candidate) =>
    pickDuplicate({ candidate, recipes, jobs, self: args.self }),
  );
}

/** Les champs que le job porte pour que les imports suivants le comparent. */
export function jobTitleKeyFields(candidates: DuplicateCandidate[]): Record<string, unknown> {
  const kept = candidates.filter((c) => titleKey(c.titre));
  return {
    titre_keys: kept.map((c) => titleKey(c.titre)),
    titre_key_pages: kept.map((c) => c.page),
    titre_key_titres: kept.map((c) => c.titre),
  };
}

/** La forme écrite sur le job (`duplicates`) ou sur un brouillon (`duplicate_of`). */
export function duplicateJobEntry(match: DuplicateMatch): Record<string, unknown> {
  return {
    titre: match.titre,
    existing_titre: match.existingTitre,
    existing_page: match.existingPage,
    recipe_id: match.recipeId,
    job_id: match.jobId,
  };
}

export function duplicateOfField(match: DuplicateMatch): Record<string, unknown> {
  return {
    titre: match.existingTitre,
    page: match.existingPage,
    recipe_id: match.recipeId,
    job_id: match.jobId,
  };
}

function asStringList(value: unknown): string[] {
  return Array.isArray(value) ? value.map((v) => (typeof v === "string" ? v : "")) : [];
}

function asPageList(value: unknown): (number | null)[] {
  return Array.isArray(value) ? value.map((v) => (typeof v === "number" ? v : null)) : [];
}
