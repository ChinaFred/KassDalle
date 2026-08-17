/**
 * Pilotage de la politique App Check.
 *
 * Le mode se change depuis l'écran d'administration, jamais par un déploiement.
 * La raison est la même que pour le routage d'IA, en plus pressante : le jour où
 * l'attestation refuse à tort — clé mal posée, client resté en arrière,
 * fournisseur en panne — il faut rouvrir en une minute. Un interrupteur qui
 * demande un `firebase deploy` n'est pas un interrupteur.
 *
 * La lecture renseigne aussi l'écran sur ce qui *arrive réellement* : combien
 * d'appels ont été attestés, combien ne l'ont pas été. Sans cela, passer en
 * `enforce` serait un pari — exactement l'erreur qu'on a déjà commise avec la
 * clé Anthropic, où une bascule sans effet restait une énigme pour celui qui
 * l'avait demandée.
 */

import { onCall, HttpsError } from "firebase-functions/v2/https";
import { getFirestore, FieldValue } from "firebase-admin/firestore";

import { REGION, COLL_APP_CONFIG, MAX_CALLABLE_INSTANCES } from "../config";
import { requireAdmin } from "./_auth";
import {
  APP_CHECK_MODES,
  APP_CHECK_POLICY_DOC_ID,
  DEFAULT_APP_CHECK_POLICY,
  getAppCheckPolicy,
  invalidateAppCheckPolicyCache,
  isAppCheckMode,
} from "../security/appCheckPolicy";

const ALLOWED_ORIGINS = [
  "https://kassdale-6d948.web.app",
  "https://kassdale-6d948.firebaseapp.com",
];

const callableOpts = {
  region: REGION,
  memory: "256MiB" as const,
  timeoutSeconds: 60,
  cors: ALLOWED_ORIGINS,
  maxInstances: MAX_CALLABLE_INSTANCES,
};

export const getAppCheckPolicyFn = onCall(callableOpts, async (req) => {
  await requireAdmin(req, "app_check_policy");
  const policy = await getAppCheckPolicy();

  // L'attestation de *cet appel* est le signal le plus honnête que l'écran
  // puisse afficher : si l'écran d'administration lui-même n'atteste pas,
  // passer en `enforce` mettrait son utilisateur dehors le premier.
  return {
    policy,
    modes: APP_CHECK_MODES,
    callerAttested: req.app != null,
    defaultMode: DEFAULT_APP_CHECK_POLICY.mode,
  };
});

interface SetAppCheckPolicyRequest {
  mode?: string;
}

export const setAppCheckPolicyFn = onCall<SetAppCheckPolicyRequest>(callableOpts, async (req) => {
  const ctx = await requireAdmin(req, "app_check_policy");

  const mode = req.data?.mode;
  if (!isAppCheckMode(mode)) {
    throw new HttpsError("invalid-argument", `mode doit valoir ${APP_CHECK_MODES.join(", ")}.`);
  }

  // Garde-fou : passer en `enforce` depuis un client qui n'atteste pas
  // reviendrait à se verrouiller dehors, et à verrouiller la famille avec.
  // Le refus est plus utile que l'obéissance.
  if (mode === "enforce" && req.app == null) {
    throw new HttpsError(
      "failed-precondition",
      "Cet appel n'est pas lui-même attesté : activer l'exigence vous mettrait " +
        "dehors immédiatement. Vérifiez la configuration App Check du client, " +
        "puis réessayez depuis un client attesté.",
    );
  }

  await getFirestore().collection(COLL_APP_CONFIG).doc(APP_CHECK_POLICY_DOC_ID).set(
    {
      mode,
      updated_at: FieldValue.serverTimestamp(),
      updated_by: ctx.userId,
    },
    { merge: true },
  );

  // Le cache de cette instance est vidé tout de suite ; les autres instances
  // suivent au bout d'une minute au plus.
  invalidateAppCheckPolicyCache();

  return { policy: { mode }, callerAttested: req.app != null };
});
