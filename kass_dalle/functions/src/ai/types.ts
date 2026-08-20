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
export type AiProvider = "gemini" | "anthropic" | "vision";

/**
 * Fragment d'entrée, indépendant du fournisseur.
 *
 * Volontairement minimal : c'est le plus petit dénominateur commun entre les
 * deux SDK, et il couvre tout ce que le projet envoie aujourd'hui — du texte,
 * des images pour l'extraction de recettes scannées, et des documents (PDF)
 * pour l'import de fichiers.
 *
 * `image` et `document` sont distingués parce que les deux SDK ne les traitent
 * pas de la même façon : Gemini les passe tous les deux en `inlineData`, Claude
 * exige un bloc `document` pour un PDF et refuse un bloc `image` qui n'en est
 * pas une.
 */
export type ModelPart =
  | { kind: "text"; text: string }
  | { kind: "image"; mimeType: string; dataBase64: string }
  | { kind: "document"; mimeType: string; dataBase64: string };

export function textPart(text: string): ModelPart {
  return { kind: "text", text };
}

export function imagePart(mimeType: string, dataBase64: string): ModelPart {
  return { kind: "image", mimeType, dataBase64 };
}

export function documentPart(mimeType: string, dataBase64: string): ModelPart {
  return { kind: "document", mimeType, dataBase64 };
}

/**
 * Fragment binaire construit depuis des octets, classé d'après son type MIME.
 *
 * Remplace `dataPart` de `gemini/client.ts` pour les postes routés : le reste
 * du backend fabrique ses entrées sans savoir quel moteur les servira.
 */
export function filePart(mimeType: string, bytes: Buffer): ModelPart {
  const kind = mimeType.startsWith("image/") ? "image" : "document";
  return { kind, mimeType, dataBase64: bytes.toString("base64") };
}

/** Consommation d'un appel, telle que le reporting la comptabilise. */
export interface ModelUsage {
  inputTokens: number;
  /** Jetons du texte rendu à l'appelant. */
  outputTokens: number;
  totalTokens: number;
  /**
   * Jetons de raisonnement, facturés au tarif de sortie et invisibles dans la
   * réponse.
   *
   * Gemini 2.5 les compte à part (`thoughtsTokenCount`) et les exclut de
   * `candidatesTokenCount` ; ne lire que ce dernier revient à ignorer la
   * majeure partie de ce que Google facture, puisque le raisonnement dépasse
   * couramment plusieurs fois le texte produit. Claude, lui, les inclut déjà
   * dans ses jetons de sortie : ce champ y reste à zéro, sans quoi ils
   * seraient comptés deux fois.
   */
  thinkingTokens?: number;
  /**
   * Jetons de prompt écrits dans le cache, puis relus depuis le cache.
   *
   * Ce sont des jetons d'**entrée**, et ils ne sont pas dans `inputTokens` :
   * Anthropic n'y met que le reste non mis en cache. Ne lire que `inputTokens`
   * fait donc disparaître du comptage toute la partie mise en cache d'un
   * prompt — sans erreur, sans écran cassé, le coût est simplement plus bas
   * que la facture. Ils se facturent à un autre tarif que l'entrée : 1,25 fois
   * pour l'écriture, un dixième pour la relecture.
   *
   * Le projet ne pose aujourd'hui aucun `cache_control` : ces compteurs
   * devraient rester à zéro. C'est précisément pour le **vérifier** qu'ils sont
   * lus — jusqu'ici, rien ne l'aurait dit s'ils avaient cessé de l'être.
   */
  cacheCreationInputTokens?: number;
  cacheReadInputTokens?: number;
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
  /** Job de pipeline auquel l'appel appartient, quand il y en a un. */
  jobId?: string;
  /** Rang de l'étape dans le pipeline — sert à ordonner les logs d'un import. */
  stepIndex?: number;
  /**
   * Soin que le modèle met à répondre. `low` par défaut.
   *
   * Ce réglage était figé à `low` pour tout le monde, avec une justification qui
   * ne vaut que pour la nutrition : estimer les calories d'un ingrédient est un
   * rappel de connaissances, pas un problème de raisonnement, et les jetons de
   * réflexion se facturent au tarif de sortie.
   *
   * Transcrire une page de livre est l'exact contraire. Il faut suivre une mise
   * en page, rattacher « en poudre » au bon ingrédient, ne pas résumer une
   * énumération en « les épices ». Un modèle pressé fait précisément cela : il
   * rend une phrase élégante et fausse. Le poste choisit donc son soin.
   */
  effort?: "low" | "medium" | "high";
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
