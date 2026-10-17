#!/usr/bin/env node
// Extrait du CHANGELOG.md les dernières versions qui portent une entrée
// « fonctionnel », pour l'écran « Nouveautés » de l'application.
//
// Usage, depuis la racine du dépôt :
//   node .github/scripts/changelog-recent.mjs
//
// Lit documentation/CHANGELOG.md et écrit kass_dalle/assets/changelog_recent.json.
// Le fichier est régénéré par la CI et par le workflow « Déploiement » avant
// chaque build ; la copie versionnée ne sert qu'aux builds locaux.
//
// Échoue (code 1) quand le CHANGELOG donne moins de COUNT versions : une liste
// tronquée ne doit pas partir en ligne.
import { readFileSync, writeFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

export const COUNT = 6;

const DATE_RE = /^## (\d{4}-\d{2}-\d{2})\s*$/;
const ENTRY_RE = /^### v(\d+\.\d+\.\d+) — (fonctionnel|technique)\s*$/;

/**
 * Les `count` dernières versions ayant une entrée « fonctionnel », de la plus
 * récente à la plus ancienne (ordre du fichier). Une version qui n'a qu'une
 * entrée « technique » est ignorée. Deux entrées « fonctionnel » d'une même
 * version sont concaténées, séparées par une ligne vide.
 */
export function extractRecentVersions(markdown, count = COUNT) {
  const versions = [];
  const byVersion = new Map();
  let date = null;
  let current = null;

  const close = () => {
    if (current === null) return;
    const text = current.lines.join('\n').trim();
    const entry = current;
    current = null;
    if (text === '') return;
    const known = byVersion.get(entry.version);
    if (known) {
      known.text += `\n\n${text}`;
      return;
    }
    const added = { version: entry.version, date: entry.date, text };
    byVersion.set(entry.version, added);
    versions.push(added);
  };

  for (const line of markdown.split(/\r?\n/)) {
    const dateMatch = DATE_RE.exec(line);
    if (dateMatch) {
      close();
      date = dateMatch[1];
      continue;
    }
    const entry = ENTRY_RE.exec(line);
    if (entry) {
      close();
      if (entry[2] === 'fonctionnel') {
        current = { version: entry[1], date, lines: [] };
      }
      continue;
    }
    if (current === null) continue;
    if (line.startsWith('#')) {
      close();
      continue;
    }
    current.lines.push(line);
  }
  close();
  return versions.slice(0, count);
}

function main() {
  const root = join(dirname(fileURLToPath(import.meta.url)), '..', '..');
  const source = join(root, 'documentation', 'CHANGELOG.md');
  const target = join(root, 'kass_dalle', 'assets', 'changelog_recent.json');

  const versions = extractRecentVersions(readFileSync(source, 'utf8'));
  if (versions.length < COUNT) {
    console.error(
      `CHANGELOG.md : ${versions.length} version(s) « fonctionnel » trouvée(s), ${COUNT} attendues.`,
    );
    process.exit(1);
  }
  writeFileSync(target, `${JSON.stringify({ versions }, null, 2)}\n`);
  console.log(
    `${target} : ${versions.map((v) => `v${v.version}`).join(', ')}`,
  );
}

if (process.argv[1] === fileURLToPath(import.meta.url)) main();
