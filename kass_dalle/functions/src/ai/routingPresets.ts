/**
 * Lecture d'une politique de routage, et configurations enregistrées.
 *
 * Deux besoins, une seule règle de lecture. La politique en vigueur arrive de
 * l'écran d'administration ; une configuration enregistrée arrive de Firestore,
 * parfois écrite des mois plus tôt. Les deux doivent être jugées contre le même
 * catalogue de postes, sinon une configuration s'enregistre valide et se
 * charge invalide.
 *
 * Ce qui les sépare tient dans un seul réglage, [ReadPolicyOptions.onUnknown] :
 *
 *  - `reject` — ce que fait l'écran. Un poste inconnu refuse la politique
 *    ENTIÈRE : personne ne doit pouvoir écrire un réglage qui ne commandera
 *    rien.
 *  - `drop` — ce que fait la relecture d'une configuration. `ROUTABLE_FEATURES`
 *    perd des postes à chaque version — huit sont déjà partis avec le code qui
 *    les appelait. Une configuration de juillet qui nomme `detect_illustrations`
 *    doit rester chargeable : le poste disparu est écarté et signalé, les
 *    quarante-deux autres arrivent intacts. Refuser le tout laisserait
 *    l'administrateur devant une configuration morte sans savoir pourquoi.
 *
 * Logique pure : ni Firestore, ni réseau, ni `HttpsError`. Le callable traduit
 * [RoutingPolicyError] en erreur transportable.
 */

import { DEFAULT_AI_ROUTING_POLICY, type AiRoutingPolicy } from "./router";
import type { AiProvider } from "./types";

/**
 * Plafond de raisonnement admis, en jetons.
 *
 * Un plafond démesuré ne protégerait de rien : la borne haute vaut celle du
 * modèle, au-delà l'API refuserait l'appel.
 */
export const MAX_THINKING_BUDGET = 24576;

/** Longueur maximale du nom d'une configuration. */
export const PRESET_NAME_MAX_LENGTH = 60;

/**
 * Configuration semée au premier affichage de l'écran.
 *
 * La politique déjà en vigueur au moment où cet écran gagne les configurations
 * est un état réglé à la main, poste par poste. Le perdre au premier essai
 * d'une autre configuration reviendrait à demander de le refaire de mémoire.
 */
export const SEEDED_PRESET_ID = "haute-performance";
export const SEEDED_PRESET_NAME = "Haute performance";

/** Une politique refusée, avec la raison telle qu'elle sera affichée. */
export class RoutingPolicyError extends Error {
  constructor(message: string) {
    super(message);
    this.name = "RoutingPolicyError";
  }
}

/**
 * Ce que le serveur accepte aujourd'hui : les postes, leurs fournisseurs
 * admis, et les modèles Claude de la grille tarifaire.
 *
 * Passé en argument plutôt que lu depuis le callable : c'est ce qui rend la
 * lecture testable sans démarrer une Cloud Function.
 */
export interface RoutingCatalog {
  providers: readonly AiProvider[];
  featureProviders: ReadonlyMap<string, readonly AiProvider[]>;
  models: ReadonlySet<string>;
}

export function buildRoutingCatalog(args: {
  providers: readonly AiProvider[];
  features: ReadonlyArray<{ id: string; providers?: readonly AiProvider[] }>;
  models: ReadonlyArray<{ id: string }>;
}): RoutingCatalog {
  const featureProviders = new Map<string, readonly AiProvider[]>();
  for (const feature of args.features) {
    featureProviders.set(feature.id, feature.providers ?? args.providers);
  }
  return {
    providers: args.providers,
    featureProviders,
    models: new Set(args.models.map((m) => m.id)),
  };
}

export interface ReadPolicyOptions {
  onUnknown: "reject" | "drop";
}

export interface RoutingPolicyReading {
  policy: AiRoutingPolicy;
  /**
   * Ce qui a été écarté, en clair. Toujours vide en mode `reject`, où la
   * première anomalie lève.
   */
  stale: string[];
}

/**
 * Lit une politique proposée et n'en garde que ce que le serveur commande.
 *
 * Un poste absent du résultat n'est pas un poste laissé tel quel : la politique
 * est un remplacement, pas une fusion. Un poste sans valeur explicite est servi
 * par le moteur par défaut.
 */
export function readRoutingPolicy(
  raw: Partial<AiRoutingPolicy> | null | undefined,
  catalog: RoutingCatalog,
  options: ReadPolicyOptions,
): RoutingPolicyReading {
  if (!raw) throw new RoutingPolicyError("policy est requis.");

  const stale: string[] = [];
  const refuse = (message: string): void => {
    if (options.onUnknown === "reject") throw new RoutingPolicyError(message);
    stale.push(message);
  };

  let defaultProvider = raw.defaultProvider ?? DEFAULT_AI_ROUTING_POLICY.defaultProvider;
  if (!catalog.providers.includes(defaultProvider)) {
    refuse(`defaultProvider doit valoir ${catalog.providers.join(" ou ")}.`);
    defaultProvider = DEFAULT_AI_ROUTING_POLICY.defaultProvider;
  }

  const features: Record<string, AiProvider> = {};
  for (const [feature, provider] of Object.entries(raw.features ?? {})) {
    const allowed = catalog.featureProviders.get(feature);
    if (!allowed) {
      refuse(`Poste inconnu : ${feature}.`);
      continue;
    }
    if (!allowed.includes(provider as AiProvider)) {
      refuse(`Fournisseur invalide pour ${feature} : ${provider}.`);
      continue;
    }
    features[feature] = provider as AiProvider;
  }

  // Le modèle par défaut n'est pas contraint à la liste de l'écran : une
  // politique posée à la main peut nommer une révision datée, que la grille
  // tarifaire sait ramener à son préfixe.
  let anthropicModel = (typeof raw.anthropicModel === "string" ? raw.anthropicModel : "").trim();
  if (!anthropicModel) {
    if (raw.anthropicModel !== undefined) refuse("anthropicModel ne peut pas être vide.");
    anthropicModel = DEFAULT_AI_ROUTING_POLICY.anthropicModel;
  }

  // Le modèle par poste, lui, reste dans la liste : un identifiant hors grille
  // se facturerait sans montant et gonflerait `total_unpriced_calls`.
  const anthropicModels: Record<string, string> = {};
  for (const [feature, model] of Object.entries(raw.anthropicModels ?? {})) {
    if (!catalog.featureProviders.has(feature)) {
      refuse(`Poste inconnu : ${feature}.`);
      continue;
    }
    const wanted = typeof model === "string" ? model.trim() : "";
    if (!wanted) continue;
    if (!catalog.models.has(wanted)) {
      refuse(`Modèle Claude inconnu pour ${feature} : ${wanted}.`);
      continue;
    }
    // Un poste réglé sur le modèle par défaut n'a pas besoin d'exception :
    // la garder figerait ce poste le jour où le défaut change.
    if (wanted !== anthropicModel) anthropicModels[feature] = wanted;
  }

  const readBudget = (value: unknown, label: string): number | null => {
    if (value == null) return null;
    const n = Number(value);
    if (!Number.isFinite(n) || n < 0 || n > MAX_THINKING_BUDGET) {
      refuse(
        `Plafond de raisonnement invalide pour ${label} : attendu entre 0 et ${MAX_THINKING_BUDGET}.`,
      );
      return null;
    }
    return Math.trunc(n);
  };

  const thinkingBudget = readBudget(raw.thinkingBudget, "le réglage global");
  const thinkingBudgets: Record<string, number> = {};
  for (const [feature, budget] of Object.entries(raw.thinkingBudgets ?? {})) {
    if (!catalog.featureProviders.has(feature)) {
      refuse(`Poste inconnu : ${feature}.`);
      continue;
    }
    const value = readBudget(budget, feature);
    if (value != null) thinkingBudgets[feature] = value;
  }

  return {
    policy: {
      defaultProvider,
      features,
      anthropicModel,
      anthropicModels,
      fallbackEnabled: raw.fallbackEnabled !== false,
      thinkingBudget,
      thinkingBudgets,
    },
    stale,
  };
}

/**
 * Nom d'une configuration, normalisé.
 *
 * Les espaces multiples sont réduits : « Haute  performance » et « Haute
 * performance » sont le même nom, et deux entrées identiques dans une liste
 * déroulante ne se distinguent plus une fois choisies.
 */
export function normalizePresetName(raw: unknown): string {
  const name = (typeof raw === "string" ? raw : "").trim().replace(/\s+/g, " ");
  if (!name) throw new RoutingPolicyError("Le nom de la configuration est requis.");
  if (name.length > PRESET_NAME_MAX_LENGTH) {
    throw new RoutingPolicyError(
      `Le nom d'une configuration ne dépasse pas ${PRESET_NAME_MAX_LENGTH} caractères.`,
    );
  }
  return name;
}

/** Clé de comparaison d'un nom : c'est elle qui empêche deux homonymes. */
export function presetNameKey(name: string): string {
  return name.toLocaleLowerCase("fr");
}

/** La politique, telle qu'elle s'écrit dans un document de configuration. */
export function presetPolicyToMap(policy: AiRoutingPolicy): Record<string, unknown> {
  return {
    default_provider: policy.defaultProvider,
    features: policy.features,
    anthropic_model: policy.anthropicModel,
    anthropic_models: policy.anthropicModels,
    fallback_enabled: policy.fallbackEnabled,
    thinking_budget: policy.thinkingBudget,
    thinking_budgets: policy.thinkingBudgets,
  };
}

/**
 * Relecture permissive d'un document de configuration.
 *
 * Ne juge rien : elle rend une politique candidate, que [readRoutingPolicy]
 * confronte ensuite au catalogue du jour. Séparer les deux évite d'avoir deux
 * endroits où un poste disparu doit être traité.
 */
export function presetPolicyFromMap(
  raw: Record<string, unknown> | null | undefined,
): Partial<AiRoutingPolicy> {
  const data = raw ?? {};
  const asRecord = (value: unknown): Record<string, never> =>
    value != null && typeof value === "object" ? (value as Record<string, never>) : {};

  return {
    defaultProvider: data.default_provider as AiProvider | undefined,
    features: asRecord(data.features),
    anthropicModel: typeof data.anthropic_model === "string" ? data.anthropic_model : undefined,
    anthropicModels: asRecord(data.anthropic_models),
    fallbackEnabled: data.fallback_enabled !== false,
    thinkingBudget: data.thinking_budget == null ? null : (data.thinking_budget as number),
    thinkingBudgets: asRecord(data.thinking_budgets),
  };
}
