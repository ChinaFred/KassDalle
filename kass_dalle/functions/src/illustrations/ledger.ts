/**
 * Le journal d'une extraction d'illustrations : un bloc, une ligne par étape.
 *
 * ## Pourquoi un bloc
 *
 * L'extraction coûte jusqu'à cinq appels de modèle pour une seule page. Écrits
 * séparément, ils se dispersent dans Cloud Logging entre les logs des autres
 * jobs qui tournent en même temps, et plus personne ne sait ce qu'a coûté
 * *cette* page. Les cinq lignes portent donc le même `correlationId`, et un
 * `stepIndex` qui les ordonne : un seul filtre les rassemble, dans l'ordre.
 *
 * La dernière ligne est le **total**. Sans elle, il faudrait additionner à la
 * main cinq montants à quatre décimales pour répondre à « combien a coûté cette
 * page », qui est la seule question qu'on pose vraiment.
 *
 * ## Le montant en euros, et son absence
 *
 * Les grilles tarifaires sont en dollars, la facture est en euros. Le taux vit
 * dans `app_config/currency_rate`, relevé sur la facture Google elle-même.
 *
 * **Quand il manque, on écrit des dollars.** Pas de 0,92 de secours : le projet
 * en a déjà retiré un. Un taux figé appliqué à la place du taux réel donne un
 * montant périmé présenté comme exact — et un chiffre faux, contrairement à un
 * chiffre absent, ne se voit jamais. Même règle pour un modèle absent de la
 * grille : le coût vaut `null`, l'étape est journalisée sans montant, et le
 * total dit combien d'étapes n'ont pas pu être chiffrées.
 */

import { getUsdToEurRate } from "../ai/budget";
import { estimateAiCostUsd, loadAiPricingTable, type AiModelPricing } from "../ai/pricing";
import { logError, logInfo } from "../logging";
import type { ModelCallResult } from "../ai/types";

/** Ce qu'une étape a coûté, et ce qu'elle a rendu. */
export interface IllustrationStep {
  /** Nom court de l'étape, en français, tel qu'il apparaît dans le journal. */
  label: string;
  /** Poste de coût imputé — la même clé que dans le reporting. */
  feature: string;
  provider: string;
  model: string;
  inputTokens: number;
  outputTokens: number;
  /** `null` quand la grille ne connaît pas le modèle : un coût manquant se voit. */
  costUsd: number | null;
  costEur: number | null;
  elapsedMs: number;
  /** Ce que l'étape a conclu, en quelques mots — lu tel quel dans le journal. */
  outcome: string;
}

/**
 * Accumule les étapes d'une extraction et les écrit au fil de l'eau.
 *
 * Au fil de l'eau et non à la fin : une extraction qui échoue au milieu doit
 * laisser derrière elle les étapes déjà facturées. Un journal qui ne s'écrit qu'en
 * cas de succès perd exactement les traces qu'on vient chercher.
 */
export class IllustrationLedger {
  private readonly steps: IllustrationStep[] = [];
  private readonly startedAt = Date.now();
  private table: Record<string, AiModelPricing> | null = null;
  private rate: number | null | undefined = undefined;

  constructor(
    private readonly ctx: {
      correlationId: string;
      /** Scan de l'utilisateur d'où vient ce bloc, quand il en vient un. */
      scanId?: string;
      userId?: string;
      jobId?: string;
      fileName?: string;
    },
  ) {}

  /** Le nombre d'appels de modèle déjà comptés. */
  get callCount(): number {
    return this.steps.length;
  }

  /**
   * Enregistre une étape et l'écrit dans le journal.
   *
   * Le chiffrage est best-effort et ne remonte jamais : une grille tarifaire en
   * panne ne doit pas faire échouer un import. Elle laisse un coût `null`, ce
   * que le total dira.
   */
  async record(args: {
    label: string;
    feature: string;
    result: ModelCallResult;
    elapsedMs: number;
    outcome: string;
  }): Promise<void> {
    const { label, feature, result, elapsedMs, outcome } = args;
    const usage = result.usage;

    let costUsd: number | null = null;
    try {
      const table = await this.pricingTable();
      costUsd = estimateAiCostUsd({
        model: result.model,
        inputTokens: usage.inputTokens,
        outputTokens: usage.outputTokens + (usage.thinkingTokens ?? 0),
        cacheCreationInputTokens: usage.cacheCreationInputTokens ?? 0,
        cacheReadInputTokens: usage.cacheReadInputTokens ?? 0,
        table,
      });
    } catch (err) {
      await logError({
        message: "Illustrations : grille tarifaire illisible, étape comptée sans montant",
        errorDescription: err instanceof Error ? err.message : String(err),
        moduleType: "DESIGN",
        correlationId: this.ctx.correlationId,
        scanId: this.ctx.scanId,
        userId: this.ctx.userId,
        feature,
      });
    }

    const rate = await this.usdToEur();
    const costEur = costUsd != null && rate != null ? costUsd * rate : null;

    const step: IllustrationStep = {
      label,
      feature,
      provider: result.provider,
      model: result.model,
      inputTokens: usage.inputTokens,
      outputTokens: usage.outputTokens + (usage.thinkingTokens ?? 0),
      costUsd,
      costEur,
      elapsedMs,
      outcome,
    };
    this.steps.push(step);

    await logInfo({
      message: `Illustrations · ${this.steps.length}. ${label} · ${formatCost(costEur, costUsd)} · ${outcome}`,
      moduleType: "DESIGN",
      correlationId: this.ctx.correlationId,
      scanId: this.ctx.scanId,
      callId: result.callId,
      userId: this.ctx.userId,
      jobId: this.ctx.jobId,
      feature,
      provider: result.provider,
      model: result.model,
      stepIndex: this.steps.length,
      executionTimeMs: elapsedMs,
      extra: {
        illustrationStep: label,
        costEur,
        costUsd,
        inputTokens: step.inputTokens,
        outputTokens: step.outputTokens,
        outcome,
      },
    });
  }

  /**
   * Écrit la ligne de clôture : le total du bloc.
   *
   * `stepIndex` vaut zéro, et c'est délibéré : la ligne de total se trie donc
   * en tête du bloc, où on la cherche.
   */
  async close(args: { outcome: string; illustrations: number }): Promise<void> {
    const priced = this.steps.filter((s) => s.costEur != null || s.costUsd != null);
    const unpriced = this.steps.length - priced.length;

    const totalEur = this.steps.every((s) => s.costEur != null)
      ? this.steps.reduce((sum, s) => sum + (s.costEur ?? 0), 0)
      : null;
    const totalUsd = this.steps.every((s) => s.costUsd != null)
      ? this.steps.reduce((sum, s) => sum + (s.costUsd ?? 0), 0)
      : null;

    const elapsedMs = Date.now() - this.startedAt;
    const manquants = unpriced > 0 ? ` · ${unpriced} étape(s) sans montant` : "";

    await logInfo({
      message:
        `Illustrations · TOTAL ${formatCost(totalEur, totalUsd)} · ` +
        `${args.illustrations} illustration(s) · ${this.steps.length} appel(s) · ` +
        `${(elapsedMs / 1000).toFixed(1)} s · ${args.outcome}${manquants}`,
      moduleType: "DESIGN",
      correlationId: this.ctx.correlationId,
      scanId: this.ctx.scanId,
      userId: this.ctx.userId,
      jobId: this.ctx.jobId,
      feature: "page_illustrations",
      stepIndex: 0,
      executionTimeMs: elapsedMs,
      extra: {
        illustrationBlock: true,
        fileName: this.ctx.fileName,
        totalCostEur: totalEur,
        totalCostUsd: totalUsd,
        unpricedSteps: unpriced,
        illustrations: args.illustrations,
        outcome: args.outcome,
        steps: this.steps.map((s) => ({
          label: s.label,
          feature: s.feature,
          provider: s.provider,
          model: s.model,
          costEur: s.costEur,
          costUsd: s.costUsd,
          elapsedMs: s.elapsedMs,
          outcome: s.outcome,
        })),
      },
    });
  }

  private async pricingTable(): Promise<Record<string, AiModelPricing>> {
    if (!this.table) this.table = await loadAiPricingTable();
    return this.table;
  }

  private async usdToEur(): Promise<number | null> {
    if (this.rate === undefined) this.rate = await getUsdToEurRate();
    return this.rate;
  }
}

/**
 * Le montant, en euros quand on sait le convertir, en dollars sinon.
 *
 * Jamais « 0,0000 € » à la place d'un coût inconnu : zéro est un montant, et
 * l'afficher pour dire « je ne sais pas » est le mensonge que ce module
 * s'interdit.
 */
export function formatCost(eur: number | null, usd: number | null): string {
  if (eur != null) return `${eur.toFixed(4).replace(".", ",")} €`;
  if (usd != null) return `${usd.toFixed(4)} $ (taux de change inconnu)`;
  return "montant inconnu";
}
