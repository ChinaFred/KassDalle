/**
 * Dossier Storage d'une illustration de recette (`image_urls`,
 * `thumbnail_urls`) : sous `illustrations/` ou `recipes/`, les deux dossiers
 * où n'arrive qu'une image modérée, ou ailleurs.
 *
 * Sert le backfill de contrôle « Dossiers des illustrations »
 * (`illustrationFoldersBackfillCallable.ts`), qui n'écrit rien : il liste les
 * recettes dont une illustration pointe hors de ces dossiers, avant qu'une
 * version suivante limite l'affichage à eux seuls. Le backfill « Ranger les
 * illustrations » (`illustrationFoldersMove.ts`) range celles qu'il liste.
 *
 * Mêmes formes d'URL que le client (`lib/core/utils/app_image_url.dart`) :
 * URL de téléchargement `firebasestorage.googleapis.com` (chemin encodé, lu
 * décodé), URL publique `storage.googleapis.com/<bucket>/<chemin>`, et
 * `gs://`. Le chemin se lit par `utils/storagePath.ts`.
 *
 * Pur : aucun accès au bucket, testé par `tests/illustrationFolders.test.ts`.
 */

import {
  PUBLISHED_IMAGE_PREFIXES,
  isWellFormedObjectPath,
  storageObjectPathOf,
} from "../utils/storagePath";

/** Ancien bucket par défaut du projet : des documents anciens y pointent encore. */
export const LEGACY_APP_BUCKET = "kassdale-6d948.appspot.com";

const PUBLIC_HOST = "storage.googleapis.com";

/** Longueur maximale du nom de dossier cité dans le compte rendu. */
const FOLDER_MAX_LENGTH = 40;

/**
 * Verdict sur une URL : `null` si elle est sous un dossier modéré, sinon le
 * lieu trouvé, en français, sans l'URL ni le chemin complet (le chemin d'un
 * scan porte l'uid de son auteur).
 */
export function illustrationFolderIssue(
  url: unknown,
  opts: { buckets: readonly string[]; allowEmulator?: boolean },
): string | null {
  if (typeof url !== "string" || url.trim().length === 0) return "adresse vide ou illisible";
  const reference = url.trim();
  if (!/^[a-z][a-z0-9+.-]*:/i.test(reference)) return "chemin sans adresse";

  const ref = objectRefInBuckets(reference, opts);
  if (ref === undefined) return "hors du stockage de l'application";
  if (ref === null) return "autre bucket";
  const path = ref.path;
  if (!isWellFormedObjectPath(path)) return "chemin mal formé";
  const ok = PUBLISHED_IMAGE_PREFIXES.some(
    (prefix) => path.startsWith(prefix) && path.length > prefix.length,
  );
  return ok ? null : folderLabel(path);
}

/** Un objet du stockage : son bucket et son chemin décodé. */
export interface StorageObjectRef {
  bucket: string;
  path: string;
}

/**
 * L'objet nommé par une URL d'illustration (`firebasestorage`, publique ou
 * `gs://`), s'il est dans l'un des buckets admis et que son chemin est bien
 * formé ; `null` sinon. Un chemin nu, sans adresse, n'est pas lu : il ne
 * s'affiche pas. Sert le rangement des illustrations
 * (`illustrationFoldersMove.ts`), qui doit savoir où copier.
 */
export function illustrationObjectRef(
  url: unknown,
  opts: { buckets: readonly string[]; allowEmulator?: boolean },
): StorageObjectRef | null {
  if (typeof url !== "string") return null;
  const reference = url.trim();
  if (!/^[a-z][a-z0-9+.-]*:/i.test(reference)) return null;
  const ref = objectRefInBuckets(reference, opts);
  if (ref == null || !isWellFormedObjectPath(ref.path)) return null;
  return ref;
}

/**
 * Bucket et chemin d'objet si la référence nomme l'un des buckets admis ;
 * `null` si elle est du stockage Firebase mais d'un autre bucket ; `undefined`
 * si elle n'en est pas (autre hôte, autre schéma, URL illisible).
 */
function objectRefInBuckets(
  reference: string,
  opts: { buckets: readonly string[]; allowEmulator?: boolean },
): StorageObjectRef | null | undefined {
  const publicPath = publicUrlPath(reference);
  if (publicPath !== undefined) {
    if (publicPath == null) return undefined;
    return opts.buckets.includes(publicPath.bucket) ? publicPath : null;
  }

  for (const bucketName of opts.buckets) {
    const path = storageObjectPathOf(reference, {
      bucketName,
      allowEmulator: opts.allowEmulator,
      silent: true,
    });
    if (path != null) return { bucket: bucketName, path };
  }
  const anyBucket = storageObjectPathOf(reference, {
    allowEmulator: opts.allowEmulator,
    silent: true,
  });
  return anyBucket == null ? undefined : null;
}

/**
 * `https://storage.googleapis.com/<bucket>/<chemin>` : bucket et chemin
 * décodé ; `null` si l'URL a cet hôte mais une forme illisible ; `undefined`
 * pour un autre hôte.
 */
function publicUrlPath(reference: string): { bucket: string; path: string } | null | undefined {
  // Une URL illisible sera refusée par `storageObjectPathOf` (sans trace :
  // `silent`) : ici, seule la forme publique est cherchée.
  if (!URL.canParse(reference)) return undefined;
  const parsed = new URL(reference);
  if (parsed.protocol !== "https:" || parsed.hostname !== PUBLIC_HOST || parsed.port !== "") {
    return undefined;
  }
  const raw = parsed.pathname.replace(/^\//, "");
  const slash = raw.indexOf("/");
  if (slash <= 0 || slash === raw.length - 1) return null;
  try {
    return {
      bucket: decodeURIComponent(raw.substring(0, slash)),
      path: decodeURIComponent(raw.substring(slash + 1)),
    };
  } catch (err) {
    // `console.error` plutôt que `logError` : module pur, testable sans Cloud
    // Logging. Le message seul : jamais la référence, qui porte un uid.
    console.error(
      JSON.stringify({
        severity: "ERROR",
        message: "illustrationFolders : URL publique mal encodée",
        errorDescription: err instanceof Error ? err.message : String(err),
      }),
    );
    return null;
  }
}

/**
 * Le premier segment du chemin, suivi de `/` : `scans/`, `rejected/`. Un nom
 * hors de `[A-Za-z0-9_.-]` ou trop long n'est pas recopié — un chemin écrit
 * par un client peut contenir n'importe quoi.
 */
function folderLabel(path: string): string {
  const slash = path.indexOf("/");
  if (slash < 0) return "racine du bucket";
  const first = path.substring(0, slash);
  if (first.length > FOLDER_MAX_LENGTH || !/^[A-Za-z0-9_.-]+$/.test(first)) {
    return "dossier inattendu";
  }
  return `${first}/`;
}

/**
 * Les lieux hors dossiers modérés des illustrations d'une recette, sans
 * doublon, dans l'ordre : d'abord `image_urls`, puis `thumbnail_urls`. Un
 * champ absent est vide ; un champ présent qui n'est pas une liste est signalé.
 */
export function recipeIllustrationIssues(
  data: Record<string, unknown>,
  opts: { buckets: readonly string[]; allowEmulator?: boolean },
): string[] {
  const issues: string[] = [];
  const push = (issue: string) => {
    if (!issues.includes(issue)) issues.push(issue);
  };
  for (const field of ["image_urls", "thumbnail_urls"] as const) {
    const value = data[field];
    if (value == null) continue;
    if (!Array.isArray(value)) {
      push(`${field} n'est pas une liste`);
      continue;
    }
    for (const url of value) {
      const issue = illustrationFolderIssue(url, opts);
      if (issue != null) push(issue);
    }
  }
  return issues;
}

/** Une image signalée par le contrôle : sa recette et l'objet cité (`bucket/chemin`). */
export interface FlaggedIllustration {
  recipe_id: string;
  key: string;
}

/** Entrées gardées au plus dans la liste des images signalées. */
export const FLAGGED_LIST_LIMIT = 2000;

/**
 * Les objets (`bucket/chemin`) que le contrôle signale dans une recette : les
 * URL de `image_urls` et `thumbnail_urls` hors des dossiers modérés qui nomment
 * un objet d'un bucket admis. Une URL d'un autre hôte ou bucket n'a pas
 * d'objet à nommer : elle reste dans « À revoir » sans entrer dans la liste.
 * Le rangement (`illustrationFoldersMove.ts`) ne copie que ces objets.
 */
export function flaggedIllustrationKeys(
  data: Record<string, unknown>,
  opts: { buckets: readonly string[]; allowEmulator?: boolean },
): string[] {
  const keys: string[] = [];
  for (const field of ["image_urls", "thumbnail_urls"] as const) {
    const value = data[field];
    if (!Array.isArray(value)) continue;
    for (const url of value) {
      if (illustrationFolderIssue(url, opts) == null) continue;
      const ref = illustrationObjectRef(url, opts);
      if (ref == null) continue;
      const key = `${ref.bucket}/${ref.path}`;
      if (!keys.includes(key)) keys.push(key);
    }
  }
  return keys;
}
