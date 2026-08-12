/**
 * Vocabulaire commun aux fournisseurs d'IA du projet.
 *
 * Le backend a longtemps parlé « Gemini » partout : le type de réponse, le nom
 * des fonctions, la table des tarifs. Tant qu'il n'y avait qu'un moteur, c'était
 * exact. Dès qu'il y en a deux, ce vocabulaire devient un mensonge de nommage —
 * et le premier endroit où un mensonge de nommage coûte cher, c'est le
 * reporting de coûts : un appel Claude facturé au tarif Gemini n'affiche aucune
 * erreur, il affiche un chiffre faux.
 *
 * Ce fichier ne connaît aucun SDK. Il décrit ce qu'on envoie, ce qu'on reçoit,
 * et qui l'a servi.
 */

import type { ModuleType } from "../logging";

/** Fournisseurs d'inférence connus du backend. */
export type AiProvider = "gemini" | "anthropic";

/**
 * Fragment d'entrée, indépendant du fournisseur.
 *
 * Volontairement minimal : c'est le plus petit dénominateur commun entre les
 * deux SDK, et il couvre tout ce que le projet envoie aujourd'hui (du texte,
 * et des images pour l'extraction de recettes scannées).
 */
export type ModelPart =
  | { kind: "text"; text: string }
  | { kind: "image"; mimeType: string; dataBase64: string };

export function textPart(text: string): ModelPart {
  return { kind: "text", text };
}

export function imagePart(mimeType: string, dataBase64: string): ModelPart {
  return { kind: "image", mimeType, dataBase64 };
}

/** Consommation d'un appel, telle que le reporting la comptabilise. */
export interface ModelUsage {
  inputTokens: number;
  outputTokens: number;
  totalTokens: number;
  /** Images générées — seuls les modèles d'image en produisent. */
  imageOutputCount?: number;
}

/**
 * Réponse normalisée d'un appel de modèle.
 *
 * `provider` et `model` sont des champs de premier plan et non des détails :
 * c'est ce que le reporting écrit dans `ai_usage`, et c'est ce qui permet de
 * comparer deux moteurs sur le même poste.
 */
export interface ModelCallResult {
  text: string;
  provider: AiProvider;
  model: string;
  usage: ModelUsage;
  /** Raison d'arrêt telle que rendue par le fournisseur, si elle est connue. */
  stopReason?: string;
}

/** Contexte d'appel : traçabilité, imputation, garde-fous. */
export interface ModelCallContext {
  correlationId: string;
  /** Poste fonctionnel — la clé d'imputation des coûts et de routage. */
  feature: string;
  userId?: string;
  moduleType?: ModuleType;
  timeoutMs?: number;
}

/**
 * Schéma de sortie attendu.
 *
 * Passé au fournisseur quand il sait le faire respecter (Claude le garantit via
 * `output_config.format`). Les fournisseurs qui ne le savent pas l'ignorent : le
 * schéma reste alors une intention, pas une garantie, et l'appelant doit
 * continuer à valider ce qu'il reçoit.
 */
export interface ModelOutputSchema {
  name: string;
  schema: Record<string, unknown>;
}

/** Erreur d'un fournisseur, normalisée pour que le routeur puisse décider. */
export class ModelCallError extends Error {
  constructor(
    message: string,
    public readonly provider: AiProvider,
    public readonly retryable: boolean,
    public readonly cause?: unknown,
  ) {
    super(message);
    this.name = "ModelCallError";
  }
}
