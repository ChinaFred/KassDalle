/**
 * Conformité d'un document `users/{uid}` au schéma que `firestore.rules` impose
 * depuis v0.24.30 et v0.24.32 (tickets #162, #163).
 *
 * Les règles contrôlent une écriture, pas les documents déjà en base : un
 * document écrit avant elles peut ne pas les respecter. `AppUser.fromFirestore`
 * lève alors une exception, `watchAllUsers` saute le compte, et son titulaire
 * ne peut plus mettre à jour son propre document. Ce module dit, pour un
 * document stocké, ce qui casse. Lecture seule, pur, testé
 * (`tests/userDocument.test.ts`). Il sert le backfill « Contrôler les comptes »
 * (`callable/usersSchemaCheckBackfillCallable.ts`).
 *
 * Seul ce qui casse réellement est signalé :
 *
 *  - la lecture par `AppUser.fromFirestore` : `email` et `display_name` en
 *    texte, `preferred_name`, `photo_url` et `free_recipe_cover_url` absents,
 *    nuls ou en texte, `created_at` et `last_seen_at` en date ;
 *  - `readRole` (`security/roles.ts`) : le rôle, l'une des quatre valeurs
 *    écrites à l'identique ;
 *  - `isRevoked()` dans les règles : `is_revoked` présent (un champ absent lu
 *    par `.is_revoked` est une erreur, et une erreur vaut refus) et booléen ;
 *  - ce que les règles refuseraient à la prochaine écriture du titulaire :
 *    un champ hors de `createdKeysOk` et `ownerKeysOk`, un `uid` différent de
 *    l'identifiant du document, un type que `updatedTypesOk` exige.
 *
 * Ne sont pas signalés, parce qu'ils ne bloquent rien : la longueur des noms
 * (`nameOk`) et de `photo_url` (`photoUrlOk`), la forme de
 * `free_recipe_cover_url` (`coverUrlOk`). Les règles ne les contrôlent que
 * quand le champ change, et le profil public filtre la couverture
 * (`publicCoverUrl`).
 */

import { Timestamp } from "firebase-admin/firestore";

import { readRole } from "./roles";

/**
 * Champs qu'un document `users/{uid}` peut porter : ceux de la création
 * (`createdKeysOk`) et `import_illustrations`, que le titulaire ajoute
 * (`ownerKeysOk`). L'administrateur n'en ajoute aucun autre (`adminKeysOk`).
 */
export const USER_DOCUMENT_KEYS = [
  "uid",
  "email",
  "display_name",
  "preferred_name",
  "photo_url",
  "free_recipe_cover_url",
  "role",
  "created_at",
  "last_seen_at",
  "is_revoked",
  "import_illustrations",
] as const;

/** Longueur maximale d'une valeur citée dans une raison. */
const QUOTED_MAX_LENGTH = 40;

/** Longueur maximale du prénom cité dans le libellé d'un compte. */
const LABEL_NAME_MAX_LENGTH = 20;

/** Caractères de l'identifiant cités dans le libellé d'un compte. */
const LABEL_ID_LENGTH = 6;

function clip(text: string, max: number): string {
  const clean = text.replace(/\s+/g, " ").trim();
  return clean.length > max ? `${clean.slice(0, max - 1)}…` : clean;
}

/**
 * Une valeur stockée, citée dans une raison : bornée, sur une ligne. Un texte
 * garde ses espaces de début et de fin — `"admin "` est inconnu à cause d'eux.
 */
function quote(value: unknown): string {
  let text: string;
  if (typeof value === "string") {
    const flat = Array.from(value, (c) => {
      const code = c.charCodeAt(0);
      return code < 0x20 || code === 0x7f ? " " : c;
    }).join("");
    const cut = flat.length > QUOTED_MAX_LENGTH ? `${flat.slice(0, QUOTED_MAX_LENGTH - 1)}…` : flat;
    text = `« ${cut} »`;
  } else if (value === null) text = "null";
  else if (typeof value === "number" || typeof value === "boolean") text = String(value);
  else if (Array.isArray(value)) text = "une liste";
  else text = `une valeur de type ${typeof value}`;
  return text;
}

function isTimestamp(value: unknown): boolean {
  return value instanceof Timestamp;
}

/** Absent, ou nul : les règles lisent l'un et l'autre `null` (`get(…, null)`). */
function missing(data: Record<string, unknown>, key: string): boolean {
  return !(key in data) || data[key] === null || data[key] === undefined;
}

/**
 * Les raisons, en français simple, pour lesquelles le document [data] de
 * `users/[docId]` s'écarte du schéma des règles ; une liste vide s'il est
 * conforme. Ordre stable : champs non permis, puis champ par champ.
 */
export function userDocumentIssues(docId: string, data: Record<string, unknown>): string[] {
  const issues: string[] = [];
  const allowed = USER_DOCUMENT_KEYS as readonly string[];

  for (const key of Object.keys(data).sort()) {
    if (!allowed.includes(key)) issues.push(`champ non permis : ${clip(key, QUOTED_MAX_LENGTH)}`);
  }

  if ("uid" in data && data.uid !== docId) issues.push("uid différent de l'identifiant");

  if (missing(data, "email")) issues.push("email absent");
  else if (typeof data.email !== "string") issues.push("email n'est pas un texte");

  if (missing(data, "display_name")) issues.push("display_name absent");
  else if (typeof data.display_name !== "string") issues.push("display_name n'est pas un texte");

  if (missing(data, "role")) issues.push("rôle absent");
  else if (readRole(data.role) === null) issues.push(`rôle inconnu : ${quote(data.role)}`);

  if (!("is_revoked" in data) || data.is_revoked === undefined) issues.push("is_revoked absent");
  else if (typeof data.is_revoked !== "boolean") {
    issues.push(`is_revoked n'est pas un booléen : ${quote(data.is_revoked)}`);
  }

  for (const key of ["created_at", "last_seen_at"]) {
    if (missing(data, key)) issues.push(`${key} absent`);
    else if (!isTimestamp(data[key])) issues.push(`${key} n'est pas une date`);
  }

  for (const key of ["preferred_name", "photo_url", "free_recipe_cover_url"]) {
    if (!missing(data, key) && typeof data[key] !== "string") {
      issues.push(`${key} n'est pas un texte`);
    }
  }

  return issues;
}

/**
 * Le nom d'un compte dans la liste « À revoir » : son prénom (le nom préféré,
 * sinon le premier mot du nom Google), tronqué, et le début de son
 * identifiant. Jamais l'adresse : la liste est recopiée dans
 * `app_config/backfill_run_users_schema_check`, que tout administrateur lit.
 */
export function userReviewLabel(docId: string, data: Record<string, unknown>): string {
  const shortId = docId.length > LABEL_ID_LENGTH ? `${docId.slice(0, LABEL_ID_LENGTH)}…` : docId;
  const preferred = typeof data.preferred_name === "string" ? data.preferred_name.trim() : "";
  const google =
    typeof data.display_name === "string" ? (data.display_name.trim().split(/\s+/)[0] ?? "") : "";
  const name = clip(preferred || google, LABEL_NAME_MAX_LENGTH);
  return name ? `${name} (${shortId})` : `Compte ${shortId}`;
}
