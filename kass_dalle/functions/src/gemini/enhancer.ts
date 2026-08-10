/**
 * Amélioration d'illustration via Gemini 2.5 Flash Image.
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
import { logInfo, logError } from "../logging";
import { GeminiError, generateWithModel } from "./client";
import { recordImageUsage } from "./tokenUsage";

const IMAGE_MODEL = "gemini-2.5-flash-image";

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

/** Appelle Gemini Image et retourne les bytes JPEG retouchés. */
export async function enhanceCulinaryImage(
  apiKey: string,
  imageBytes: Buffer,
  mimeType: string,
  ctx: EnhanceContext,
): Promise<{ bytes: Buffer; mimeType: string }> {
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
      .rotate()                          // applique la rotation EXIF automatiquement
      .normalise()                        // étire l'histogramme → meilleur contraste
      .sharpen({ sigma: 0.5 })            // légère netteté avant traitement IA
      .jpeg({ quality: 95 })
      .toBuffer();

    const result = await generateWithModel(apiKey, IMAGE_MODEL, [
      { inlineData: { mimeType: "image/jpeg", data: preprocessed.toString("base64") } },
      { text: ENHANCE_PROMPT },
    ]);

    const candidates = result.candidates;
    for (const cand of candidates) {
      const parts = cand.content?.parts ?? [];
      for (const part of parts) {
        const inline = (
          part as { inlineData?: { data?: string; mimeType?: string } }
        ).inlineData;
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
          await recordImageUsage(result, ctx.feature, ctx.userId);
          return {
            bytes: Buffer.from(inline.data, "base64"),
            mimeType: inline.mimeType ?? "image/jpeg",
          };
        }
      }
    }

    throw new GeminiError(
      "Gemini n'a pas renvoyé d'image (réponse vide ou refusée).",
    );
  } catch (e) {
    await logError("Gemini image enhance failed", {
      correlationId: ctx.correlationId,
      userId: ctx.userId,
      executionTimeMs: Date.now() - startedAt,
      geminiStatus: "ERROR",
      errorDescription: e instanceof Error ? e.message : String(e),
      extra: { feature: ctx.feature },
    });
    if (e instanceof GeminiError) throw e;
    throw new GeminiError(e instanceof Error ? e.message : String(e), e);
  }
}

// ── Helpers Storage ──────────────────────────────────────────────────────────

/** Télécharge depuis une URL Firebase Storage (https ou gs://) vers un Buffer. */
export async function downloadStorageBytes(url: string): Promise<Buffer> {
  const path = extractStoragePath(url);
  const [bytes] = await getStorage().bucket().file(path).download();
  return bytes;
}

function extractStoragePath(url: string): string {
  if (url.startsWith("gs://")) {
    const withoutScheme = url.substring(5);
    const slash = withoutScheme.indexOf("/");
    return withoutScheme.substring(slash + 1);
  }
  const match = url.match(/\/o\/([^?]+)/);
  if (match) return decodeURIComponent(match[1]);
  return url;
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
