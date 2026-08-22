/**
 * Point d'entrée unique du bac à sable — `sandboxFn`.
 *
 * UNE seule fonction déployée, qui aiguille sur un champ `experiment`. Les
 * expériences suivantes s'ajoutent dans le `switch` : elles ne touchent ni
 * `index.ts`, ni la production, ni la surface HTTPS du projet.
 *
 * Réservé aux administrateurs. Rien n'est écrit : ni Firestore, ni Storage.
 * Seuls les journaux et la comptabilité des jetons gardent une trace, comme
 * pour n'importe quel appel de modèle.
 */

import { onCall, HttpsError, type CallableRequest } from "firebase-functions/v2/https";

import { ANTHROPIC_API_KEY, GEMINI_API_KEY, MAX_CALLABLE_INSTANCES, REGION } from "../config";
import { requireAdmin } from "../callable/_auth";
import { detectPageRegions } from "./regions";

// Copiés de `geminiCallables.ts` : le bac à sable ne dépend pas d'une constante
// privée de la production, qui bougerait sous lui sans qu'on le sache.
const ALLOWED_ORIGINS = [
  "https://kassdale-6d948.web.app",
  "https://kassdale-6d948.firebaseapp.com",
];

const sandboxOpts = {
  region: REGION,
  // Les deux clés : un secret non déclaré n'est pas monté, et le routeur
  // replierait chaque poste routé vers Claude sur Gemini, silencieusement.
  secrets: [GEMINI_API_KEY, ANTHROPIC_API_KEY],
  memory: "512MiB" as const,
  timeoutSeconds: 120,
  cors: ALLOWED_ORIGINS,
  maxInstances: MAX_CALLABLE_INSTANCES,
};

/** Poste de coût du bac à sable — inscrit au catalogue et au routage. */
const FEATURE_DETECT_REGIONS = "sandbox_detect_regions";

interface SandboxRequest {
  experiment?: string;
  bytesBase64?: string;
  mimeType?: string;
  widthPx?: number;
  heightPx?: number;
}

export const sandboxFn = onCall<SandboxRequest>(sandboxOpts, async (req) => {
  const experiment = req.data?.experiment;
  if (!experiment) {
    throw new HttpsError("invalid-argument", "experiment est requis.");
  }

  switch (experiment) {
    case "image_import.detect_regions":
      return detectRegions(req);
    default:
      throw new HttpsError("invalid-argument", `Expérience inconnue : ${experiment}`);
  }
});

async function detectRegions(
  req: CallableRequest<SandboxRequest>,
): Promise<{ regions: unknown[] }> {
  const ctx = await requireAdmin(req, FEATURE_DETECT_REGIONS);
  const { bytesBase64, mimeType, widthPx, heightPx } = req.data ?? {};
  if (!bytesBase64 || !mimeType) {
    throw new HttpsError("invalid-argument", "bytesBase64 et mimeType requis.");
  }

  try {
    const regions = await detectPageRegions({
      bytes: Buffer.from(bytesBase64, "base64"),
      mimeType,
      widthPx,
      heightPx,
      ctx: {
        ...ctx,
        feature: FEATURE_DETECT_REGIONS,
        moduleType: "DESIGN",
      },
    });
    return { regions };
  } catch (err) {
    if (err instanceof HttpsError) throw err;
    throw new HttpsError("internal", err instanceof Error ? err.message : String(err));
  }
}
