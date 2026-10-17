// Tests de changelog-recent.mjs, lancés par le job Flutter de ci.yml :
//   node --test .github/scripts/changelog-recent.test.mjs

import assert from 'node:assert/strict';
import { mkdtempSync, readFileSync, writeFileSync, existsSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { test } from 'node:test';

import { extractRecent, main } from './changelog-recent.mjs';

const SAMPLE = `# Historique des versions

Préambule.

---

## 2026-10-17

### v0.23.98 — fonctionnel

Nouvelle décision « Clore ».

Deuxième paragraphe.

### v0.23.98 — technique

Callable \`closeTicket\`.

### v0.23.97 — technique

Rien à montrer.

## 2026-10-16

### v0.23.96 — fonctionnel

Doublons à l'import.

### v0.23.96 — fonctionnel

Seconde entrée.

---

### v0.23.95 — fonctionnel

Planning.
`;

test('garde les entrées « fonctionnel », dans l’ordre du fichier', () => {
  assert.deepEqual(extractRecent(SAMPLE, 6), [
    {
      version: '0.23.98',
      date: '2026-10-17',
      text: 'Nouvelle décision « Clore ».\n\nDeuxième paragraphe.',
    },
    { version: '0.23.96', date: '2026-10-16', text: "Doublons à l'import.\n\nSeconde entrée." },
    { version: '0.23.95', date: '2026-10-16', text: 'Planning.' },
  ]);
});

test('une version seulement technique est ignorée', () => {
  const versions = extractRecent(SAMPLE, 6).map((v) => v.version);
  assert.ok(!versions.includes('0.23.97'));
});

test('s’arrête au nombre demandé', () => {
  assert.deepEqual(
    extractRecent(SAMPLE, 2).map((v) => v.version),
    ['0.23.98', '0.23.96'],
  );
});

test('lit les fins de ligne Windows', () => {
  const [first] = extractRecent(SAMPLE.replace(/\n/g, '\r\n'), 1);
  assert.equal(first.text, 'Nouvelle décision « Clore ».\n\nDeuxième paragraphe.');
});

test('le CHANGELOG du dépôt fournit six versions datées', () => {
  const markdown = readFileSync(new URL('../../documentation/CHANGELOG.md', import.meta.url), 'utf8');
  const versions = extractRecent(markdown, 6);
  assert.equal(versions.length, 6);
  for (const v of versions) {
    assert.match(v.version, /^\d+\.\d+\.\d+$/);
    assert.match(v.date, /^\d{4}-\d{2}-\d{2}$/);
    assert.ok(v.text.length > 0);
  }
});

test('une image dans un texte extrait fait échouer le script', () => {
  const dir = mkdtempSync(join(tmpdir(), 'changelog-'));
  const source = join(dir, 'CHANGELOG.md');
  const output = join(dir, 'out.json');
  writeFileSync(source, SAMPLE.replace('Planning.', 'Planning ![x](https://exemple.test/p.png).'));
  assert.equal(main([source, output, '3']), 1);
  assert.equal(existsSync(output), false);
  writeFileSync(source, SAMPLE);
  assert.equal(main([source, output, '3']), 0);
  assert.equal(JSON.parse(readFileSync(output, 'utf8')).versions.length, 3);
});
