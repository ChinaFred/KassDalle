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
import { requireAdmin, type AuthContext } from "../callable/_auth";
import { readModelChoice } from "./model";
import { detectOrientation } from "./orientation";
import { detectPageQuad } from "./page";
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
  // Trois appels de modèle peuvent s'enchaîner dans une seule requête : la
  // boîte, les coins, et le second essai des coins quand le modèle doute. À
  // soixante secondes chacun, cent vingt ne suffisaient plus — la fonction
  // était tuée en plein travail, et le navigateur ne recevait qu'un
  // « Failed to fetch » sans en-tête ni explication. C'est le plafond des
  // callables de production.
  timeoutSeconds: 300,
  cors: ALLOWED_ORIGINS,
  maxInstances: MAX_CALLABLE_INSTANCES,
};

/** Postes de coût du bac à sable — inscrits au catalogue et au routage. */
const FEATURE_DETECT_PAGE = "sandbox_detect_page";
const FEATURE_DETECT_ORIENTATION = "sandbox_detect_orientation";
const FEATURE_DETECT_REGIONS = "sandbox_detect_regions";

/**
 * Le poste nommé par la garde, selon l'expérience demandée. Il ne sert qu'à la
 * racine du `correlationId` et au journal App Check : l'imputation du coût
 * reste posée par chaque expérience (`ctx.feature`). Une expérience absente ou
 * inconnue est gardée sous le nom générique « sandbox ».
 */
const GUARD_FEATURES: Readonly<Record<string, string>> = {
  "image_import.detect_page": FEATURE_DETECT_PAGE,
  "image_import.detect_orientation": FEATURE_DETECT_ORIENTATION,
  "image_import.detect_regions": FEATURE_DETECT_REGIONS,
};

interface SandboxRequest {
  experiment?: string;
  bytesBase64?: string;
  mimeType?: string;
  widthPx?: number;
  heightPx?: number;

  // Le modèle choisi par l'expérience. Absents, l'appel suit la politique de
  // routage comme n'importe quel poste de l'application.
  provider?: string;
  model?: string;
}

export const sandboxFn = onCall<SandboxRequest>(sandboxOpts, async (req) => {
  const experiment = req.data?.experiment;
  // Une seule garde, avant tout aiguillage : un appel non administrateur est
  // refusé quel que soit `experiment`, absent ou inconnu compris (audit #151,
  // ticket #155). Une expérience ajoutée au `switch` n'a pas à s'en souvenir.
  const guardFeature =
    typeof experiment === "string" && Object.hasOwn(GUARD_FEATURES, experiment)
      ? GUARD_FEATURES[experiment]
      : "sandbox";
  const ctx = await requireAdmin(req, guardFeature);

  if (!experiment) {
    throw new HttpsError("invalid-argument", "experiment est requis.");
  }

  switch (experiment) {
    case "image_import.detect_page":
      return detectPage(req, ctx);
    case "image_import.detect_orientation":
      return detectPageOrientation(req, ctx);
    case "image_import.detect_regions":
      return detectRegions(req, ctx);
    default:
      throw new HttpsError("invalid-argument", `Expérience inconnue : ${experiment}`);
  }
});

async function detectPage(
  req: CallableRequest<SandboxRequest>,
  ctx: AuthContext,
): Promise<{ page: unknown | null }> {
  const { bytesBase64, mimeType, widthPx, heightPx } = req.data ?? {};
  if (!bytesBase64 || !mimeType) {
    throw new HttpsError("invalid-argument", "bytesBase64 et mimeType requis.");
  }

  try {
    const page = await detectPageQuad({
      bytes: Buffer.from(bytesBase64, "base64"),
      mimeType,
      widthPx,
      heightPx,
      ctx: {
        ...ctx,
        feature: FEATURE_DETECT_PAGE,
        moduleType: "DESIGN",
      },
      choice: readModelChoice(req.data),
    });
    return { page };
  } catch (err) {
    if (err instanceof HttpsError) throw err;
    throw new HttpsError("internal", err instanceof Error ? err.message : String(err));
  }
}

async function detectRegions(
  req: CallableRequest<SandboxRequest>,
  ctx: AuthContext,
): Promise<{ regions: unknown[]; engines: unknown[] }> {
  const { bytesBase64, mimeType, widthPx, heightPx } = req.data ?? {};
  if (!bytesBase64 || !mimeType) {
    throw new HttpsError("invalid-argument", "bytesBase64 et mimeType requis.");
  }

  try {
    const result = await detectPageRegions({
      bytes: Buffer.from(bytesBase64, "base64"),
      mimeType,
      widthPx,
      heightPx,
      ctx: {
        ...ctx,
        feature: FEATURE_DETECT_REGIONS,
        moduleType: "DESIGN",
      },
      choice: readModelChoice(req.data),
    });
    return { regions: result.regions, engines: result.engines };
  } catch (err) {
    if (err instanceof HttpsError) throw err;
    throw new HttpsError("internal", err instanceof Error ? err.message : String(err));
  }
}

async function detectPageOrientation(
  req: CallableRequest<SandboxRequest>,
  ctx: AuthContext,
): Promise<{ orientation: unknown | null }> {
  const { bytesBase64, mimeType, widthPx, heightPx } = req.data ?? {};
  if (!bytesBase64 || !mimeType) {
    throw new HttpsError("invalid-argument", "bytesBase64 et mimeType requis.");
  }

  try {
    const orientation = await detectOrientation({
      bytes: Buffer.from(bytesBase64, "base64"),
      mimeType,
      widthPx,
      heightPx,
      ctx: {
        ...ctx,
        feature: FEATURE_DETECT_ORIENTATION,
        moduleType: "DESIGN",
      },
      choice: readModelChoice(req.data),
    });
    return { orientation };
  } catch (err) {
    if (err instanceof HttpsError) throw err;
    throw new HttpsError("internal", err instanceof Error ? err.message : String(err));
  }
}
