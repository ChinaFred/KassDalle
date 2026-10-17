import assert from 'node:assert/strict';
import { test } from 'node:test';

import { COUNT, extractRecentVersions } from './changelog-recent.mjs';

const SAMPLE = `# Historique

## 2026-10-17

### v0.2.3 — fonctionnel

Texte trois.

### v0.2.3 — technique

Détail technique trois.

### v0.2.2 — technique

Seulement technique.

## 2026-10-16

### v0.2.1 — fonctionnel

Premier texte.

### v0.2.1 — technique

Technique un.

### v0.2.1 — fonctionnel

Second texte avec \`fichier.dart\`.

### v0.2.0 — fonctionnel

Texte zéro.
`;

test('ignore une version qui n\'a qu\'une entrée technique', () => {
  const versions = extractRecentVersions(SAMPLE);
  assert.deepEqual(
    versions.map((v) => v.version),
    ['0.2.3', '0.2.1', '0.2.0'],
  );
});

test('lit la date et exclut le texte technique', () => {
  const [first] = extractRecentVersions(SAMPLE);
  assert.equal(first.date, '2026-10-17');
  assert.equal(first.text, 'Texte trois.');
});

test('concatène deux entrées fonctionnel d\'une même version', () => {
  const second = extractRecentVersions(SAMPLE)[1];
  assert.equal(
    second.text,
    'Premier texte.\n\nSecond texte avec `fichier.dart`.',
  );
});

test('plafonne au nombre demandé', () => {
  assert.equal(extractRecentVersions(SAMPLE, 2).length, 2);
});

test('lit les fins de ligne Windows', () => {
  const versions = extractRecentVersions(SAMPLE.replaceAll('\n', '\r\n'));
  assert.equal(versions[0].text, 'Texte trois.');
});

test('le CHANGELOG du dépôt donne au moins COUNT versions', async () => {
  const { readFileSync } = await import('node:fs');
  const text = readFileSync(
    new URL('../../documentation/CHANGELOG.md', import.meta.url),
    'utf8',
  );
  assert.equal(extractRecentVersions(text).length, COUNT);
});
