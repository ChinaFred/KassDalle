/**
 * Génération d'image culinaire via le modèle image du projet (Nano Banana 2
 * Lite, voir `GEMINI_IMAGE_MODEL`).
 *
 * Utilisée pour créer une image photo-réaliste à partir d'une description
 * de plat / recette, puis l'archiver dans Firebase Storage.
 */

import { getStorage } from "firebase-admin/storage";
import { randomUUID } from "crypto";
import { logError, logInfo } from "../logging";
import { GeminiError, createGenerativeModel, toGeminiResponse } from "./client";
import { recordImageUsage } from "./tokenUsage";
import { assertWithinDailyBudget } from "../ai/budget";
import { GEMINI_IMAGE_MODEL } from "../config";

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
  /**
   * Visuel déjà produit pour une étape antérieure.
   *
   * Quand il existe, l'image n'est pas refabriquée : elle est complétée. Deux
   * générations indépendantes du même dressage donnent deux assiettes
   * différentes — cadrage, teinte, forme des éléments — et la séquence cesse
   * de raconter un montage.
   */
  baseImage?: { bytes: Buffer; mimeType: string } | null;
}

/**
 * Consignes de matière.
 *
 * Sans elles, le modèle peint toutes les sauces en liquide clair : une
 * anchoïade montée à l'huile est ressortie en bouillon. La consistance est
 * décrite en amont par le coach, encore faut-il exiger ici qu'elle soit tenue.
 */
const TEXTURE_RULES = [
  "- RESPECTE À LA LETTRE les consistances décrites : une sauce montée ou émulsionnée",
  "  est une masse épaisse, brillante, qui tient au ruban et garde sa forme — jamais",
  "  un liquide clair, jamais un bouillon, jamais une flaque translucide",
  "- une purée reste dense et mate, un jus réduit nappe sans s'étaler, un croustillant",
  "  reste irrégulier et sec : la matière doit se lire au premier regard",
];

/**
 * Confinement au contenant.
 *
 * Le modèle sort spontanément de l'assiette : il pose la sauce dans une
 * coupelle à côté, ajoute une planche, déborde sur la table. Un guide de
 * dressage montre ce qu'il y a DANS l'assiette — le reste est du décor de
 * magazine, et il ment sur le geste à reproduire.
 */
const CONTAINER_RULES = [
  "- TOUS les éléments sont DANS le contenant décrit, sans exception : rien sur la",
  "  table, rien sur le bord, rien à côté",
  "- n'ajoute AUCUN contenant supplémentaire : pas de coupelle, pas de ramequin,",
  "  pas de bol de sauce, pas de planche, pas de second plat — un seul contenant",
  "- une sauce d'accompagnement se pose en touche dans le contenant, jamais à part",
  "- aucun couvert, aucun linge, aucun ingrédient cru en décor autour",
];

const COMMON_PLATING_RULES = [
  "- vue de dessus ou trois quarts haut, contenant entier et centré dans le cadre",
  "- fond neutre uni, lumière diffuse, aucune ombre dure, aucun accessoire",
  "- rendu photo-réaliste et net, lecture immédiate des positions et des volumes",
  "- pas de texte, pas de flèche, pas de watermark, pas de personne, pas de mains",
];

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
  const editing = input.baseImage != null;

  return [
    editing
      ? "L'image fournie montre cette assiette à l'étape précédente du montage. COMPLÈTE-LA."
      : "Tu illustres une étape de MONTAGE d'une assiette, pour un guide de dressage.",
    `Plat: ${input.recipeTitle.trim()}`,
    input.contenant?.trim() ? `Contenant: ${input.contenant.trim()}` : "",
    `Étape illustrée: ${input.stepTitle.trim()}`,
    `Geste en cours: ${input.stepGeste.trim()}`,
    done.length
      ? `Déjà en place dans l'assiette: ${done.join(" ; ")}`
      : "L'assiette est vide avant ce geste.",
    `Ce qu'il faut voir: ${input.visualPrompt.trim()}`,
    "Contraintes visuelles:",
    ...(editing
      ? [
          "- CONSERVE l'image fournie : même assiette, même cadrage, même angle, même",
          "  lumière, mêmes couleurs, et surtout mêmes éléments déjà posés, inchangés",
          "  de forme et de position",
          "- ajoute UNIQUEMENT ce que décrit le geste en cours, rien d'autre : aucun",
          "  objet, aucun contenant, aucune garniture qui ne serait pas demandé",
        ]
      : [
          "- l'assiette est SAISIE EN COURS DE MONTAGE, le plat n'est pas terminé",
          "- ne montre que les éléments déjà posés à cette étape, rien de plus",
        ]),
    ...CONTAINER_RULES,
    ...TEXTURE_RULES,
    ...COMMON_PLATING_RULES,
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
  return runImageModel(
    apiKey,
    buildPlatingPrompt(input),
    input.recipeTitle,
    ctx,
    input.baseImage ?? null,
  );
}

async function runImageModel(
  apiKey: string,
  prompt: string,
  recipeTitle: string,
  ctx: GenerateImageContext,
  baseImage: { bytes: Buffer; mimeType: string } | null = null,
): Promise<{ bytes: Buffer; mimeType: string }> {
  // Point de passage unique des trois postes qui produisent une image — les
  // plus chers du catalogue, 0,0336 $ l'unité. Le plafond s'y applique comme
  // au texte ; l'image ne passe pas par `callModel`, elle serait sinon la
  // seule dépense non bornée.
  await assertWithinDailyBudget(ctx.userId, ctx.feature);

  const model = createGenerativeModel(apiKey, GEMINI_IMAGE_MODEL);
  const startedAt = Date.now();

  // `feature` au premier niveau, et non dans `extra` : c'est ce champ que
  // l'écran de logs lit pour nommer un traitement et pour filtrer.
  await logInfo("Gemini image generate started", {
    correlationId: ctx.correlationId,
    userId: ctx.userId,
    feature: ctx.feature,
    extra: {
      recipeTitle,
      promptLength: prompt.length,
      editsBaseImage: baseImage != null,
    },
  });

  try {
    // L'image de départ passe avant le texte : c'est l'ordre attendu pour une
    // édition, le prompt décrivant alors ce qu'il faut lui ajouter.
    const parts = baseImage
      ? [
          {
            inlineData: {
              mimeType: baseImage.mimeType,
              data: baseImage.bytes.toString("base64"),
            },
          },
          { text: prompt },
        ]
      : [{ text: prompt }];

    const result = toGeminiResponse(
      await model.generateContent({
        contents: [{ role: "user", parts }],
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
            feature: ctx.feature,
            extra: {
              outputMime: inline.mimeType,
              outputBytes: inline.data.length,
            },
          });
          // Sans le correlationId, la ligne de consommation ne se rattache à
          // aucun traitement : elle apparaît « hors traitement » dans l'écran
          // de logs, à côté de l'appel qui l'a pourtant provoquée.
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
    await logError("Gemini image generate failed", {
      correlationId: ctx.correlationId,
      userId: ctx.userId,
      executionTimeMs: Date.now() - startedAt,
      geminiStatus: "ERROR",
      errorDescription: e instanceof Error ? e.message : String(e),
      feature: ctx.feature,
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
