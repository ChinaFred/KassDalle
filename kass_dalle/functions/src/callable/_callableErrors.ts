/**
 * Traduction des erreurs des callables d'IA en `HttpsError`, pour le client.
 *
 * Deux erreurs partent en `resource-exhausted` : le plafond d'IA du compte
 * (`BudgetExceededError`, message rédigé en français pour le membre) et la
 * saturation du fournisseur (`GeminiQuotaExceededError`, dont le texte brut
 * est remplacé par un texte fixe). Le client ne reprend que le premier : il le
 * reconnaît à `details.scope` (`AI_BUDGET_SCOPE`) et à `details.reason`. Un
 * quota du fournisseur ne porte aucun `details`, et le client affiche « Service
 * d'IA saturé ».
 *
 * Sans SDK de fournisseur : testé seul (`tests/callableErrors.test.ts`).
 */

import { HttpsError } from "firebase-functions/v2/https";

import { BudgetExceededError } from "../ai/budget";
import { GeminiError, GeminiQuotaExceededError } from "../gemini/client";
import { StoragePathRefusedError } from "../utils/storagePath";
import { logError } from "../logging";

/**
 * `details.scope` d'un refus du plafond d'IA. `details.reason` seul ne suffit
 * pas : la conception d'un planning renvoie aussi `resource-exhausted` avec
 * `reason: "cost"` quand le plafond de **la génération** est atteint
 * (`PlanningRunDenied`), un autre plafond que celui du compte.
 */
export const AI_BUDGET_SCOPE = "ai_budget";

/**
 * Refus du plafond d'IA, avec son message pour le membre et la raison du
 * refus : `cost` (dépense du jour), `calls` (nombre d'appels du jour),
 * `import` (plafond d'un livre) ou `concurrency` (trop d'appels en cours).
 */
export function budgetExceededHttpsError(err: BudgetExceededError): HttpsError {
  return new HttpsError("resource-exhausted", err.message, {
    reason: err.reason,
    scope: AI_BUDGET_SCOPE,
  });
}

/** Message d'un fournisseur d'IA saturé (`GeminiQuotaExceededError`). */
export const PROVIDER_QUOTA_CALLABLE_MESSAGE = "Le service d'IA est saturé. Réessayez plus tard.";

/** Message d'une panne du fournisseur d'IA (`GeminiError`). */
export const PROVIDER_ERROR_CALLABLE_MESSAGE = "Le service d'IA n'a pas pu traiter la demande.";

/** Message de toute autre erreur, non typée. */
export const UNEXPECTED_CALLABLE_MESSAGE = "Le traitement a échoué.";

/**
 * Traduit une erreur pour le client. Aucun texte brut (fournisseur, SDK,
 * bibliothèque) ne part au client : les erreurs du fournisseur et les erreurs
 * non typées reçoivent un texte fixe, et leur texte brut est journalisé ici
 * (`logError`), parce que la plupart des appelants ne journalisent pas avant
 * `throw await toHttpsError(e)`. Deux exceptions, pour ne pas écrire deux
 * lignes pour un même échec (`callableErrorAlreadyLogged`).
 */
export async function toHttpsError(
  err: unknown,
  options: { alreadyLogged?: boolean } = {},
): Promise<HttpsError> {
  if (err instanceof HttpsError) return err;
  // Plafond de dépense atteint : ce n'est ni une panne ni un défaut de droits,
  // et le message est déjà écrit pour la personne qui le lira. `internal`
  // l'aurait présenté comme un incident, et l'aurait fait réessayer.
  if (err instanceof BudgetExceededError) {
    return budgetExceededHttpsError(err);
  }
  // Fichier hors des dossiers admis : un défaut de droits, refusé avant
  // tout téléchargement et tout appel de modèle. Message rédigé par
  // `resolveAllowedStoragePath`.
  if (err instanceof StoragePathRefusedError) {
    return new HttpsError("permission-denied", err.message);
  }
  if (!callableErrorAlreadyLogged(err, options)) {
    const raw = err instanceof Error ? err.message : String(err);
    await logError({
      message: "Callable d'IA en échec — texte fixe renvoyé au client",
      errorDescription: raw,
      extra: { errorName: err instanceof Error ? err.name : typeof err },
    });
  }
  // Quota du fournisseur : même code que le plafond, sans `details`.
  if (err instanceof GeminiQuotaExceededError) {
    return new HttpsError("resource-exhausted", PROVIDER_QUOTA_CALLABLE_MESSAGE);
  }
  if (err instanceof GeminiError) {
    return new HttpsError("internal", PROVIDER_ERROR_CALLABLE_MESSAGE);
  }
  return new HttpsError("internal", UNEXPECTED_CALLABLE_MESSAGE);
}

/**
 * Vrai quand l'erreur a déjà sa ligne de journal, avec son contexte : une
 * erreur du fournisseur marquée `logged` par `gemini/client.ts`, `enhancer.ts`
 * ou `imageGenerator.ts`, ou un appelant qui vient de la journaliser lui-même
 * (`alreadyLogged`).
 */
export function callableErrorAlreadyLogged(
  err: unknown,
  options: { alreadyLogged?: boolean } = {},
): boolean {
  if (options.alreadyLogged === true) return true;
  return (err instanceof GeminiError || err instanceof GeminiQuotaExceededError) && err.logged;
}
