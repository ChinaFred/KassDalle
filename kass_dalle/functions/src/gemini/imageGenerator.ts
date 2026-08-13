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

export interface GeneratePlatingImageInput {
  recipeTitle: string;
  /** Titre court de l'étape de montage, ex. « Le lit de poireaux fondus ». */
  stepTitle: string;
  /** Le geste décrit par le coach de dressage. */
  stepGeste: string;
  /** Description visuelle produite par le coach pour cette étape. */
  visualPrompt: string;
  /** Contenant conseillé, pour que l'assiette dessinée soit la bonne. */
  contenant?: string | null;
  /** Étapes déjà réalisées — ce qui doit déjà être dans l'assiette. */
  previousSteps?: string[];
}

/**
 * Prompt d'un visuel de montage — volontairement distinct du prompt photo.
 *
 * La photo de plat fini montre le résultat ; elle n'apprend pas à le construire.
 * Ici on demande l'assiette arrêtée en cours de montage, ce qui suppose de dire
 * explicitement au modèle que le plat n'est PAS terminé — sans cette consigne,
 * il livre systématiquement une image de magazine.
 */
function buildPlatingPrompt(input: GeneratePlatingImageInput): string {
  const done = (input.previousSteps ?? []).filter((s) => s.trim().length > 0);

  return [
    "Tu illustres une étape de MONTAGE d'une assiette, pour un guide de dressage.",
    `Plat: ${input.recipeTitle.trim()}`,
    input.contenant?.trim() ? `Contenant: ${input.contenant.trim()}` : "",
    `Étape illustrée: ${input.stepTitle.trim()}`,
    `Geste en cours: ${input.stepGeste.trim()}`,
    done.length
      ? `Déjà en place dans l'assiette: ${done.join(" ; ")}`
      : "L'assiette est vide avant ce geste.",
    `Ce qu'il faut voir: ${input.visualPrompt.trim()}`,
    "Contraintes visuelles:",
    "- l'assiette est SAISIE EN COURS DE MONTAGE, le plat n'est pas terminé",
    "- ne montre que les éléments déjà posés à cette étape, rien de plus",
    "- vue de dessus ou trois quarts haut, assiette entière et centrée",
    "- fond neutre uni, lumière diffuse, aucune ombre dure, aucun accessoire",
    "- rendu photo-réaliste et net, lecture immédiate des positions et des volumes",
    "- pas de texte, pas de flèche, pas de watermark, pas de personne, pas de mains",
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
  return runImageModel(apiKey, buildPrompt(input), input.recipeTitle, ctx);
}

/** Visuel d'une étape de montage, pour le coach de dressage. */
export async function generatePlatingStepImage(
  apiKey: string,
  input: GeneratePlatingImageInput,
  ctx: GenerateImageContext,
): Promise<{ bytes: Buffer; mimeType: string }> {
  return runImageModel(apiKey, buildPlatingPrompt(input), input.recipeTitle, ctx);
}

async function runImageModel(
  apiKey: string,
  prompt: string,
  recipeTitle: string,
  ctx: GenerateImageContext,
): Promise<{ bytes: Buffer; mimeType: string }> {
  const model = createGenerativeModel(apiKey, IMAGE_MODEL);
  const startedAt = Date.now();

  await logInfo("Gemini image generate started", {
    correlationId: ctx.correlationId,
    userId: ctx.userId,
    extra: {
      feature: ctx.feature,
      recipeTitle,
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
        const inline = (part as { inlineData?: { data?: string; mimeType?: string } }).inlineData;
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

    throw new GeminiError("Gemini n'a pas renvoyé d'image (réponse vide ou refusée).");
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
  /** Suffixe de nom de fichier — distingue une illustration d'un visuel de dressage. */
  kind = "generated",
): Promise<string> {
  const ext = mimeType === "image/png" ? "png" : mimeType === "image/webp" ? "webp" : "jpg";
  const path = `illustrations/${userId}/${Date.now()}_${kind}.${ext}`;
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
