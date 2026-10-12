/**
 * Origine d'un appel d'IA : déclenché directement par un utilisateur (callable),
 * ou par le serveur (pipeline Cloud Tasks, déclencheur Firestore, tâche
 * planifiée).
 *
 * La limite d'appels simultanés du plafond (`ai/budget.ts`) ne vise que le
 * premier cas : c'est là qu'une rafale vient d'une personne. Un import de livre
 * lance cinq tranches en parallèle, plus la nutrition de chaque recette écrite,
 * toutes imputées au même compte ; les refuser pour simultanéité ferait échouer
 * un import légitime.
 *
 * Le marqueur voyage dans un `AsyncLocalStorage`, posé par les gardes des
 * callables (`callable/_auth.ts`, `baseContext`). Un champ du contexte d'appel
 * aurait dû traverser une vingtaine de fonctions qui reconstruisent leur
 * contexte (`{ correlationId, userId, feature }`) et l'auraient perdu sans
 * erreur. Le stockage asynchrone suit la requête jusqu'à l'appel de modèle,
 * quel que soit le chemin, et n'existe pas dans un déclencheur.
 *
 * Aucun SDK : `node:async_hooks` est intégré à Node.
 */

import { AsyncLocalStorage } from "node:async_hooks";

interface CallOrigin {
  interactive?: true;
  /** Passage programmé d'un backfill : plafond de base, sans multiplicateur. */
  baseBudgetCap?: true;
}

const storage = new AsyncLocalStorage<CallOrigin>();

/**
 * Marque la suite de la requête en cours comme déclenchée par un utilisateur.
 *
 * À appeler **de façon synchrone** au début du traitement de la requête —
 * c'est ce que fait `baseContext`, première instruction de chaque garde : le
 * marqueur vaut alors pour tout ce que le traitement attend ensuite.
 */
export function markInteractiveCall(): void {
  storage.enterWith({ interactive: true });
}

/** Vrai si l'appel en cours vient d'une requête d'utilisateur (callable). */
export function isInteractiveCall(): boolean {
  return storage.getStore()?.interactive === true;
}

/** Exécute `fn` comme une requête d'utilisateur — pour les tests. */
export function runAsInteractive<T>(fn: () => T): T {
  return storage.run({ interactive: true }, fn);
}

/**
 * Exécute `fn` comme un passage programmé de backfill : le plafond de dépense
 * du compte imputé s'applique **sans son multiplicateur** (fondateur ×100).
 * Un passage que personne ne surveille n'a pas à profiter de la marge prévue
 * pour les essais du propriétaire. Voir `effectiveBudgetMultiplier`.
 */
export function runWithBaseBudgetCap<T>(fn: () => T): T {
  return storage.run({ baseBudgetCap: true }, fn);
}

/** Vrai dans un passage programmé de backfill (`runWithBaseBudgetCap`). */
export function isBaseBudgetCap(): boolean {
  return storage.getStore()?.baseBudgetCap === true;
}
