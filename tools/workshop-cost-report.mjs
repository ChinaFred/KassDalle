#!/usr/bin/env node
// Relevé des coûts de l'Atelier repas, en lecture seule.
//
// Usage, depuis la racine du dépôt :
//   node tools/workshop-cost-report.mjs [--since AAAA-MM-JJ] [--sandbox]
//
// Lit les lignes `ai_usage` des postes `meal_workshop_turn` et
// `meal_workshop_recipe` du projet `kassdale-6d948` (et
// `sandbox_meal_workshop_turn` avec `--sandbox`), puis écrit sur la sortie
// standard un relevé Markdown prêt à coller dans
// `documentation/ToDo/SPEC-atelier-repas.md` (§3, « Mesures en production »).
//
// Prérequis : le CLI Firebase installé globalement et connecté
// (`firebase login`). Le script échange le jeton de rafraîchissement du CLI
// contre un jeton d'accès, avec le client OAuth du paquet firebase-tools
// installé. Aucun identifiant n'est écrit dans ce fichier. Surcharges :
// `FIREBASE_CLIENT_ID` et `FIREBASE_CLIENT_SECRET` (les deux), `FIREBASE_TOOLS_DIR`
// (dossier du paquet firebase-tools), `FIREBASE_TOOLS_CONFIG` (fichier de
// configuration du CLI).
//
// Lecture seule : seules des requêtes `documents:runQuery` partent. Rien ne
// s'écrit dans Firestore.
//
// Aucune donnée privée en sortie : la requête ne lit que les champs listés
// dans `SELECTED_FIELDS` (ni `uid`, ni texte). `entity_id` (l'identifiant de
// conversation) sert à regrouper les tours ; il n'est jamais affiché. Le
// relevé se colle dans un dépôt public : il ne donne que des jours et des
// durées, jamais l'heure d'un tour.
//
// Une erreur s'écrit sur la sortie d'erreur avec son contexte, et le script
// sort avec le code 1.
import { execSync } from 'node:child_process';
import { existsSync, readFileSync } from 'node:fs';
import { createRequire } from 'node:module';
import { homedir } from 'node:os';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

export const PROJECT_ID = 'kassdale-6d948';
export const TURN_FEATURE = 'meal_workshop_turn';
export const RECIPE_FEATURE = 'meal_workshop_recipe';
export const SANDBOX_TURN_FEATURE = 'sandbox_meal_workshop_turn';
/** `entity_type` des lignes des deux postes (`MEAL_WORKSHOP_ENTITY_TYPE`). */
export const WORKSHOP_ENTITY_TYPE = 'meal_workshop';
/** Écart au-delà duquel un cache d'une heure n'aurait pas été relu. */
export const ONE_HOUR_MS = 60 * 60 * 1000;
/** Durée du cache par défaut d'Anthropic. */
export const FIVE_MINUTES_MS = 5 * 60 * 1000;

const PAGE_SIZE = 500;
const TOKEN_URL = 'https://oauth2.googleapis.com/token';
const RUN_QUERY_URL = `https://firestore.googleapis.com/v1/projects/${PROJECT_ID}/databases/(default)/documents:runQuery`;

/** Champs lus sur chaque ligne `ai_usage`. `uid` n'en fait pas partie. */
export const SELECTED_FIELDS = [
  'feature',
  'provider',
  'model',
  'timestamp',
  'estimated_cost_usd',
  'pricing_unavailable',
  'input_tokens',
  'output_tokens',
  'thinking_tokens',
  'cache_creation_input_tokens',
  'cache_read_input_tokens',
  'status',
  'entity_type',
  'entity_id',
];

// ── Lecture d'une ligne ─────────────────────────────────────────────────────

/** Valeur d'un champ Firestore REST, ou `null` si absente ou d'un autre type. */
export function decodeValue(field) {
  if (field == null || typeof field !== 'object') return null;
  if ('integerValue' in field) {
    const n = Number(field.integerValue);
    return Number.isFinite(n) ? n : null;
  }
  if ('doubleValue' in field) {
    const n = Number(field.doubleValue);
    return Number.isFinite(n) ? n : null;
  }
  if ('stringValue' in field) return field.stringValue;
  if ('timestampValue' in field) return field.timestampValue;
  if ('booleanValue' in field) return field.booleanValue;
  return null;
}

function numberOrNull(value) {
  return typeof value === 'number' && Number.isFinite(value) ? value : null;
}

function stringOrNull(value) {
  return typeof value === 'string' && value.trim() !== '' ? value : null;
}

/**
 * Une ligne `ai_usage` lue depuis le document REST. Un champ absent ou mal
 * typé (ligne historique) devient `null` ; la ligne reste comptée.
 */
export function decodeRow(document) {
  const f = document?.fields ?? {};
  const read = (name) => decodeValue(f[name]);
  const timestamp = stringOrNull(read('timestamp'));
  const timeMs = timestamp == null ? null : Date.parse(timestamp);
  const entityType = stringOrNull(read('entity_type'));
  return {
    feature: stringOrNull(read('feature')),
    provider: stringOrNull(read('provider')),
    model: stringOrNull(read('model')) ?? '(modèle absent)',
    timestamp,
    timeMs: Number.isFinite(timeMs) ? timeMs : null,
    costUsd: numberOrNull(read('estimated_cost_usd')),
    unpriced: read('pricing_unavailable') === true,
    inputTokens: numberOrNull(read('input_tokens')) ?? 0,
    outputTokens: numberOrNull(read('output_tokens')) ?? 0,
    thinkingTokens: numberOrNull(read('thinking_tokens')) ?? 0,
    cacheWriteTokens: numberOrNull(read('cache_creation_input_tokens')) ?? 0,
    cacheReadTokens: numberOrNull(read('cache_read_input_tokens')) ?? 0,
    status: stringOrNull(read('status')) ?? '(statut absent)',
    conversationId:
      entityType === WORKSHOP_ENTITY_TYPE ? stringOrNull(read('entity_id')) : null,
  };
}

// ── Agrégation (fonctions pures) ────────────────────────────────────────────

/**
 * Nature d'un tour au regard du cache de prompt :
 * - `first` : le cache s'écrit et ne se relit pas (premier tour d'une
 *   conversation, ou cache expiré) ;
 * - `next` : le cache se relit ;
 * - `uncached` : ni écriture ni lecture (Gemini, bac à sable, ligne ancienne).
 */
export function classifyTurn(row) {
  if (row.cacheReadTokens > 0) return 'next';
  if (row.cacheWriteTokens > 0) return 'first';
  return 'uncached';
}

/** Tri chronologique stable ; une ligne sans horodatage passe en fin. */
export function sortByTime(rows) {
  return rows
    .map((row, index) => ({ row, index }))
    .sort((a, b) => {
      const ta = a.row.timeMs ?? Number.POSITIVE_INFINITY;
      const tb = b.row.timeMs ?? Number.POSITIVE_INFINITY;
      return ta === tb ? a.index - b.index : ta - tb;
    })
    .map(({ row }) => row);
}

/** Garde les lignes datées du jour `since` (AAAA-MM-JJ, UTC) ou après. */
export function filterSince(rows, since) {
  if (since == null) return rows;
  const start = Date.parse(`${since}T00:00:00Z`);
  return rows.filter((row) => row.timeMs != null && row.timeMs >= start);
}

/**
 * Regroupe les tours en conversations. Un tour qui porte `entity_id`
 * (`conversationId`, v0.24.76 et après) rejoint sa conversation. Un tour qui
 * ne le porte pas est reconstitué par l'ordre chronologique : un premier tour
 * ouvre une conversation, les tours suivants la complètent.
 *
 * Rend `{ conversations, byId, rebuilt }` : `byId` et `rebuilt` comptent les
 * conversations de chaque méthode.
 */
export function groupConversations(turnRows) {
  const sorted = sortByTime(turnRows);
  const known = new Map();
  const conversations = [];
  let current = null;
  let byId = 0;
  let rebuilt = 0;
  for (const row of sorted) {
    if (row.conversationId != null) {
      let conversation = known.get(row.conversationId);
      if (conversation == null) {
        conversation = { rows: [], method: 'id' };
        known.set(row.conversationId, conversation);
        conversations.push(conversation);
        byId += 1;
      }
      conversation.rows.push(row);
      continue;
    }
    if (current == null || classifyTurn(row) === 'first') {
      current = { rows: [], method: 'rebuilt' };
      conversations.push(current);
      rebuilt += 1;
    }
    current.rows.push(row);
  }
  return { conversations, byId, rebuilt };
}

function sum(values) {
  return values.reduce((total, value) => total + value, 0);
}

/** Statistiques de coût d'un ensemble de lignes ; les lignes sans prix n'y entrent pas. */
export function costStats(rows) {
  const priced = rows.map((row) => row.costUsd).filter((cost) => cost != null);
  const total = sum(priced);
  return {
    count: rows.length,
    pricedCount: priced.length,
    unpricedCount: rows.length - priced.length,
    totalUsd: total,
    meanUsd: priced.length > 0 ? total / priced.length : null,
    minUsd: priced.length > 0 ? Math.min(...priced) : null,
    maxUsd: priced.length > 0 ? Math.max(...priced) : null,
  };
}

function tokenStats(rows) {
  const mean = (pick) => (rows.length > 0 ? sum(rows.map(pick)) / rows.length : null);
  const max = (pick) => (rows.length > 0 ? Math.max(...rows.map(pick)) : null);
  return {
    inputMean: mean((row) => row.inputTokens),
    outputMean: mean((row) => row.outputTokens),
    thinkingMean: mean((row) => row.thinkingTokens),
    cacheWriteMean: mean((row) => row.cacheWriteTokens),
    cacheWriteMax: max((row) => row.cacheWriteTokens),
    cacheReadMean: mean((row) => row.cacheReadTokens),
    cacheReadMax: max((row) => row.cacheReadTokens),
  };
}

function countBy(rows, pick) {
  const counts = {};
  for (const row of rows) {
    const key = pick(row);
    counts[key] = (counts[key] ?? 0) + 1;
  }
  return counts;
}

/** Une ligne par couple (poste, modèle), dans l'ordre des postes demandés. */
export function summarizeByFeatureAndModel(rows, features) {
  const lines = [];
  for (const feature of features) {
    const ofFeature = rows.filter((row) => row.feature === feature);
    const models = [...new Set(ofFeature.map((row) => row.model))].sort();
    for (const model of models) {
      const ofModel = ofFeature.filter((row) => row.model === model);
      lines.push({
        feature,
        model,
        ...costStats(ofModel),
        statuses: countBy(ofModel, (row) => row.status),
      });
    }
    if (models.length === 0) {
      lines.push({ feature, model: '—', ...costStats([]), statuses: {} });
    }
  }
  return lines;
}

/**
 * Le relevé complet, calculé sur les lignes déjà filtrées. `rows` mélange les
 * postes ; seules les lignes `meal_workshop_turn` entrent dans l'analyse du
 * cache et des conversations.
 */
export function buildReport(rows, { features, since = null } = {}) {
  const wanted = features ?? [TURN_FEATURE, RECIPE_FEATURE];
  const kept = filterSince(
    rows.filter((row) => wanted.includes(row.feature)),
    since,
  );
  const undated = rows.filter((row) => wanted.includes(row.feature) && row.timeMs == null);
  const dated = kept.filter((row) => row.timeMs != null);
  const times = dated.map((row) => row.timeMs);
  const period =
    times.length > 0
      ? { from: Math.min(...times), to: Math.max(...times) }
      : { from: null, to: null };

  const turns = sortByTime(kept.filter((row) => row.feature === TURN_FEATURE));
  const firstTurns = turns.filter((row) => classifyTurn(row) === 'first');
  const nextTurns = turns.filter((row) => classifyTurn(row) === 'next');
  const uncachedTurns = turns.filter((row) => classifyTurn(row) === 'uncached');
  const turnCost = costStats(turns);
  const firstCost = costStats(firstTurns);

  const { conversations, byId, rebuilt } = groupConversations(turns);
  const conversationCosts = conversations.map((conversation) =>
    sum(conversation.rows.map((row) => row.costUsd ?? 0)),
  );
  const turnsPerConversation = conversations.map((conversation) => conversation.rows.length);

  // Rang d'un tour dans sa conversation : jetons hors cache par rang, pour
  // lire le poids de l'historique.
  const byRank = [];
  for (const conversation of conversations) {
    conversation.rows.forEach((row, index) => {
      (byRank[index] ??= []).push(row);
    });
  }

  // Un cache d'une heure n'aurait servi qu'à un premier tour précédé d'un
  // autre tour de moins d'une heure (cas le plus favorable : même préfixe).
  const firstTurnGaps = [];
  turns.forEach((row, index) => {
    if (classifyTurn(row) !== 'first' || index === 0) return;
    const previous = turns[index - 1];
    if (row.timeMs == null || previous.timeMs == null) return;
    firstTurnGaps.push(row.timeMs - previous.timeMs);
  });
  // Réécritures du cache au milieu d'une conversation identifiée.
  const rewrites = conversations
    .filter((conversation) => conversation.method === 'id')
    .flatMap((conversation) =>
      conversation.rows.slice(1).filter((row) => classifyTurn(row) === 'first'),
    ).length;

  const recipes = kept.filter((row) => row.feature === RECIPE_FEATURE);

  return {
    since,
    period,
    undatedCount: undated.length,
    byFeatureAndModel: summarizeByFeatureAndModel(kept, wanted),
    turns: {
      ...turnCost,
      first: { ...firstCost, ...tokenStats(firstTurns) },
      next: { ...costStats(nextTurns), ...tokenStats(nextTurns) },
      uncached: { ...costStats(uncachedTurns), ...tokenStats(uncachedTurns) },
      firstShare: turnCost.totalUsd > 0 ? firstCost.totalUsd / turnCost.totalUsd : null,
    },
    conversations: {
      count: conversations.length,
      byId,
      rebuilt,
      turnsMean: conversations.length > 0 ? sum(turnsPerConversation) / conversations.length : null,
      turnsMin: conversations.length > 0 ? Math.min(...turnsPerConversation) : null,
      turnsMax: conversations.length > 0 ? Math.max(...turnsPerConversation) : null,
      costMeanUsd: conversations.length > 0 ? sum(conversationCosts) / conversations.length : null,
      costMaxUsd: conversations.length > 0 ? Math.max(...conversationCosts) : null,
      cacheRewrites: rewrites,
      // Une conversation ouverte moins de 5 min après une autre, avec le même
      // préfixe, relit le cache de la précédente dès son premier tour.
      startedOnCache: conversations.filter(
        (conversation) => classifyTurn(conversation.rows[0]) === 'next',
      ).length,
      list: conversations.map((conversation, index) => ({
        startMs: conversation.rows[0].timeMs,
        turns: conversation.rows.length,
        costUsd: conversationCosts[index],
        firstInput: conversation.rows[0].inputTokens,
        lastInput: conversation.rows.at(-1).inputTokens,
      })),
      byRank: byRank.map((rankRows, index) => ({
        rank: index + 1,
        count: rankRows.length,
        inputMean: sum(rankRows.map((row) => row.inputTokens)) / rankRows.length,
        meanUsd: costStats(rankRows).meanUsd,
      })),
    },
    firstTurnGaps: {
      count: firstTurnGaps.length,
      underOneHour: firstTurnGaps.filter((gap) => gap < ONE_HOUR_MS).length,
      underFiveMinutes: firstTurnGaps.filter((gap) => gap < FIVE_MINUTES_MS).length,
      minMs: firstTurnGaps.length > 0 ? Math.min(...firstTurnGaps) : null,
    },
    recipes: costStats(recipes),
  };
}

// ── Mise en forme ───────────────────────────────────────────────────────────

/** Montant en dollars, virgule décimale : `0,254 $`. */
export function formatUsd(value, digits = 3) {
  if (value == null) return '—';
  return `${value.toFixed(digits).replace('.', ',')} $`;
}

/** Entier groupé par milliers : `99 921`. */
export function formatInt(value) {
  if (value == null) return '—';
  return String(Math.round(value)).replace(/\B(?=(\d{3})+(?!\d))/g, ' ');
}

function formatPercent(value) {
  if (value == null) return '—';
  return `${Math.round(value * 100)} %`;
}

function formatDecimal(value, digits = 1) {
  if (value == null) return '—';
  return value.toFixed(digits).replace('.', ',');
}

/**
 * Jour UTC seul : `2026-11-07`. Le dépôt est public : le relevé ne publie
 * pas les heures d'usage d'un membre, seulement des jours et des durées.
 */
export function formatDay(ms) {
  if (ms == null) return '—';
  return new Date(ms).toISOString().slice(0, 10);
}

function formatDuration(ms) {
  if (ms == null) return '—';
  const minutes = Math.round(ms / 60000);
  if (minutes < 60) return `${minutes} min`;
  const hours = Math.floor(minutes / 60);
  const rest = minutes % 60;
  return rest === 0 ? `${hours} h` : `${hours} h ${String(rest).padStart(2, '0')}`;
}

function formatStatuses(statuses) {
  const entries = Object.entries(statuses);
  if (entries.length === 0) return '—';
  return entries
    .sort(([a], [b]) => a.localeCompare(b))
    .map(([status, count]) => `${status} ${count}`)
    .join(', ');
}

/** Le relevé en Markdown. `generatedAt` : instant du relevé, en millisecondes. */
export function renderMarkdown(report, generatedAt) {
  const t = report.turns;
  const c = report.conversations;
  const g = report.firstTurnGaps;
  const lines = [];
  lines.push(`#### Relevé du ${formatDay(generatedAt)}`);
  lines.push('');
  lines.push(
    `Période couverte (jours UTC) : du ${formatDay(report.period.from)} au ${formatDay(report.period.to)}` +
      (report.since ? ` (lignes du ${report.since} et après).` : '.'),
  );
  if (report.undatedCount > 0) {
    lines.push(`Lignes sans horodatage lisible : ${report.undatedCount}.`);
  }
  lines.push('');
  lines.push('| Poste | Modèle | Appels | Total | Moyenne | Max | Sans prix | Statuts |');
  lines.push('|---|---|---|---|---|---|---|---|');
  for (const row of report.byFeatureAndModel) {
    lines.push(
      `| \`${row.feature}\` | ${row.model} | ${row.count} | ${formatUsd(row.totalUsd, 2)} | ` +
        `${formatUsd(row.meanUsd)} | ${formatUsd(row.maxUsd)} | ${row.unpricedCount} | ` +
        `${formatStatuses(row.statuses)} |`,
    );
  }
  lines.push('');
  lines.push(`Tours \`${TURN_FEATURE}\`, selon le cache de prompt :`);
  lines.push('');
  lines.push(
    '| Nature | Tours | Coût moyen | Min | Max | Jetons écrits en cache (moy.) | Jetons lus en cache (moy.) | Jetons hors cache (moy.) | Sortie (moy.) |',
  );
  lines.push('|---|---|---|---|---|---|---|---|---|');
  const natureRow = (label, s) =>
    `| ${label} | ${s.count} | ${formatUsd(s.meanUsd)} | ${formatUsd(s.minUsd)} | ` +
    `${formatUsd(s.maxUsd)} | ${formatInt(s.cacheWriteMean)} | ${formatInt(s.cacheReadMean)} | ` +
    `${formatInt(s.inputMean)} | ${formatInt(s.outputMean)} |`;
  lines.push(natureRow('Premier tour (écriture du cache)', t.first));
  lines.push(natureRow('Tour suivant (lecture du cache)', t.next));
  if (t.uncached.count > 0) lines.push(natureRow('Sans cache', t.uncached));
  lines.push('');
  lines.push(
    `Part des premiers tours dans le coût des tours : ${formatPercent(t.firstShare)} ` +
      `(${formatUsd(t.first.totalUsd, 2)} sur ${formatUsd(t.totalUsd, 2)}).`,
  );
  lines.push(
    `Taille du préfixe en cache (indicateur du corpus) : ${formatInt(t.first.cacheWriteMax)} jetons ` +
      `écrits au plus, ${formatInt(t.next.cacheReadMax)} lus au plus.`,
  );
  lines.push('');
  lines.push(
    `Conversations : ${c.count} (${c.byId} par \`entity_id\`, ${c.rebuilt} reconstituées par l'ordre des tours). ` +
      `Tours par conversation : ${formatDecimal(c.turnsMean)} en moyenne, de ${formatInt(c.turnsMin)} à ` +
      `${formatInt(c.turnsMax)}. Coût d'une conversation : ${formatUsd(c.costMeanUsd)} en moyenne, ` +
      `${formatUsd(c.costMaxUsd)} au plus. Cache réécrit en cours de conversation : ${c.cacheRewrites} fois. ` +
      `Conversations commencées par une lecture du cache : ${c.startedOnCache}.`,
  );
  lines.push('');
  if (c.list.length > 0) {
    lines.push('| Conversation | Jour (UTC) | Tours | Coût | Jetons hors cache, premier → dernier tour |');
    lines.push('|---|---|---|---|---|');
    c.list.forEach((conversation, index) => {
      lines.push(
        `| ${index + 1} | ${formatDay(conversation.startMs)} | ${conversation.turns} | ` +
          `${formatUsd(conversation.costUsd)} | ${formatInt(conversation.firstInput)} → ` +
          `${formatInt(conversation.lastInput)} |`,
      );
    });
    lines.push('');
  }
  if (c.byRank.length > 0) {
    lines.push('| Rang du tour | Tours | Jetons hors cache (moy.) | Coût moyen |');
    lines.push('|---|---|---|---|');
    for (const rank of c.byRank) {
      lines.push(
        `| ${rank.rank} | ${rank.count} | ${formatInt(rank.inputMean)} | ${formatUsd(rank.meanUsd)} |`,
      );
    }
    lines.push('');
  }
  lines.push(
    `Premiers tours précédés d'un autre tour : ${g.count} ; à moins d'une heure : ${g.underOneHour} ; ` +
      `à moins de 5 min : ${g.underFiveMinutes} ; écart le plus court : ${formatDuration(g.minMs)}.`,
  );
  lines.push(
    `Plats rédigés (\`${RECIPE_FEATURE}\`) : ${report.recipes.count}, ` +
      `coût moyen ${formatUsd(report.recipes.meanUsd)}.`,
  );
  lines.push('');
  lines.push(
    "Le nombre de recettes envoyées n'est pas enregistré dans `ai_usage` : les jetons du cache en tiennent lieu.",
  );
  return lines.join('\n');
}

// ── Arguments ───────────────────────────────────────────────────────────────

/** `{ since, sandbox }` ; lève une erreur sur un argument inconnu ou mal formé. */
export function parseArgs(argv) {
  const options = { since: null, sandbox: false };
  for (let i = 0; i < argv.length; i += 1) {
    const arg = argv[i];
    if (arg === '--sandbox') {
      options.sandbox = true;
    } else if (arg === '--since' || arg.startsWith('--since=')) {
      const value = arg === '--since' ? argv[++i] : arg.slice('--since='.length);
      if (value == null || !/^\d{4}-\d{2}-\d{2}$/.test(value) || !Number.isFinite(Date.parse(value))) {
        throw new Error(`--since attend une date AAAA-MM-JJ, reçu : ${value ?? '(rien)'}`);
      }
      options.since = value;
    } else {
      throw new Error(`argument inconnu : ${arg} (attendus : --since AAAA-MM-JJ, --sandbox)`);
    }
  }
  return options;
}

// ── Accès à Firestore (lecture seule) ───────────────────────────────────────

/**
 * Dossiers globaux connus, essayés sans lancer de processus : sous Windows
 * `%APPDATA%/npm/node_modules`, ailleurs `<préfixe de node>/lib/node_modules`.
 */
export function knownGlobalRoots(env = process.env, platform = process.platform, execPath = process.execPath) {
  if (platform === 'win32') {
    return env.APPDATA ? [join(env.APPDATA, 'npm', 'node_modules')] : [];
  }
  return [join(dirname(dirname(execPath)), 'lib', 'node_modules')];
}

function firebaseToolsDir() {
  if (process.env.FIREBASE_TOOLS_DIR) return process.env.FIREBASE_TOOLS_DIR;
  for (const root of knownGlobalRoots()) {
    const dir = join(root, 'firebase-tools');
    if (existsSync(join(dir, 'lib', 'api.js'))) return dir;
  }
  // Repli : `npm root -g` lancé depuis le dossier personnel. Lancé depuis le
  // dépôt, cmd.exe chercherait d'abord un `npm.cmd` du dossier courant, et npm
  // lirait un `.npmrc` de projet.
  let globalRoot;
  try {
    globalRoot = execSync('npm root -g', {
      cwd: homedir(),
      encoding: 'utf8',
      stdio: ['ignore', 'pipe', 'pipe'],
    }).trim();
  } catch (err) {
    throw new Error(
      `« npm root -g » a échoué (${err.message}). Indiquez le dossier du paquet par FIREBASE_TOOLS_DIR.`,
    );
  }
  return join(globalRoot, 'firebase-tools');
}

/** Client OAuth du CLI Firebase : variables d'environnement, sinon paquet installé. */
function loadOAuthClient() {
  const envId = process.env.FIREBASE_CLIENT_ID;
  const envSecret = process.env.FIREBASE_CLIENT_SECRET;
  if (envId && envSecret) return { clientId: envId, clientSecret: envSecret };

  const dir = firebaseToolsDir();
  const apiPath = join(dir, 'lib', 'api.js');
  if (!existsSync(apiPath)) {
    throw new Error(
      `client OAuth introuvable : ${apiPath} n'existe pas. Installez le CLI (npm install -g firebase-tools), ` +
        'ou posez FIREBASE_TOOLS_DIR, ou FIREBASE_CLIENT_ID et FIREBASE_CLIENT_SECRET.',
    );
  }
  let api;
  try {
    api = createRequire(import.meta.url)(apiPath);
  } catch (err) {
    throw new Error(`chargement de ${apiPath} impossible : ${err.message}`);
  }
  // Selon la version du paquet, l'export est une fonction ou une chaîne.
  const read = (value) => (typeof value === 'function' ? value() : value);
  const clientId = read(api.clientId);
  const clientSecret = read(api.clientSecret);
  if (typeof clientId !== 'string' || typeof clientSecret !== 'string' || !clientId || !clientSecret) {
    throw new Error(
      `${apiPath} n'exporte pas clientId et clientSecret. Posez FIREBASE_CLIENT_ID et FIREBASE_CLIENT_SECRET.`,
    );
  }
  return { clientId, clientSecret };
}

/**
 * Jeton de rafraîchissement lu dans le texte de `firebase-tools.json`. Aucun
 * message d'erreur ne recopie le contenu du fichier : le message d'un
 * `JSON.parse` en cite un extrait, qui peut être le début du jeton.
 */
export function readRefreshTokenFrom(text, path) {
  let config;
  try {
    config = JSON.parse(text);
  } catch (err) {
    throw new Error(`lecture de ${path} impossible : JSON invalide (${err.name})`);
  }
  const token = config?.tokens?.refresh_token;
  if (typeof token !== 'string' || token === '') {
    throw new Error(`aucun jeton de rafraîchissement dans ${path}. Connectez le CLI : firebase login.`);
  }
  return token;
}

function readRefreshToken() {
  const path =
    process.env.FIREBASE_TOOLS_CONFIG ??
    join(homedir(), '.config', 'configstore', 'firebase-tools.json');
  if (!existsSync(path)) {
    throw new Error(`configuration du CLI introuvable : ${path}. Connectez le CLI : firebase login.`);
  }
  let text;
  try {
    text = readFileSync(path, 'utf8');
  } catch (err) {
    // Le code seul (ENOENT, EACCES…) : rien du contenu.
    throw new Error(`lecture de ${path} impossible : ${err.code ?? err.name}`);
  }
  return readRefreshTokenFrom(text, path);
}

async function fetchAccessToken() {
  const { clientId, clientSecret } = loadOAuthClient();
  const response = await fetch(TOKEN_URL, {
    method: 'POST',
    headers: { 'content-type': 'application/x-www-form-urlencoded' },
    body: new URLSearchParams({
      grant_type: 'refresh_token',
      refresh_token: readRefreshToken(),
      client_id: clientId,
      client_secret: clientSecret,
    }),
  });
  // Un corps illisible devient une erreur nommée, levée juste en dessous. Le
  // type seul : le message de JSON.parse citerait un extrait de la réponse.
  const body = await response.json().catch((err) => ({ error: `réponse illisible (${err.name})` }));
  if (!response.ok || typeof body.access_token !== 'string') {
    throw new Error(
      `échange du jeton refusé (HTTP ${response.status}) : ${body.error ?? '?'} ${body.error_description ?? ''}`.trim() +
        '. Reconnectez le CLI : firebase login --reauth.',
    );
  }
  return body.access_token;
}

/** Toutes les lignes `ai_usage` d'un poste, par pages, triées par nom de document. */
async function fetchFeatureRows(accessToken, feature) {
  const rows = [];
  let lastName = null;
  for (;;) {
    const structuredQuery = {
      select: { fields: SELECTED_FIELDS.map((fieldPath) => ({ fieldPath })) },
      from: [{ collectionId: 'ai_usage' }],
      where: {
        fieldFilter: { field: { fieldPath: 'feature' }, op: 'EQUAL', value: { stringValue: feature } },
      },
      orderBy: [{ field: { fieldPath: '__name__' }, direction: 'ASCENDING' }],
      limit: PAGE_SIZE,
      ...(lastName ? { startAt: { values: [{ referenceValue: lastName }], before: false } } : {}),
    };
    const response = await fetch(RUN_QUERY_URL, {
      method: 'POST',
      headers: { authorization: `Bearer ${accessToken}`, 'content-type': 'application/json' },
      body: JSON.stringify({ structuredQuery }),
    });
    // Un corps illisible devient une erreur nommée, levée juste en dessous. Le
    // type seul : le message de JSON.parse citerait un extrait de la réponse.
    const body = await response.json().catch((err) => ({ error: { message: `réponse illisible (${err.name})` } }));
    const failure = Array.isArray(body) ? body.find((item) => item.error)?.error : body.error;
    if (!response.ok || failure || !Array.isArray(body)) {
      throw new Error(
        `runQuery sur ai_usage (feature == ${feature}) refusé (HTTP ${response.status}) : ` +
          `${failure?.message ?? 'réponse inattendue'}`,
      );
    }
    const documents = body.filter((item) => item.document).map((item) => item.document);
    for (const document of documents) rows.push(decodeRow(document));
    if (documents.length < PAGE_SIZE) return rows;
    lastName = documents.at(-1).name;
  }
}

async function main() {
  const options = parseArgs(process.argv.slice(2));
  const features = [TURN_FEATURE, RECIPE_FEATURE, ...(options.sandbox ? [SANDBOX_TURN_FEATURE] : [])];
  const accessToken = await fetchAccessToken();
  const rows = [];
  for (const feature of features) {
    rows.push(...(await fetchFeatureRows(accessToken, feature)));
  }
  const report = buildReport(rows, { features, since: options.since });
  process.stdout.write(`${renderMarkdown(report, Date.now())}\n`);
}

if (process.argv[1] && resolve(fileURLToPath(import.meta.url)) === resolve(process.argv[1])) {
  main().catch((err) => {
    process.stderr.write(`workshop-cost-report : ${err.stack ?? err.message ?? String(err)}\n`);
    process.exitCode = 1;
  });
}
