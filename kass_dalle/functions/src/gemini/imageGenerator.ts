/**
 * Génération d'image culinaire via Gemini 2.5 Flash Image.
 *
 * Utilisée pour créer une image photo-réaliste à partir d'une description
 * de plat / recette, puis l'archiver dans Firebase Storage.
 */

import { getStorage } from "firebase-admin/storage";
import { randomUUID } from "crypto";
import { logError, logInfo } from "../logging";
import { GeminiError, createGenerativeModel, toGeminiResponse } from "./client";
import { recordImageUsage } from "./tokenUsage";

const IMAGE_MODEL = "gemini-2.5-flash-image";

export interface GenerateCulinaryImageInput {
  recipeTitle: string;
  recipeContext: string;
  userInstruction?: string | null;
  style?: string | null;
}

export interface GenerateImageContext {
  correlationId: string;
  userId: string;
  feature: string;
}

function buildPrompt(input: GenerateCulinaryImageInput): string {
  const instruction = input.userInstruction?.trim();
  const style = input.style?.trim() || "photo réaliste";

  return [
    "Tu es un directeur artistique culinaire. Génère une image du plat suivant.",
    `Plat principal: ${input.recipeTitle.trim()}`,
    input.recipeContext.trim() ? `Contexte recette: ${input.recipeContext.trim()}` : "",
    instruction ? `Consigne de l'utilisateur: ${instruction}` : "",
    `Style attendu: ${style}.`,
    "Contraintes visuelles:",
    "- image photo-réaliste, appetissante et naturelle, pas une illustration ni un dessin",
    "- dressage soigneux, lisible et inspirant, comme une photo de restaurant",
    "- les elements essentiels de l'assiette ou du plat doivent etre bien visibles et identifiables",
    "- lumiere naturelle ou douce, fond sobre, profondeur de champ legere",
    "- pas de texte, pas de watermark, pas de personne, pas de mains, pas d'objets parasites",
    "- cadrage suffisamment large pour comprendre la composition, tout en restant centré sur le plat",
    "Retourne uniquement l'image.",
  ]
    .filter(Boolean)
    .join("\n");
}

export async function generateCulinaryImage(
  apiKey: string,
  input: GenerateCulinaryImageInput,
  ctx: GenerateImageContext,
): Promise<{ bytes: Buffer; mimeType: string }> {
  const model = createGenerativeModel(apiKey, IMAGE_MODEL);
  const startedAt = Date.now();
  const prompt = buildPrompt(input);

  await logInfo("Gemini image generate started", {
    correlationId: ctx.correlationId,
    userId: ctx.userId,
    extra: {
      feature: ctx.feature,
      recipeTitle: input.recipeTitle,
      promptLength: prompt.length,
    },
  });

  try {
    const result = toGeminiResponse(
      await model.generateContent({
        contents: [
          {
            role: "user",
            parts: [{ text: prompt }],
          },
        ],
      }),
    );

    const candidates = result.candidates;
    for (const cand of candidates) {
      const parts = cand.content?.parts ?? [];
      for (const part of parts) {
        const inline = (
          part as { inlineData?: { data?: string; mimeType?: string } }
        ).inlineData;
        if (inline?.data) {
          const elapsed = Date.now() - startedAt;
          await logInfo("Gemini image generate OK", {
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
    await logError("Gemini image generate failed", {
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

export async function uploadGeneratedIllustration(
  userId: string,
  bytes: Buffer,
  mimeType: string,
): Promise<string> {
  const ext = mimeType === "image/png" ? "png" : mimeType === "image/webp" ? "webp" : "jpg";
  const path = `illustrations/${userId}/${Date.now()}_generated.${ext}`;
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