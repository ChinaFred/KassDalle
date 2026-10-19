/**
 * Cache des préférences comprises, et l'étape de traduction du planning.
 *
 * `users/{uid}/preferences/planning_constraints` garde, par empreinte du
 * texte (`constraintTextHash`), les critères que le modèle a relevés et ce
 * qu'il n'a pas su traduire. Le document est écrit par le serveur seul ; son
 * titulaire le lit pour afficher « Compris : … » sous chaque champ.
 *
 * Forme : `{ entries: { <sha256>: { text, criteria, untranslated,
 * prompt_version, translated_at } }, updated_at }`, quarante entrées au plus.
 *
 * Aucun SDK lourd : `firebase-admin/firestore` seul, déjà chargé par le reste
 * du bundle.
 */

import { Timestamp, getFirestore } from "firebase-admin/firestore";

import { COLL_USER_PREFERENCES, COLL_USERS, PLANNING_CONSTRAINTS_DOC_ID } from "../config";
import { BudgetExceededError } from "../ai/budget";
import type { ModelCallContext } from "../ai/types";
import { logError, logWarn } from "../logging";
import {
  CONSTRAINT_CACHE_MAX_ENTRIES,
  CONSTRAINT_TEXTS_PER_CALL,
  CONSTRAINT_TEXT_MAX_CHARS,
  PLANNING_CONSTRAINTS_PROMPT_VERSION,
  constraintTextHash,
  translateConstraintTexts,
  type TextUnderstanding,
} from "./planningConstraints";
import { planningCriteriaToMap, readPlanningCriteria } from "./planningCriteria";

/** Ce que la génération dit d'un texte, renvoyé au client. */
export interface ConstraintTextOutcome {
  text: string;
  /** Forme canonique (`planningCriteriaToMap`). */
  criteria: Record<string, unknown>;
  untranslated: string;
  /**
   * `cached` : lu dans le cache, aucun appel. `translated` : traduit par cet
   * appel. `failed` : le modèle n'a pas répondu ou n'a rien rendu pour ce
   * texte. `skipped` : pas traduit (mode sans modèle, texte trop long, trop
   * de textes) — il part au prompt tel quel, non vérifié.
   */
  status: "cached" | "translated" | "failed" | "skipped";
}

export interface PlanningUnderstanding {
  /** Texte (sans espaces en bord) → ce qui en a été compris. */
  understood: Map<string, TextUnderstanding>;
  outcomes: ConstraintTextOutcome[];
  /** Le modèle a été appelé pour cette génération. */
  called: boolean;
}

interface CacheEntry {
  text: string;
  understanding: TextUnderstanding;
  translatedAtMs: number;
  raw: Record<string, unknown>;
}

function cacheRef(uid: string) {
  return getFirestore()
    .collection(COLL_USERS)
    .doc(uid)
    .collection(COLL_USER_PREFERENCES)
    .doc(PLANNING_CONSTRAINTS_DOC_ID);
}

/** Lit les entrées du cache : une entrée mal formée est ignorée. */
export function readConstraintCache(data: unknown): Map<string, CacheEntry> {
  const out = new Map<string, CacheEntry>();
  const entries =
    data != null && typeof data === "object" ? (data as Record<string, unknown>).entries : null;
  if (entries == null || typeof entries !== "object" || Array.isArray(entries)) return out;
  for (const [hash, value] of Object.entries(entries as Record<string, unknown>)) {
    if (value == null || typeof value !== "object" || Array.isArray(value)) continue;
    const v = value as Record<string, unknown>;
    if (typeof v.text !== "string" || v.prompt_version !== PLANNING_CONSTRAINTS_PROMPT_VERSION) {
      continue;
    }
    const at = v.translated_at as { toMillis?: unknown } | null | undefined;
    const ms = at != null && typeof at.toMillis === "function" ? Number(at.toMillis()) : 0;
    out.set(hash, {
      text: v.text,
      understanding: {
        criteria: readPlanningCriteria(v.criteria),
        untranslated: typeof v.untranslated === "string" ? v.untranslated : "",
      },
      translatedAtMs: Number.isFinite(ms) ? ms : 0,
      raw: v,
    });
  }
  return out;
}

/**
 * Ce que le programme comprend des textes d'une génération.
 *
 * Les textes connus du cache ne coûtent rien. Les autres sont traduits en un
 * appel, si [translate] le permet (mode avec modèle) : seize au plus, de
 * deux mille caractères au plus. Un échec du modèle, du cache ou de son
 * écriture ne bloque jamais la génération : le texte part au prompt tel
 * quel, et l'écran dit « non vérifié ».
 */
export async function understandPlanningTexts(args: {
  uid: string;
  texts: readonly string[];
  translate: boolean;
  ctx: ModelCallContext;
  nowMs: number;
}): Promise<PlanningUnderstanding> {
  const texts = [...new Set(args.texts.map((t) => t.trim()).filter((t) => t.length > 0))];
  const understood = new Map<string, TextUnderstanding>();
  const outcomes: ConstraintTextOutcome[] = [];
  if (texts.length === 0) return { understood, outcomes, called: false };
  const logCtx = {
    correlationId: args.ctx.correlationId,
    userId: args.uid,
    feature: "planning_constraints",
  };

  let cache = new Map<string, CacheEntry>();
  try {
    const snap = await cacheRef(args.uid).get();
    cache = snap.exists ? readConstraintCache(snap.data()) : cache;
  } catch (err) {
    await logError({
      ...logCtx,
      message: "Planning — cache des préférences comprises illisible, textes retraduits",
      errorDescription: err instanceof Error ? err.message : String(err),
    });
  }

  const outcome = (
    text: string,
    u: TextUnderstanding | null,
    status: ConstraintTextOutcome["status"],
  ): ConstraintTextOutcome => ({
    text,
    criteria: planningCriteriaToMap(u?.criteria ?? readPlanningCriteria(null)),
    untranslated: u?.untranslated ?? text,
    status,
  });

  const missing: string[] = [];
  for (const text of texts) {
    const hit = cache.get(constraintTextHash(text));
    if (hit && hit.text === text) {
      understood.set(text, hit.understanding);
      outcomes.push(outcome(text, hit.understanding, "cached"));
    } else {
      missing.push(text);
    }
  }

  const eligible = args.translate
    ? missing
        .filter((t) => t.length <= CONSTRAINT_TEXT_MAX_CHARS)
        .slice(0, CONSTRAINT_TEXTS_PER_CALL)
    : [];
  for (const text of missing) {
    if (!eligible.includes(text)) outcomes.push(outcome(text, null, "skipped"));
  }
  if (eligible.length === 0) return { understood, outcomes, called: false };

  let answer: Map<number, TextUnderstanding> | null = null;
  try {
    answer = await translateConstraintTexts(eligible, args.ctx);
  } catch (err) {
    const payload = {
      ...logCtx,
      message:
        err instanceof BudgetExceededError
          ? "Planning — plafond du jour atteint, préférences transmises sans vérification"
          : "Planning — traduction des préférences en échec, transmises sans vérification",
      errorDescription: err instanceof Error ? err.message : String(err),
      extra: { texts: eligible.length },
    };
    if (err instanceof BudgetExceededError) await logWarn(payload);
    else await logError(payload);
  }

  const fresh: Record<string, unknown> = {};
  const now = Timestamp.fromMillis(args.nowMs);
  let unanswered = 0;
  eligible.forEach((text, index) => {
    const u = answer?.get(index) ?? null;
    if (!u) {
      if (answer) unanswered++;
      outcomes.push(outcome(text, null, "failed"));
      return;
    }
    understood.set(text, u);
    outcomes.push(outcome(text, u, "translated"));
    fresh[constraintTextHash(text)] = {
      text,
      criteria: planningCriteriaToMap(u.criteria),
      untranslated: u.untranslated,
      prompt_version: PLANNING_CONSTRAINTS_PROMPT_VERSION,
      translated_at: now,
    };
  });
  if (unanswered > 0) {
    await logWarn({
      ...logCtx,
      message: "Planning — textes sans réponse du modèle, transmis sans vérification",
      extra: { unanswered, texts: eligible.length },
    });
  }

  if (Object.keys(fresh).length > 0) {
    // Les plus récentes d'abord, quarante au plus : le cache ne grossit pas.
    const kept = [...cache.entries()]
      .filter(([hash]) => !(hash in fresh))
      .sort((a, b) => b[1].translatedAtMs - a[1].translatedAtMs)
      .slice(0, Math.max(0, CONSTRAINT_CACHE_MAX_ENTRIES - Object.keys(fresh).length));
    try {
      await cacheRef(args.uid).set({
        entries: { ...Object.fromEntries(kept.map(([h, e]) => [h, e.raw])), ...fresh },
        updated_at: now,
      });
    } catch (err) {
      await logError({
        ...logCtx,
        message:
          "Planning — cache des préférences comprises non écrit, retraduction au prochain appel",
        errorDescription: err instanceof Error ? err.message : String(err),
      });
    }
  }
  return { understood, outcomes, called: true };
}
