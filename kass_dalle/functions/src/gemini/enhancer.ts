/**
 * Amélioration d'illustration via le modèle image du projet (Nano Banana 2
 * Lite, voir `GEMINI_IMAGE_MODEL`).
 *
 * Combine en un seul appel :
 *  - détection des coins du sujet et correction de perspective trapézoïdale,
 *  - rééquilibrage exposition / blancs / contraste / saturation, de façon naturelle.
 *
 * Gemini retourne l'image éditée dans `inlineData` d'un `Part` de la première
 * candidate.
 */

import { getStorage } from "firebase-admin/storage";
import { randomUUID } from "crypto";
import sharp from "sharp";
import { logInfo, logError, logWarn } from "../logging";
import { GeminiError, createGenerativeModel, toGeminiResponse } from "./client";
import { recordImageUsage } from "./tokenUsage";
import { GEMINI_IMAGE_MODEL } from "../config";
import { resolveAllowedStoragePath, storageEmulatorActive } from "../utils/storagePath";
import { withDailyBudget } from "../ai/budget";

const ENHANCE_PROMPT =
  "Tu es un retoucheur photo culinaire. Sur cette photo de plat ou de page de recette, fais en une seule passe :\n" +
  "1) Détecte les bords du sujet principal (assiette, plat, page) et corrige la déformation trapézoïdale liée à l'angle de prise de vue. Redresse l'image comme si elle avait été prise de face.\n" +
  "2) RECADRE l'image au plus près du sujet : supprime les marges inutiles (table, arrière-plan vide, doigts, ombres parasites) tout en conservant la totalité du plat ou de la page. Le sujet doit occuper l'essentiel du cadre.\n" +
  "3) PIVOTE l'image dans l'orientation naturelle de lecture : une page de recette doit être à l'endroit (texte lisible debout), un plat doit être présenté droit. Si la photo a été prise de côté ou à l'envers, applique une rotation de 90°, 180° ou 270° pour la remettre dans le bon sens.\n" +
  "4) Améliore l'exposition, l'équilibre des blancs, le contraste et la saturation pour obtenir des couleurs équilibrées et vivantes mais NATURELLES (pas de filtre artistique, pas de teinte excessive).\n" +
  "5) Réduis légèrement le bruit si nécessaire, sans lissage agressif des textures.\n" +
  "Retourne UNIQUEMENT l'image éditée, sans texte.";

export interface EnhanceContext {
  correlationId: string;
  userId: string;
  feature: string;
}

/**
 * Appelle Gemini Image et retourne les bytes JPEG retouchés.
 *
 * Sous plafond, comme les autres postes d'image : l'appel réserve sa place
 * avant de partir (`withDailyBudget`). Il en était exempté, seul poste d'image
 * à l'être.
 */
export async function enhanceCulinaryImage(
  apiKey: string,
  imageBytes: Buffer,
  mimeType: string,
  ctx: EnhanceContext,
): Promise<{ bytes: Buffer; mimeType: string }> {
  return withDailyBudget(ctx.userId, ctx.feature, () =>
    enhanceWithinBudget(apiKey, imageBytes, mimeType, ctx),
  );
}

async function enhanceWithinBudget(
  apiKey: string,
  imageBytes: Buffer,
  mimeType: string,
  ctx: EnhanceContext,
): Promise<{ bytes: Buffer; mimeType: string }> {
  const model = createGenerativeModel(apiKey, GEMINI_IMAGE_MODEL);
  const startedAt = Date.now();

  await logInfo("Gemini image enhance started", {
    correlationId: ctx.correlationId,
    userId: ctx.userId,
    extra: { feature: ctx.feature, inputBytes: imageBytes.length, mimeType },
  });

  try {
    // ── Pré-traitement Sharp : rotation EXIF + normalisation + légère netteté ─
    // Donner à Gemini une image déjà propre améliore la qualité du résultat
    // et réduit les artefacts de compression côté modèle.
    const preprocessed = await sharp(imageBytes)
      .rotate() // applique la rotation EXIF automatiquement
      .normalise() // étire l'histogramme → meilleur contraste
      .sharpen({ sigma: 0.5 }) // légère netteté avant traitement IA
      .jpeg({ quality: 95 })
      .toBuffer();

    const result = toGeminiResponse(
      await model.generateContent({
        contents: [
          {
            role: "user",
            parts: [
              { inlineData: { mimeType: "image/jpeg", data: preprocessed.toString("base64") } },
              { text: ENHANCE_PROMPT },
            ],
          },
        ],
      }),
    );

    const candidates = result.candidates;
    for (const cand of candidates) {
      const parts = cand.content?.parts ?? [];
      for (const part of parts) {
        const inline = (part as { inlineData?: { data?: string; mimeType?: string } }).inlineData;
        if (inline?.data) {
          const elapsed = Date.now() - startedAt;
          await logInfo("Gemini image enhance OK", {
            correlationId: ctx.correlationId,
            userId: ctx.userId,
            executionTimeMs: elapsed,
            geminiStatus: "SUCCESS",
            extra: {
              feature: ctx.feature,
              outputMime: inline.mimeType,
              outputBytes: inline.data.length,
            },
          });
          await recordImageUsage(result, ctx.feature, ctx.userId, {
            correlationId: ctx.correlationId,
          });
          return {
            bytes: Buffer.from(inline.data, "base64"),
            mimeType: inline.mimeType ?? "image/jpeg",
          };
        }
      }
    }

    throw new GeminiError("Gemini n'a pas renvoyé d'image (réponse vide ou refusée).");
  } catch (e) {
    await logError("Gemini image enhance failed", {
      correlationId: ctx.correlationId,
      userId: ctx.userId,
      executionTimeMs: Date.now() - startedAt,
      geminiStatus: "ERROR",
      errorDescription: e instanceof Error ? e.message : String(e),
      extra: { feature: ctx.feature },
    });
    // Journalisée ci-dessus : `logged` évite une seconde ligne dans `toHttpsError`.
    if (e instanceof GeminiError) throw new GeminiError(e.message, e.cause, true);
    throw new GeminiError(e instanceof Error ? e.message : String(e), e, true);
  }
}

// ── Helpers Storage ──────────────────────────────────────────────────────────

/**
 * Télécharge depuis une référence Firebase Storage (chemin, `gs://` ou URL de
 * téléchargement) vers un Buffer.
 *
 * La référence vient d'un client ou d'un champ qu'il peut écrire : seuls les
 * dossiers `allowedPrefixes` sont lisibles. Sinon `StoragePathRefusedError`,
 * avant tout téléchargement.
 */
export async function downloadStorageBytes(
  reference: string,
  allowedPrefixes: readonly string[],
  ctx: { userId?: string; correlationId?: string; feature?: string } = {},
): Promise<Buffer> {
  const bucket = getStorage().bucket();
  let path: string;
  try {
    path = resolveAllowedStoragePath(reference, allowedPrefixes, {
      bucketName: bucket.name,
      allowEmulator: storageEmulatorActive(),
    });
  } catch (err) {
    // Une tentative de lecture hors des dossiers admis (`rejected/…`, la
    // quarantaine d'un autre) laisse une trace, avec le compte qui l'a faite.
    await logWarn({
      message: "Lecture Storage refusée : chemin hors des dossiers admis",
      errorDescription: err instanceof Error ? err.message : String(err),
      userId: ctx.userId,
      correlationId: ctx.correlationId,
      feature: ctx.feature,
      extra: { reference: reference.slice(0, 300), allowedPrefixes },
    });
    throw err;
  }
  const [bytes] = await bucket.file(path).download();
  return bytes;
}

/** Upload l'image améliorée sous illustrations/{uid}/{ts}_enhanced.jpg. */
export async function uploadEnhancedIllustration(
  userId: string,
  bytes: Buffer,
  mimeType: string,
): Promise<string> {
  const ext = mimeType === "image/png" ? "png" : "jpg";
  const path = `illustrations/${userId}/${Date.now()}_enhanced.${ext}`;
  const bucket = getStorage().bucket();
  const file = bucket.file(path);
  const downloadToken = randomUUID();
  await file.save(bytes, {
    contentType: mimeType,
    metadata: {
      cacheControl: "public, max-age=31536000",
      metadata: { firebaseStorageDownloadTokens: downloadToken },
    },
  });
  return (
    `https://firebasestorage.googleapis.com/v0/b/${bucket.name}/o/` +
    `${encodeURIComponent(path)}?alt=media&token=${downloadToken}`
  );
}
