/**
 * App Check — attester que l'appel vient de l'application, et non d'un script.
 *
 * Ce que le contrôle d'accès savait déjà vérifier : *qui* appelle (un compte
 * nommé, non révoqué). Ce qu'il ne savait pas : *quoi* appelle. Une callable
 * est une URL HTTPS publique et devinable ; la seule chose qu'elle exigeait
 * était un jeton d'identité, lequel s'obtient avec la clé web — publique par
 * conception — ou se recopie depuis le navigateur d'un membre de la famille.
 * Votre application Flutter et une boucle `while true` dans un terminal
 * étaient indiscernables côté serveur, et chaque appel part chez Gemini ou
 * Anthropic.
 *
 * App Check ajoute une attestation délivrée par la plateforme : reCAPTCHA
 * Enterprise sur le web, Play Integrity sur Android, DeviceCheck sur iOS. Le
 * jeton accompagne l'appel, `req.app` en porte le résultat.
 *
 * ── Pourquoi une politique en base, et non l'option `enforceAppCheck` ───────
 *
 * `enforceAppCheck: true` se décide au déploiement. Or le jour où l'attestation
 * refuse à tort — clé mal configurée, client pas encore à jour, fournisseur en
 * panne — il faut pouvoir rouvrir en une minute, pas en un déploiement. Les
 * fonctions gardent donc l'option à `false` : la requête arrive, et c'est ce
 * module qui décide, d'après `app_config/app_check_policy`. Même moule que le
 * routage d'IA et la grille tarifaire.
 *
 * ── Trois états, et un seul chemin pour y arriver ────────────────────────────
 *
 *  • `off`      — rien n'est vérifié, rien n'est journalisé.
 *  • `monitor`  — défaut. Rien n'est refusé, mais tout appel **sans**
 *                 attestation laisse une trace. Le silence de ces traces est
 *                 la condition pour passer à `enforce` : il dit que tous les
 *                 clients réellement utilisés attestent.
 *  • `enforce`  — un appel sans attestation valide est refusé.
 *
 * ── L'avertissement qui compte ───────────────────────────────────────────────
 *
 * Le client **Windows desktop n'atteste pas**. Le plugin couvre bien la
 * plateforme, mais avec un seul fournisseur — un jeton de *débogage* à inscrire
 * dans la console, c'est-à-dire un secret partagé dans un binaire distribué,
 * que la documentation du plugin dit elle-même de ne pas embarquer en
 * production. Passer en `enforce` prive donc `Release/desktop` de toute fonction
 * d'IA. Et cette limite ne se contourne pas par une exemption de plateforme :
 * la plateforme est déclarée par le client, donc par l'attaquant aussi — une
 * exemption « desktop » serait une porte ouverte à tout le monde. Le choix est
 * binaire et il appartient à l'administrateur ; `monitor` le laisse ouvert aussi
 * longtemps qu'il le faut.
 */

import { getFirestore } from "firebase-admin/firestore";

import { COLL_APP_CONFIG } from "../config";
import { logError } from "../logging";

export const APP_CHECK_POLICY_DOC_ID = "app_check_policy";

export const APP_CHECK_MODES = ["off", "monitor", "enforce"] as const;
export type AppCheckMode = (typeof APP_CHECK_MODES)[number];

export interface AppCheckPolicy {
  mode: AppCheckMode;
}

/**
 * Politique par défaut : observer, ne rien refuser.
 *
 * Un déploiement qui se mettrait à refuser des appels sans que personne l'ait
 * demandé serait une panne, pas une sécurisation.
 */
export const DEFAULT_APP_CHECK_POLICY: AppCheckPolicy = { mode: "monitor" };

export function isAppCheckMode(value: unknown): value is AppCheckMode {
  return typeof value === "string" && (APP_CHECK_MODES as readonly string[]).includes(value);
}

/**
 * Postes exemptés d'attestation, en toutes circonstances.
 *
 * Un interrupteur d'arrêt ne doit pas dépendre de ce qu'il coupe. Ces deux
 * entrées ne font que **lire et écrire le mode** ; les soumettre à
 * l'attestation enferme la clé dans la pièce : le jour où l'attestation refuse
 * à tort — reCAPTCHA en panne, clé expirée, client resté en arrière — plus
 * aucun client ne peut rouvrir, et le mode `enforce` devient définitif.
 *
 * Le risque concédé est mince : les deux postes exigent le rôle administrateur,
 * ne coûtent rien, et n'exposent qu'un mot parmi trois.
 */
export const APP_CHECK_EXEMPT_FEATURES = ["app_check_policy"] as const;

export function isAppCheckExempt(feature: string): boolean {
  return (APP_CHECK_EXEMPT_FEATURES as readonly string[]).includes(feature);
}

/** Ce que la politique décide, en fonction de l'attestation reçue. */
export type AppCheckVerdict =
  /** Rien à faire. */
  | { action: "allow" }
  /** Laisser passer, mais laisser une trace : appel non attesté sous `monitor`. */
  | { action: "observe" }
  /** Refuser. */
  | { action: "deny"; message: string };

const DENY_MESSAGE =
  "Appel refusé : l'application n'a pas pu être attestée. " +
  "Mettez l'application à jour, ou contactez l'administrateur.";

/**
 * Décision pure — c'est elle qui est testée.
 *
 * [attested] vaut `true` quand `req.app` est renseigné, ce qui signifie que le
 * jeton était présent **et** valide : un jeton absent et un jeton invalide se
 * présentent de la même façon, et se traitent donc pareil.
 */
export function appCheckVerdict(
  mode: AppCheckMode,
  attested: boolean,
  feature = "",
): AppCheckVerdict {
  if (attested) return { action: "allow" };
  switch (mode) {
    case "off":
      return { action: "allow" };
    case "monitor":
      return { action: "observe" };
    case "enforce":
      // Le pilotage de la politique reste joignable : sinon `enforce` n'aurait
      // pas de marche arrière. L'appel est tout de même observé — savoir qu'un
      // client non attesté vient changer le mode a de la valeur.
      return isAppCheckExempt(feature)
        ? { action: "observe" }
        : { action: "deny", message: DENY_MESSAGE };
  }
}

let cachedPolicy: { value: AppCheckPolicy; readAt: number } | null = null;
/** Durée de vie du cache mémoire — une bascule prend effet en moins d'une minute. */
const POLICY_TTL_MS = 60_000;

/** Vide le cache — utilisé après une écriture depuis l'écran d'administration. */
export function invalidateAppCheckPolicyCache(): void {
  cachedPolicy = null;
}

export async function getAppCheckPolicy(): Promise<AppCheckPolicy> {
  if (cachedPolicy && Date.now() - cachedPolicy.readAt < POLICY_TTL_MS) {
    return cachedPolicy.value;
  }

  try {
    const snap = await getFirestore()
      .collection(COLL_APP_CONFIG)
      .doc(APP_CHECK_POLICY_DOC_ID)
      .get();

    const data = snap.data() as Record<string, unknown> | undefined;
    const policy: AppCheckPolicy = {
      mode: isAppCheckMode(data?.mode) ? data.mode : DEFAULT_APP_CHECK_POLICY.mode,
    };
    cachedPolicy = { value: policy, readAt: Date.now() };
    return policy;
  } catch (err) {
    // Une politique illisible ne doit pas fermer l'application : refuser tous
    // les appels parce qu'un document ne se lit pas transformerait un incident
    // de lecture en panne totale. On observe, et l'incident reste visible.
    await logError({
      message: "getAppCheckPolicy: lecture impossible, mode « monitor » appliqué",
      errorDescription: err instanceof Error ? err.message : String(err),
    });
    return DEFAULT_APP_CHECK_POLICY;
  }
}
