import assert from 'node:assert/strict';
import { join } from 'node:path';
import { test } from 'node:test';

import {
  buildReport,
  classifyTurn,
  decodeRow,
  filterSince,
  formatInt,
  formatUsd,
  groupConversations,
  knownGlobalRoots,
  parseArgs,
  readRefreshTokenFrom,
  renderMarkdown,
  RECIPE_FEATURE,
  SELECTED_FIELDS,
  TURN_FEATURE,
} from './workshop-cost-report.mjs';

const MINUTE = 60 * 1000;
const T0 = Date.parse('2026-11-06T21:07:00Z');

/** Une ligne déjà décodée, comme la rend `decodeRow`. */
function row(overrides = {}) {
  return {
    feature: TURN_FEATURE,
    provider: 'anthropic',
    model: 'claude-sonnet-5',
    timestamp: null,
    timeMs: T0,
    costUsd: 0.026,
    unpriced: false,
    inputTokens: 500,
    outputTokens: 400,
    thinkingTokens: 0,
    cacheWriteTokens: 0,
    cacheReadTokens: 99921,
    status: 'ok',
    conversationId: null,
    ...overrides,
  };
}

const first = (minutes, overrides = {}) =>
  row({
    timeMs: T0 + minutes * MINUTE,
    costUsd: 0.254,
    inputTokens: 141,
    cacheWriteTokens: 99921,
    cacheReadTokens: 0,
    ...overrides,
  });
const next = (minutes, overrides = {}) => row({ timeMs: T0 + minutes * MINUTE, ...overrides });

test('classe un tour selon le cache de prompt', () => {
  assert.equal(classifyTurn(first(0)), 'first');
  assert.equal(classifyTurn(next(1)), 'next');
  assert.equal(classifyTurn(row({ cacheWriteTokens: 0, cacheReadTokens: 0 })), 'uncached');
  // Lecture et écriture à la fois : le tour relit le cache, il n'est pas premier.
  assert.equal(classifyTurn(row({ cacheWriteTokens: 300, cacheReadTokens: 99921 })), 'next');
});

test('décode une ligne REST, champs absents ou mal typés compris', () => {
  const decoded = decodeRow({
    fields: {
      feature: { stringValue: TURN_FEATURE },
      model: { stringValue: 'claude-sonnet-5' },
      timestamp: { timestampValue: '2026-11-07T16:09:12.000Z' },
      estimated_cost_usd: { doubleValue: 0.254 },
      input_tokens: { integerValue: '141' },
      cache_creation_input_tokens: { integerValue: '99921' },
      cache_read_input_tokens: { stringValue: 'pas un nombre' },
      entity_type: { stringValue: 'meal_workshop' },
      entity_id: { stringValue: 'conv_abcdefgh' },
      uid: { stringValue: 'ne-doit-pas-sortir' },
    },
  });
  assert.equal(decoded.costUsd, 0.254);
  assert.equal(decoded.inputTokens, 141);
  assert.equal(decoded.cacheWriteTokens, 99921);
  assert.equal(decoded.cacheReadTokens, 0);
  assert.equal(decoded.conversationId, 'conv_abcdefgh');
  assert.equal(decoded.status, '(statut absent)');
  assert.equal(decoded.timeMs, Date.parse('2026-11-07T16:09:12.000Z'));
  assert.equal('uid' in decoded, false);
  assert.equal(SELECTED_FIELDS.includes('uid'), false);

  const empty = decodeRow({});
  assert.equal(empty.costUsd, null);
  assert.equal(empty.timeMs, null);
  assert.equal(empty.model, '(modèle absent)');
});

test('ignore entity_id quand entity_type n\'est pas celui de l\'atelier', () => {
  const decoded = decodeRow({
    fields: { entity_type: { stringValue: 'recipe' }, entity_id: { stringValue: 'r1' } },
  });
  assert.equal(decoded.conversationId, null);
});

test('regroupe par entity_id, même quand les conversations se chevauchent', () => {
  const rows = [
    first(0, { conversationId: 'a' }),
    first(1, { conversationId: 'b' }),
    next(2, { conversationId: 'a' }),
    next(3, { conversationId: 'b' }),
    next(4, { conversationId: 'a' }),
  ];
  const { conversations, byId, rebuilt } = groupConversations(rows);
  assert.equal(byId, 2);
  assert.equal(rebuilt, 0);
  assert.deepEqual(
    conversations.map((c) => c.rows.length),
    [3, 2],
  );
});

test('reconstitue les conversations sans entity_id : un premier tour en ouvre une', () => {
  // Ordre d'arrivée volontairement mélangé : le tri chronologique décide.
  const rows = [next(5), first(0), next(1), first(90), next(91), next(92)];
  const { conversations, rebuilt } = groupConversations(rows);
  assert.equal(rebuilt, 2);
  assert.deepEqual(
    conversations.map((c) => c.rows.length),
    [3, 3],
  );
  // Des tours suivants sans premier tour avant eux forment quand même une conversation.
  assert.equal(groupConversations([next(0), next(1)]).conversations.length, 1);
});

test('filtre les lignes à partir d\'une date, en UTC', () => {
  const rows = [first(0), next(3 * 60), row({ timeMs: null })];
  assert.equal(filterSince(rows, null).length, 3);
  assert.equal(filterSince(rows, '2026-11-07').length, 1);
});

test('totaux, premiers tours, conversations et plats rédigés', () => {
  const rows = [
    first(0, { conversationId: 'a' }),
    next(2, { conversationId: 'a', costUsd: 0.024 }),
    next(4, { conversationId: 'a', costUsd: 0.03 }),
    // Ouverte 3 min après : relit le cache de la conversation a.
    next(7, { conversationId: 'b', inputTokens: 100 }),
    // Ouverte 2 h après : écrit le cache de nouveau.
    first(130, { conversationId: 'c' }),
    next(131, { conversationId: 'c', costUsd: null, unpriced: true }),
    row({ feature: RECIPE_FEATURE, timeMs: T0 + 140 * MINUTE, costUsd: 0.05, cacheReadTokens: 0 }),
    row({ feature: 'planning_concept', costUsd: 9 }),
  ];
  const report = buildReport(rows);

  assert.equal(report.period.from, T0);
  assert.equal(report.period.to, T0 + 140 * MINUTE);

  const turnLine = report.byFeatureAndModel.find((l) => l.feature === TURN_FEATURE);
  assert.equal(turnLine.count, 6);
  assert.equal(turnLine.unpricedCount, 1);
  assert.ok(Math.abs(turnLine.totalUsd - (0.254 * 2 + 0.024 + 0.03 + 0.026)) < 1e-9);
  assert.equal(turnLine.maxUsd, 0.254);

  assert.equal(report.turns.first.count, 2);
  assert.equal(report.turns.next.count, 4);
  assert.equal(report.turns.first.cacheWriteMean, 99921);
  assert.ok(Math.abs(report.turns.firstShare - 0.508 / 0.588) < 1e-9);

  assert.equal(report.conversations.count, 3);
  assert.equal(report.conversations.turnsMax, 3);
  assert.equal(report.conversations.startedOnCache, 1);
  assert.equal(report.conversations.cacheRewrites, 0);
  assert.ok(Math.abs(report.conversations.costMaxUsd - 0.308) < 1e-9);
  assert.equal(report.conversations.byRank[0].count, 3);

  // Seul le premier tour de c est précédé d'un autre tour, 123 min avant.
  assert.equal(report.firstTurnGaps.count, 1);
  assert.equal(report.firstTurnGaps.underOneHour, 0);
  assert.equal(report.firstTurnGaps.minMs, 123 * MINUTE);

  assert.equal(report.recipes.count, 1);
  assert.equal(report.recipes.meanUsd, 0.05);
});

test('compte une réécriture du cache au milieu d\'une conversation', () => {
  const report = buildReport([
    first(0, { conversationId: 'a' }),
    next(2, { conversationId: 'a' }),
    first(20, { conversationId: 'a' }),
  ]);
  assert.equal(report.conversations.cacheRewrites, 1);
  assert.equal(report.firstTurnGaps.underOneHour, 1);
  assert.equal(report.firstTurnGaps.underFiveMinutes, 0);
});

test('un relevé vide ne lève pas d\'erreur', () => {
  const report = buildReport([]);
  assert.equal(report.turns.count, 0);
  assert.equal(report.turns.firstShare, null);
  assert.equal(report.conversations.count, 0);
  const markdown = renderMarkdown(report, T0);
  assert.match(markdown, /Période couverte \(jours UTC\) : du — au —/);
});

test('le Markdown ne contient aucun identifiant de conversation', () => {
  const report = buildReport([
    first(0, { conversationId: 'conv_secret_123' }),
    next(1, { conversationId: 'conv_secret_123' }),
  ]);
  const markdown = renderMarkdown(report, T0);
  assert.equal(markdown.includes('conv_secret_123'), false);
  assert.match(markdown, /Part des premiers tours dans le coût des tours : 91 %/);
});

test('formate les montants et les jetons à la française', () => {
  assert.equal(formatUsd(0.2541), '0,254 $');
  assert.equal(formatUsd(1.476, 2), '1,48 $');
  assert.equal(formatUsd(null), '—');
  assert.equal(formatInt(99921), '99 921');
  assert.equal(formatInt(141), '141');
});

test('lit les arguments et refuse ce qu\'il ne connaît pas', () => {
  assert.deepEqual(parseArgs([]), { since: null, sandbox: false });
  assert.deepEqual(parseArgs(['--since', '2026-11-01', '--sandbox']), {
    since: '2026-11-01',
    sandbox: true,
  });
  assert.equal(parseArgs(['--since=2026-11-02']).since, '2026-11-02');
  assert.throws(() => parseArgs(['--since', '7/11/2026']), /AAAA-MM-JJ/);
  assert.throws(() => parseArgs(['--since']), /AAAA-MM-JJ/);
  assert.throws(() => parseArgs(['--write']), /argument inconnu/);
});

test('le Markdown ne publie que des jours, jamais une heure', () => {
  const report = buildReport([
    first(0, { conversationId: 'a' }),
    next(2, { conversationId: 'a' }),
    first(130, { conversationId: 'b' }),
  ]);
  const markdown = renderMarkdown(report, Date.parse('2026-11-07T22:00:00Z'));
  assert.equal(/\d{1,2}:\d{2}/.test(markdown), false);
  assert.match(markdown, /Relevé du 2026-11-07/);
  assert.match(markdown, /du 2026-11-06 au 2026-11-06/);
  assert.match(markdown, /\| 1 \| 2026-11-06 \| 2 \|/);
  // Les durées restent : 128 min entre le dernier tour de a et le premier de b.
  assert.match(markdown, /écart le plus court : 2 h 08/);
});

test('lit le jeton du CLI sans jamais recopier le fichier dans une erreur', () => {
  const path = 'C:/x/firebase-tools.json';
  assert.equal(readRefreshTokenFrom('{"tokens":{"refresh_token":"1//abc"}}', path), '1//abc');
  const secret = '1//0gSECRETSECRETSECRET';
  // JSON tronqué : le message de JSON.parse citerait le début du fichier.
  for (const text of [`{"tokens":{"refresh_token":"${secret}`, `${secret}`, `{"tokens": ${secret}}`]) {
    assert.throws(
      () => readRefreshTokenFrom(text, path),
      (err) => {
        assert.equal(err.message.includes('SECRET'), false);
        assert.equal(err.message.includes('0gS'), false);
        assert.match(err.message, /JSON invalide \(SyntaxError\)/);
        return true;
      },
    );
  }
  assert.throws(() => readRefreshTokenFrom('{"tokens":{}}', path), /firebase login/);
});

test('cherche le paquet global sans lancer de processus', () => {
  assert.deepEqual(knownGlobalRoots({ APPDATA: 'C:/Users/u/AppData/Roaming' }, 'win32', 'x'), [
    join('C:/Users/u/AppData/Roaming', 'npm', 'node_modules'),
  ]);
  assert.deepEqual(knownGlobalRoots({}, 'win32', 'x'), []);
  assert.deepEqual(knownGlobalRoots({}, 'linux', '/usr/local/bin/node'), [
    join('/usr/local', 'lib', 'node_modules'),
  ]);
});
