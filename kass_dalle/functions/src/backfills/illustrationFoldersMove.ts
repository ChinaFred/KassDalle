/**
 * Rangement des illustrations hors des dossiers modérés — logique pure du
 * backfill « Ranger les illustrations » (`illustration_folders_move`,
 * `illustrationFoldersMoveBackfillCallable.ts`).
 *
 * Le contrôle « Dossiers des illustrations » (`illustrationFolders.ts`) liste
 * les recettes dont une URL de `image_urls` ou de `thumbnail_urls` n'est pas
 * sous `illustrations/` ou `recipes/`. L'administrateur a regardé ces images
 * et les garde telles quelles. Ce module décide, sans accès au bucket ni à
 * Firestore :
 *
 *  - quelles images d'une recette sont à ranger, et lesquelles ne peuvent pas
 *    l'être (autre bucket, autre hôte, chemin mal formé) ;
 *  - où chacune est copiée : `recipes/{recipeId}/illus_moved_{empreinte}.{ext}`,
 *    le dossier d'une illustration de recette approuvée (`targetPathFor`,
 *    `moderation/promote.ts`), sous un nom stable pour qu'un passage relancé
 *    retrouve la copie au lieu d'en créer une seconde ;
 *  - quels champs de la recette citent le fichier, et leur nouvelle valeur ;
 *  - si l'ancien fichier peut être supprimé : seulement quand plus aucun
 *    document lu ne le cite, et que la lecture a été complète.
 *
 * Testé par `tests/illustrationFoldersMove.test.ts`.
 */

import { createHash } from "node:crypto";

import type { ModerationReason } from "../moderation/decision";
import { isWellFormedObjectPath } from "../utils/storagePath";
import {
  illustrationFolderIssue,
  illustrationObjectRef,
  type StorageObjectRef,
} from "./illustrationFolders";

/** Options de lecture d'une URL : buckets admis, émulateur. */
export interface BucketOptions {
  buckets: readonly string[];
  allowEmulator?: boolean;
}

/** Motif de la ligne de modération écrite pour une image rangée. */
export const MOVE_MODERATION_REASON: ModerationReason = "manual_folder_move";

/**
 * Champs d'une recette qui ne se réécrivent pas : ils nomment le fichier
 * importé, que l'import relit sous `scans/{uid}/` (`promotedScanPrefix`), et
 * pas une image affichée. Ils restent des références : un fichier qu'ils
 * citent n'est pas supprimé.
 */
export const SOURCE_FIELDS: ReadonlySet<string> = new Set([
  "source_file_url",
  "source_file_name",
  "additional_source_file_urls",
  "source_url",
]);

/**
 * Une adresse dans un texte : URL `http(s)` ou `gs://`, jusqu'au premier
 * espace, guillemet, chevron, crochet ou parenthèse — la fin d'un lien
 * Markdown `![…](url)` du CookLang.
 */
const URL_TOKEN = /(?:https?:\/\/|gs:\/\/)[^\s"'<>()[\]]+/g;

/** Clé unique d'un objet : `bucket/chemin`. */
export function objectKey(ref: StorageObjectRef): string {
  return `${ref.bucket}/${ref.path}`;
}

/** `scans/{uid}/…` : page ou fichier promu par un import (`scanAndPromoteUploadFn`). */
const SCAN_SOURCE = /^scans\/[^/]+\/.+$/;
/**
 * `users/{uid}/free_recipe_cover_{horodatage}.{ext}` : la couverture « Recette
 * libre » d'un compte, seul fichier écrit sous `users/` — par la modération
 * (`targetPathFor`, `free_recipe_cover`), et avant elle par le client, au même
 * nom. Tout autre fichier sous `users/` n'est pas rangé.
 */
const USER_COVER_SOURCE = /^users\/[^/]+\/free_recipe_cover_[0-9]+\.[a-z0-9]{1,5}$/;

/**
 * Pourquoi une image hors des dossiers modérés ne se range pas, ou `null` si
 * elle peut l'être. Seules deux sources sont admises : une page d'import sous
 * `scans/{uid}/` et une couverture « Recette libre » sous `users/{uid}/`.
 * `quarantine/` (pas encore modérée), `rejected/` (refusée), `tickets/`
 * (capture privée), `covers/` et tout autre dossier sont refusés : les copier
 * publierait comme approuvée une image que personne n'a validée — un éditeur
 * peut écrire n'importe quelle URL du bucket dans sa recette.
 */
export function movableSourceRefusal(path: string): string | null {
  if (SCAN_SOURCE.test(path) || USER_COVER_SOURCE.test(path)) return null;
  const folder = sourceFolder(path);
  if (folder === "quarantine/") return "quarantine/ : image pas encore modérée, non rangée";
  if (folder === "rejected/") return "rejected/ : image refusée par la modération, non rangée";
  if (folder === "tickets/") return "tickets/ : capture privée d'un ticket, non rangée";
  if (folder === "users/")
    return "users/ : fichier autre qu'une couverture de recette libre, non rangé";
  if (folder === "scans/") return "scans/ : chemin sans dossier de compte, non rangé";
  return `${folder} : dossier non admis pour le rangement`;
}

/** Raison d'un refus : l'image n'est pas dans la liste du dernier contrôle. */
export const NOT_FLAGGED_REASON =
  "non signalée par le dernier contrôle : relancez « Dossiers des illustrations »";

/** Clé d'un couple (recette, objet) de la liste fermée. */
export function flaggedPairKey(recipeId: string, key: string): string {
  return `${recipeId}\n${key}`;
}

/**
 * Lit la liste fermée écrite par le contrôle « Dossiers des illustrations »
 * (`signalees` de `app_config/backfill_run_illustration_folders`) : les
 * couples (recette, `bucket/chemin`) qu'il a signalés, et que l'administrateur
 * a regardés. `null` si la liste est absente ou n'est pas une liste : le
 * rangement ne fait alors rien. Une entrée mal formée est ignorée.
 */
export function readFlaggedList(raw: unknown): Set<string> | null {
  if (!Array.isArray(raw)) return null;
  const out = new Set<string>();
  for (const entry of raw) {
    if (entry == null || typeof entry !== "object") continue;
    const recipeId = (entry as Record<string, unknown>).recipe_id;
    const key = (entry as Record<string, unknown>).key;
    if (typeof recipeId !== "string" || recipeId.length === 0) continue;
    if (typeof key !== "string" || key.length === 0) continue;
    out.add(flaggedPairKey(recipeId, key));
  }
  return out;
}

/** Ce qu'une recette demande au rangement. */
export interface RecipeMovePlan {
  /** Images à ranger, sans doublon, dans l'ordre : `image_urls`, puis `thumbnail_urls`. */
  refs: StorageObjectRef[];
  /** Raisons pour lesquelles une image ne peut pas être rangée (autre bucket…). */
  blocking: string[];
}

/**
 * Les images d'une recette hors des dossiers modérés. Une image dans
 * `illustrations/` ou `recipes/` n'y figure pas ; une image que le contrôle
 * signale mais qui n'est pas un objet des buckets admis va dans `blocking`.
 */
export function recipeMovePlan(
  data: Record<string, unknown>,
  opts: BucketOptions,
  scope: { recipeId: string; flagged: ReadonlySet<string> },
): RecipeMovePlan {
  const refs: StorageObjectRef[] = [];
  const seen = new Set<string>();
  const blocking: string[] = [];
  const block = (reason: string) => {
    if (!blocking.includes(reason)) blocking.push(reason);
  };
  for (const field of ["image_urls", "thumbnail_urls"] as const) {
    const value = data[field];
    if (value == null) continue;
    if (!Array.isArray(value)) {
      block(`${field} n'est pas une liste`);
      continue;
    }
    for (const url of value) {
      const issue = illustrationFolderIssue(url, opts);
      if (issue == null) continue;
      const ref = illustrationObjectRef(url, opts);
      if (ref == null) {
        block(issue);
        continue;
      }
      const refusal = movableSourceRefusal(ref.path);
      if (refusal != null) {
        block(refusal);
        continue;
      }
      const key = objectKey(ref);
      if (!scope.flagged.has(flaggedPairKey(scope.recipeId, key))) {
        block(NOT_FLAGGED_REASON);
        continue;
      }
      if (!seen.has(key)) {
        seen.add(key);
        refs.push(ref);
      }
    }
  }
  return { refs, blocking };
}

/** Type d'une image lu sur ses premiers octets : JPEG, PNG, WebP, ou `null`. */
export function illustrationMimeOf(
  head: Uint8Array,
): "image/jpeg" | "image/png" | "image/webp" | null {
  if (head.length >= 3 && head[0] === 0xff && head[1] === 0xd8 && head[2] === 0xff) {
    return "image/jpeg";
  }
  const png = [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a];
  if (head.length >= 8 && png.every((b, i) => head[i] === b)) return "image/png";
  const ascii = (from: number, to: number) => String.fromCharCode(...head.subarray(from, to));
  if (head.length >= 12 && ascii(0, 4) === "RIFF" && ascii(8, 12) === "WEBP") {
    return "image/webp";
  }
  return null;
}

const EXTENSIONS: Record<string, string> = {
  "image/jpeg": "jpg",
  "image/png": "png",
  "image/webp": "webp",
};

/** Empreinte courte et stable d'un objet source (16 caractères hexadécimaux). */
export function sourceFingerprint(ref: StorageObjectRef): string {
  return createHash("sha256").update(objectKey(ref)).digest("hex").slice(0, 16);
}

/**
 * Chemin de la copie rangée : `recipes/{recipeId}/illus_moved_{empreinte}.{ext}`.
 *
 * Le dossier est celui d'une illustration de recette approuvée
 * (`targetPathFor`, `recipe_illustration`). Le nom ne porte pas d'horodatage,
 * contrairement à une promotion : il dépend du seul fichier source, pour qu'un
 * passage interrompu puis relancé retrouve la copie déjà faite. Lève si
 * l'identifiant de recette ne peut pas entrer dans un chemin.
 */
export function movedIllustrationPath(
  recipeId: string,
  source: StorageObjectRef,
  mime: "image/jpeg" | "image/png" | "image/webp",
): string {
  if (recipeId.length === 0 || recipeId.includes("/") || recipeId === "." || recipeId === "..") {
    throw new Error("Identifiant de recette inutilisable dans un chemin Storage.");
  }
  const path = `recipes/${recipeId}/illus_moved_${sourceFingerprint(source)}.${EXTENSIONS[mime]}`;
  if (!isWellFormedObjectPath(path)) {
    throw new Error("Chemin de destination mal formé.");
  }
  return path;
}

/** Identifiant stable de la ligne de modération d'une image rangée. */
export function moveModerationId(recipeId: string, source: StorageObjectRef): string {
  const digest = createHash("sha256")
    .update(`${recipeId}\n${objectKey(source)}`)
    .digest("hex")
    .slice(0, 32);
  return `illustration_move_${digest}`;
}

/** URL de téléchargement d'un objet, avec son jeton. */
export function downloadUrlFor(bucket: string, path: string, token: string): string {
  return (
    `https://firebasestorage.googleapis.com/v0/b/${bucket}/o/` +
    `${encodeURIComponent(path)}?alt=media&token=${token}`
  );
}

function isPlainObject(value: unknown): value is Record<string, unknown> {
  if (value == null || typeof value !== "object" || Array.isArray(value)) return false;
  const proto = Object.getPrototypeOf(value);
  return proto === Object.prototype || proto === null;
}

/**
 * Les objets de [wanted] qu'une chaîne cite : URL entière, URL dans un texte,
 * ou chemin nu égal au chemin d'un objet recherché (quel que soit son
 * bucket — dans le doute, la référence compte).
 */
function keysInString(
  text: string,
  wanted: ReadonlySet<string>,
  wantedPaths: ReadonlyMap<string, readonly string[]>,
  opts: BucketOptions,
  out: Set<string>,
): void {
  const bare = text.trim();
  const byPath = wantedPaths.get(bare);
  if (byPath) for (const key of byPath) out.add(key);
  for (const token of text.match(URL_TOKEN) ?? []) {
    const ref = illustrationObjectRef(token, opts);
    if (ref == null) continue;
    const key = objectKey(ref);
    if (wanted.has(key)) out.add(key);
  }
}

/**
 * Les objets de [wanted] (clés `bucket/chemin`) cités quelque part dans
 * [value] : chaînes, listes et objets simples, à toute profondeur. Les autres
 * valeurs (horodatages, références de document) ne citent rien.
 */
export function referencedObjectKeys(
  value: unknown,
  wanted: ReadonlySet<string>,
  opts: BucketOptions,
): Set<string> {
  const out = new Set<string>();
  if (wanted.size === 0) return out;
  const wantedPaths = new Map<string, string[]>();
  for (const key of wanted) {
    const path = pathOfKey(key, opts);
    if (path == null) continue;
    const list = wantedPaths.get(path) ?? [];
    list.push(key);
    wantedPaths.set(path, list);
  }
  const visit = (v: unknown, depth: number) => {
    if (depth > 32) return;
    if (typeof v === "string") {
      keysInString(v, wanted, wantedPaths, opts, out);
    } else if (Array.isArray(v)) {
      for (const item of v) visit(item, depth + 1);
    } else if (isPlainObject(v)) {
      for (const item of Object.values(v)) visit(item, depth + 1);
    }
  };
  visit(value, 0);
  return out;
}

/** Chemin d'une clé `bucket/chemin`, le bucket étant l'un des buckets admis. */
function pathOfKey(key: string, opts: BucketOptions): string | null {
  for (const bucket of opts.buckets) {
    if (key.startsWith(`${bucket}/`)) return key.substring(bucket.length + 1);
  }
  return null;
}

/** Nouvelle adresse d'un objet rangé. */
export interface MovedObject {
  /** Chemin de la copie dans le bucket par défaut. */
  path: string;
  /** URL de téléchargement de la copie, avec son jeton. */
  url: string;
}

/** Ce que la réécriture change dans une recette. */
export interface RecipeRewrite {
  /** Champs de premier niveau à écrire, avec leur nouvelle valeur entière. */
  update: Record<string, unknown>;
  /** Nombre de chaînes réécrites. */
  replaced: number;
}

/**
 * Réécrit, dans tous les champs d'une recette sauf [SOURCE_FIELDS], chaque
 * citation d'un objet de [moves] (clé `bucket/chemin`) : une URL, entière ou
 * dans un texte, devient l'URL de la copie ; un chemin nu devient le chemin de
 * la copie. Seuls les champs qui changent sont rendus, avec leur valeur
 * entière. Les valeurs qui ne sont ni chaînes, ni listes, ni objets simples
 * sont recopiées telles quelles.
 */
export function rewriteIllustrationReferences(
  data: Record<string, unknown>,
  moves: ReadonlyMap<string, MovedObject>,
  opts: BucketOptions,
): RecipeRewrite {
  const update: Record<string, unknown> = {};
  let replaced = 0;
  if (moves.size === 0) return { update, replaced };

  const byPath = new Map<string, MovedObject>();
  for (const [key, moved] of moves) {
    const path = pathOfKey(key, opts);
    if (path != null && !byPath.has(path)) byPath.set(path, moved);
  }

  const rewriteString = (text: string): string => {
    const bare = byPath.get(text.trim());
    if (bare) {
      replaced += 1;
      return bare.path;
    }
    let changed = false;
    const next = text.replace(URL_TOKEN, (token) => {
      const ref = illustrationObjectRef(token, opts);
      const moved = ref == null ? undefined : moves.get(objectKey(ref));
      if (!moved) return token;
      changed = true;
      return moved.url;
    });
    if (changed) replaced += 1;
    return next;
  };

  const rewrite = (v: unknown, depth: number): unknown => {
    if (depth > 32) return v;
    if (typeof v === "string") return rewriteString(v);
    if (Array.isArray(v)) {
      let changed = false;
      const next = v.map((item) => {
        const r = rewrite(item, depth + 1);
        if (r !== item) changed = true;
        return r;
      });
      return changed ? next : v;
    }
    if (isPlainObject(v)) {
      let changed = false;
      const next: Record<string, unknown> = {};
      for (const [k, item] of Object.entries(v)) {
        const r = rewrite(item, depth + 1);
        if (r !== item) changed = true;
        next[k] = r;
      }
      return changed ? next : v;
    }
    return v;
  };

  for (const [field, value] of Object.entries(data)) {
    if (SOURCE_FIELDS.has(field)) continue;
    const next = rewrite(value, 0);
    if (next !== value) update[field] = next;
  }
  return { update, replaced };
}

/** Sort de l'ancien fichier après le rangement. */
export type SourceFileDecision =
  /** Plus aucun document lu ne le cite, et la lecture a été complète. */
  | "delete"
  /** Un autre document le cite encore (recette, job d'import, sauvegarde…). */
  | "keep_referenced"
  /** La lecture des références n'a pas abouti : on ne sait pas. */
  | "keep_unverified"
  /** Le fichier n'existe plus. */
  | "missing";

/**
 * Peut-on supprimer l'ancien fichier ? Seulement si personne ne le cite et que
 * toutes les collections lues l'ont été jusqu'au bout. Dans le doute, il reste.
 */
export function sourceFileDecision(args: {
  holders: ReadonlySet<string> | undefined;
  indexComplete: boolean;
  sourceExists: boolean;
}): SourceFileDecision {
  if (!args.sourceExists) return "missing";
  if (!args.indexComplete) return "keep_unverified";
  if (args.holders != null && args.holders.size > 0) return "keep_referenced";
  return "delete";
}

/** Le premier dossier d'un chemin, pour une ligne lisible : `scans/`, `users/`. */
export function sourceFolder(path: string): string {
  const slash = path.indexOf("/");
  if (slash <= 0) return "racine du bucket";
  const first = path.substring(0, slash);
  return /^[A-Za-z0-9_.-]{1,40}$/.test(first) ? `${first}/` : "dossier inattendu";
}

/**
 * Les formes sous lesquelles une recette peut citer [ref] dans `image_urls`
 * ou `thumbnail_urls` : les URL lues pendant le passage, l'URL de
 * téléchargement de chaque jeton de l'objet, l'URL publique
 * `storage.googleapis.com`, le chemin nu et la forme `gs://`. Sert la relecture faite juste avant de supprimer l'ancien
 * fichier (requêtes `array-contains`).
 */
export function citationVariants(
  ref: StorageObjectRef,
  seen: Iterable<string>,
  tokens: Iterable<string> = [],
): string[] {
  const out = new Set<string>();
  for (const value of seen) if (value.length > 0) out.add(value);
  for (const token of tokens) {
    const t = token.trim();
    if (t.length > 0) out.add(downloadUrlFor(ref.bucket, ref.path, t));
  }
  out.add(`https://storage.googleapis.com/${ref.bucket}/${ref.path}`);
  out.add(ref.path);
  out.add(`gs://${ref.bucket}/${ref.path}`);
  return [...out];
}

/** Jetons de téléchargement d'un objet (`firebaseStorageDownloadTokens`, séparés par des virgules). */
export function downloadTokensOf(metadata: unknown): string[] {
  if (metadata == null || typeof metadata !== "object") return [];
  const raw = (metadata as Record<string, unknown>).firebaseStorageDownloadTokens;
  if (typeof raw !== "string") return [];
  return raw
    .split(",")
    .map((t) => t.trim())
    .filter((t) => t.length > 0);
}

/**
 * Message d'erreur sans adresse ni chemin d'objet : une erreur Storage cite
 * souvent `bucket/scans/{uid}/…` ou `users/{uid}/…`, qui portent un uid. Les
 * URL, les références `gs://` et tout chemin à partir d'un segment suivi de
 * `/` sont remplacés par « [chemin] ». Le code d'erreur, s'il existe, est
 * gardé en tête. Sert le journal et la liste « À revoir ».
 */
export function scrubbedErrorMessage(err: unknown): string {
  const code =
    err != null && typeof err === "object" && "code" in err
      ? String((err as { code: unknown }).code)
      : "";
  const raw = err instanceof Error ? err.message : String(err);
  const scrubbed = raw
    .replace(/(?:https?:\/\/|gs:\/\/)\S+/g, "[chemin]")
    .replace(/[^\s"'`()[\]<>]*[A-Za-z0-9_.-]+\/[^\s"'`()[\]<>]+/g, "[chemin]")
    .replace(/\s+/g, " ")
    .trim()
    .slice(0, 200);
  const message = scrubbed.length > 0 ? scrubbed : "erreur inconnue";
  return code.length > 0 && code !== "undefined" ? `${code} : ${message}` : message;
}
