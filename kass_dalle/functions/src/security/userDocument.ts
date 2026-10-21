/**
 * Contrôle d'un document `users/{uid}` écrit avant le schéma que
 * `firestore.rules` impose depuis v0.24.30 et v0.24.32 (tickets #162, #163).
 *
 * Les règles contrôlent une écriture, pas les documents déjà en base. Ce module
 * dit, pour un document stocké, ce qui casse réellement, et l'effet de chaque
 * écart. Lecture seule, pur, testé (`tests/userDocument.test.ts`). Il sert le
 * backfill « Contrôler les comptes » (`callable/usersSchemaCheckBackfillCallable.ts`).
 *
 * Trois effets, et trois seulement :
 *
 *  - **la fiche n'apparaît pas dans Comptes** : `AppUser.fromFirestore` lève,
 *    et `watchAllUsers` saute le document. Cas : `email` ou `display_name`
 *    absent, nul ou non texte ; `created_at` ou `last_seen_at` absent ou autre
 *    chose qu'une date ; `preferred_name`, `photo_url` ou
 *    `free_recipe_cover_url` présent et non texte ; `is_revoked` présent, non
 *    nul et non booléen ;
 *  - **compte sans droit** : un rôle absent ou inconnu se lit « aucun rôle »
 *    côté serveur (`readRole`, `security/roles.ts`) et `pending` côté client,
 *    qui l'affiche « en attente » dans Comptes ;
 *  - **toute règle qui lit la révocation échoue** : `is_revoked` absent. La
 *    règle `isRevoked()` lit `.is_revoked` sans valeur par défaut, et l'erreur
 *    vaut refus. `is_revoked: null` est conforme : la règle le lit faux sans
 *    erreur, et le client `as bool? ?? false`.
 *
 * Ne sont pas signalés, parce qu'ils ne bloquent rien : un champ hors de la
 * liste des règles et un `uid` différent de l'identifiant (la mise à jour ne
 * teste que les champs qu'elle change, `_upsertUser` ne touche que
 * `last_seen_at`, `photo_url` et `display_name`, le client lit l'uid sur
 * l'identifiant et aucune Function ne lit `users.uid`) ; la longueur des noms
 * et de `photo_url`, la forme de la couverture (contrôlées seulement quand le
 * champ change ; `publicCoverUrl` filtre la couverture du profil public).
 */

import { Timestamp } from "firebase-admin/firestore";

import { readRole } from "./roles";

/** Longueur maximale d'une valeur citée dans une raison. */
const QUOTED_MAX_LENGTH = 40;

/** Longueur maximale du prénom cité dans le libellé d'un compte. */
const LABEL_NAME_MAX_LENGTH = 20;

/** Caractères de l'identifiant cités dans le libellé d'un compte. */
const LABEL_ID_LENGTH = 6;

/** Ce qui remplace un texte qui pourrait être une adresse e-mail. */
const MASKED = "(valeur masquée)";

/** Effet d'un champ que `AppUser.fromFirestore` ne sait pas lire. */
const NOT_LISTED = "la fiche n'apparaît pas dans Comptes";

/** Effet d'un rôle absent ou inconnu. */
const NO_RIGHTS = "compte sans droit, affiché « en attente » dans Comptes";

/** Effet de `is_revoked` absent. */
const REVOCATION_FAILS = "toute règle qui lit la révocation échoue pour ce compte";

function clip(text: string, max: number): string {
  const clean = text.replace(/\s+/g, " ").trim();
  return clean.length > max ? `${clean.slice(0, max - 1)}…` : clean;
}

/** Un texte qui contient « @ » peut être une adresse : il n'est jamais cité. */
function mayBeEmail(text: string): boolean {
  return text.includes("@");
}

/**
 * Une valeur stockée, citée dans une raison : bornée, sur une ligne. Un texte
 * garde ses espaces de début et de fin — `"admin "` est inconnu à cause d'eux.
 * Un texte qui contient « @ » est masqué : la raison est recopiée dans
 * `app_config/backfill_run_users_schema_check` et dans « Copier la liste ».
 */
function quote(value: unknown): string {
  let text: string;
  if (typeof value === "string" && mayBeEmail(value)) {
    text = MASKED;
  } else if (typeof value === "string") {
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

/** Absent, ou nul. */
function missing(data: Record<string, unknown>, key: string): boolean {
  return !(key in data) || data[key] === null || data[key] === undefined;
}

/** Textes obligatoires, et leur nom courant. */
const REQUIRED_TEXT_FIELDS: readonly (readonly [string, string, string])[] = [
  ["email", "adresse e-mail", "absente"],
  ["display_name", "nom Google", "absent"],
];

/** Dates obligatoires, et leur nom courant. */
const DATE_FIELDS: readonly (readonly [string, string])[] = [
  ["created_at", "date de création"],
  ["last_seen_at", "date de dernière visite"],
];

/** Textes facultatifs (absents, nuls ou texte), et leur nom courant. */
const OPTIONAL_TEXT_FIELDS: readonly (readonly [string, string])[] = [
  ["preferred_name", "nom préféré"],
  ["photo_url", "photo"],
  ["free_recipe_cover_url", "couverture « Recette libre »"],
];

/**
 * Les raisons, en français simple, pour lesquelles le document [data] de
 * `users/{uid}` casse une lecture ou une règle ; une liste vide s'il ne casse
 * rien. Chaque raison nomme le champ entre parenthèses et dit son effet.
 */
export function userDocumentIssues(data: Record<string, unknown>): string[] {
  const issues: string[] = [];

  for (const [key, label, absent] of REQUIRED_TEXT_FIELDS) {
    if (missing(data, key)) issues.push(`${label} ${absent} (${key}) : ${NOT_LISTED}`);
    else if (typeof data[key] !== "string") {
      issues.push(`${label} n'est pas un texte (${key}) : ${NOT_LISTED}`);
    }
  }

  if (missing(data, "role")) issues.push(`rôle absent (role) : ${NO_RIGHTS}`);
  else if (readRole(data.role) === null) {
    issues.push(`rôle inconnu (role) ${quote(data.role)} : ${NO_RIGHTS}`);
  }

  if (!("is_revoked" in data) || data.is_revoked === undefined) {
    issues.push(`indicateur de révocation absent (is_revoked) : ${REVOCATION_FAILS}`);
  } else if (data.is_revoked !== null && typeof data.is_revoked !== "boolean") {
    issues.push(
      `indicateur de révocation n'est pas un booléen (is_revoked) ${quote(data.is_revoked)} : ` +
        NOT_LISTED,
    );
  }

  for (const [key, label] of DATE_FIELDS) {
    if (missing(data, key)) issues.push(`${label} absente (${key}) : ${NOT_LISTED}`);
    else if (!isTimestamp(data[key])) {
      issues.push(`${label} n'est pas une date (${key}) : ${NOT_LISTED}`);
    }
  }

  for (const [key, label] of OPTIONAL_TEXT_FIELDS) {
    if (!missing(data, key) && typeof data[key] !== "string") {
      issues.push(`${label} n'est pas un texte (${key}) : ${NOT_LISTED}`);
    }
  }

  return issues;
}

/**
 * Le nom d'un compte dans la liste « À revoir » : son prénom (le nom préféré,
 * sinon le premier mot du nom Google), tronqué, et le début de son
 * identifiant. Jamais l'adresse : la liste est recopiée dans
 * `app_config/backfill_run_users_schema_check`, que tout administrateur lit.
 * Un prénom qui contient « @ » peut être une adresse : il est écarté.
 */
export function userReviewLabel(docId: string, data: Record<string, unknown>): string {
  const shortId = docId.length > LABEL_ID_LENGTH ? `${docId.slice(0, LABEL_ID_LENGTH)}…` : docId;
  const preferred = typeof data.preferred_name === "string" ? data.preferred_name.trim() : "";
  const google =
    typeof data.display_name === "string" ? (data.display_name.trim().split(/\s+/)[0] ?? "") : "";
  const candidate = [preferred, google].find((n) => n !== "" && !mayBeEmail(n)) ?? "";
  const name = clip(candidate, LABEL_NAME_MAX_LENGTH);
  return name ? `${name} (${shortId})` : `Compte ${shortId}`;
}
