#!/usr/bin/env node
// Extrait du CHANGELOG pour l'écran « Nouveautés » de l'application.
//
//   node .github/scripts/changelog-recent.mjs <CHANGELOG.md> <sortie.json> [nombre]
//
// Écrit les <nombre> (6 par défaut) dernières versions qui ont une entrée
// « ### v<x> — fonctionnel », de la plus récente à la plus ancienne. Chaque
// version porte la date de son titre « ## AAAA-MM-JJ » et le texte de ses
// entrées « fonctionnel » (deux entrées se concatènent). Une version qui n'a
// qu'une entrée « technique » est ignorée : elle n'a rien à montrer à un
// membre.
//
// Le fichier entier (environ 660 Ko) n'est pas embarqué dans l'application.
// ci.yml et deploy.yml lancent ce script avant les tests et le build : la
// version installée connaît son propre historique. Le JSON est aussi
// versionné dans kass_dalle/assets/, pour que flutter run et deploy.ps1
// trouvent l'asset ; il peut y dater de quelques versions.
//
// Échoue (code 1) si l'extraction rend moins de <nombre> versions : une liste
// tronquée ne part pas en production. Échoue aussi si un texte extrait contient
// une image Markdown (« ![ ») : l'écran ne charge aucune image, et une adresse
// externe dans l'APK servirait de pixel de suivi.

import { readFileSync, writeFileSync } from 'node:fs';
import { pathToFileURL } from 'node:url';

const DATE_HEADING = /^## (\d{4}-\d{2}-\d{2})\s*$/;
const VERSION_HEADING = /^### v(\S+) — (fonctionnel|technique)\s*$/;

/**
 * Les `count` dernières versions qui ont une entrée « fonctionnel ».
 * Rend moins de `count` versions si le texte n'en contient pas assez.
 */
export function extractRecent(markdown, count) {
  const versions = [];
  const byVersion = new Map();
  let date = null;
  let current = null;

  const close = () => {
    if (current === null) return;
    const text = current.lines.join('\n').trim();
    if (text.length > 0) {
      let entry = byVersion.get(current.version);
      if (entry === undefined) {
        entry = { version: current.version, date: current.date, texts: [] };
        byVersion.set(current.version, entry);
        versions.push(entry);
      }
      entry.texts.push(text);
    }
    current = null;
  };

  for (const line of markdown.replace(/\r/g, '').split('\n')) {
    const dateMatch = DATE_HEADING.exec(line);
    if (dateMatch) {
      close();
      date = dateMatch[1];
      continue;
    }
    const versionMatch = VERSION_HEADING.exec(line);
    if (versionMatch) {
      close();
      if (versionMatch[2] === 'fonctionnel') {
        current = { version: versionMatch[1], date, lines: [] };
      }
      continue;
    }
    // Tout autre titre de niveau 1 à 3, ou un séparateur, termine l'entrée.
    if (/^#{1,3} /.test(line) || /^---\s*$/.test(line)) {
      close();
      continue;
    }
    if (current !== null) current.lines.push(line);
  }
  close();

  return versions.slice(0, count).map((entry) => ({
    version: entry.version,
    date: entry.date,
    text: entry.texts.join('\n\n'),
  }));
}

export function main(argv) {
  const [source, output, rawCount] = argv;
  if (!source || !output) {
    console.error('Usage : changelog-recent.mjs <CHANGELOG.md> <sortie.json> [nombre]');
    return 2;
  }
  const count = rawCount === undefined ? 6 : Number.parseInt(rawCount, 10);
  if (!Number.isInteger(count) || count < 1) {
    console.error(`Nombre de versions invalide : ${rawCount}`);
    return 2;
  }
  const versions = extractRecent(readFileSync(source, 'utf8'), count);
  if (versions.length < count) {
    console.error(
      `::error file=${source}::${versions.length} version(s) « fonctionnel » trouvée(s), ${count} attendue(s).`,
    );
    return 1;
  }
  const withImage = versions.filter((v) => v.text.includes('!['));
  if (withImage.length > 0) {
    console.error(
      `::error file=${source}::Image Markdown dans l'entrée « fonctionnel » de ${withImage.map((v) => `v${v.version}`).join(', ')} : retirer l'image.`,
    );
    return 1;
  }
  writeFileSync(output, `${JSON.stringify({ versions }, null, 2)}\n`);
  console.log(`${output} : ${versions.map((v) => `v${v.version}`).join(', ')}.`);
  return 0;
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  process.exitCode = main(process.argv.slice(2));
}
