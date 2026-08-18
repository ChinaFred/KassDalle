/**
 * Adaptateur Google Cloud Vision — SafeSearch + labels.
 *
 * **Seul fichier autorisé à importer le SDK Vision**, comme `gemini/client.ts`
 * et `ai/anthropic.ts` le sont pour leur fournisseur. La projection des paliers
 * de Vision sur l'échelle neutre `0..1` vit ici et nulle part ailleurs : c'est
 * la seule façon de changer de moteur sans toucher aux règles.
 */

import { ImageAnnotatorClient } from "@google-cloud/vision";

import type { ModerationLabel, ModerationSignals } from "./decision";

/**
 * Paliers de Vision, projetés sur `0..1`.
 *
 * `UNKNOWN` rend `null`, jamais `0`. Un critère que le moteur n'a pas su lire
 * n'est pas un critère rassurant : le confondre avec « très peu probable »
 * ferait approuver sur une ignorance.
 */
const LIKELIHOOD_SCALE: Record<string, number | null> = {
  VERY_UNLIKELY: 0,
  UNLIKELY: 0.25,
  POSSIBLE: 0.5,
  LIKELY: 0.75,
  VERY_LIKELY: 1,
  UNKNOWN: null,
};

/** Identifiant de modèle utilisé pour la tarification et le reporting. */
export const VISION_MODEL_ID = "cloud-vision-safesearch";

/**
 * Unités facturées par image : SafeSearch et Label sont deux requêtes de
 * fonctionnalité, donc deux unités. C'est le nombre d'unités, pas d'images, qui
 * est enregistré — sans quoi le coût serait divisé par deux.
 */
export const VISION_UNITS_PER_IMAGE = 2;

export function likelihoodToScore(value: string | number | null | undefined): number | null {
  if (value === null || value === undefined) return null;
  const key = typeof value === "number" ? numericLikelihood(value) : String(value).toUpperCase();
  if (key === null) return null;
  return key in LIKELIHOOD_SCALE ? LIKELIHOOD_SCALE[key] : null;
}

/**
 * Le SDK peut rendre l'énumération sous forme d'entier selon la version et le
 * transport. Les deux formes se lisent, sinon un déploiement de bibliothèque
 * transformerait silencieusement tous les verdicts en « illisible ».
 */
function numericLikelihood(value: number): string | null {
  const names = ["UNKNOWN", "VERY_UNLIKELY", "UNLIKELY", "POSSIBLE", "LIKELY", "VERY_LIKELY"];
  return names[value] ?? null;
}

/** Forme brute d'une annotation SafeSearch, tolérante aux variantes du SDK. */
export interface RawSafeSearch {
  adult?: string | number | null;
  violence?: string | number | null;
  racy?: string | number | null;
  medical?: string | number | null;
  spoof?: string | number | null;
}

export interface RawLabel {
  description?: string | null;
  score?: number | null;
}

/**
 * Projette une réponse Vision sur la forme neutre.
 *
 * Exporté pour être testé sans réseau : la projection est la seule partie de
 * l'adaptateur qui puisse se tromper en silence.
 */
export function toModerationSignals(
  safeSearch: RawSafeSearch | null | undefined,
  labels: RawLabel[] | null | undefined,
): ModerationSignals {
  const safe = safeSearch ?? {};
  const raw: Record<string, string> = {};
  for (const key of ["adult", "violence", "racy", "medical", "spoof"] as const) {
    const value = safe[key];
    if (value === null || value === undefined) continue;
    raw[key] = typeof value === "number" ? (numericLikelihood(value) ?? "UNKNOWN") : String(value);
  }

  // Le contenu suggestif compte dans le critère sexuel, mais moins que
  // l'explicite : on retient le plus élevé des deux, sans quoi une image
  // marquée « racy » et non « adult » ne pèserait rien.
  const adult = likelihoodToScore(safe.adult);
  const racy = likelihoodToScore(safe.racy);
  const sexual = adult === null && racy === null ? null : Math.max(adult ?? 0, racy ?? 0);

  const cleanLabels: ModerationLabel[] = (labels ?? [])
    .map((l) => ({ name: (l.description ?? "").trim(), score: Number(l.score ?? 0) }))
    .filter((l) => l.name.length > 0 && Number.isFinite(l.score));

  return {
    sexual,
    violence: likelihoodToScore(safe.violence),
    medical: likelihoodToScore(safe.medical),
    raw,
    labels: cleanLabels,
  };
}

let client: ImageAnnotatorClient | null = null;

function visionClient(): ImageAnnotatorClient {
  if (client === null) client = new ImageAnnotatorClient();
  return client;
}

/**
 * Analyse une image et rend les signaux neutres.
 *
 * Lève en cas d'échec : l'appelant en fait un état `pending`. Rendre des
 * signaux vides serait un repli — une image publiée sur une panne.
 */
export async function analyseWithVision(bytes: Buffer): Promise<ModerationSignals> {
  const [result] = await visionClient().annotateImage({
    image: { content: bytes },
    features: [{ type: "SAFE_SEARCH_DETECTION" }, { type: "LABEL_DETECTION", maxResults: 20 }],
  });

  if (result.error?.message) {
    throw new Error(`Cloud Vision: ${result.error.message}`);
  }

  return toModerationSignals(
    result.safeSearchAnnotation as RawSafeSearch | null,
    (result.labelAnnotations ?? []) as RawLabel[],
  );
}

/** Remet le client à zéro — réservé aux tests. */
export function resetVisionClient(): void {
  client = null;
}
