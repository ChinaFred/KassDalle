/**
 * Correction orthographique de la **prose seule** d'une recette.
 *
 * ── Pourquoi une seconde passe, alors que `polishCooklang` existe ────────────
 *
 * `polishCooklang` réécrit le document entier, jetons compris : le prompt lui
 * demande explicitement de corriger « les noms d'ingrédients ». C'est utile sur
 * un brouillon brut, et dangereux ensuite, pour deux raisons :
 *
 *  - le nom écrit dans `@nom{}` est l'**identité** de l'ingrédient — celle dont
 *    dépendent l'appariement nutritionnel, la liste de courses, l'index de
 *    recherche et les catégories. Le corriger le casse ;
 *  - et le correctif ne tiendrait pas : `rewriteCooklangWithReferentials`
 *    réécrit chaque jeton depuis le référentiel au prochain enregistrement.
 *
 * Cette passe-ci ne touche donc **que le texte entre les jetons**. Chaque
 * `@nom{…}`, `#matériel{…}`, `~minuteur{…}`, chaque ligne de métadonnée `>>`,
 * chaque en-tête de section `== … ==` et chaque référence d'image ressort
 * **identique, octet pour octet**.
 *
 * ── Comment la sûreté est obtenue ────────────────────────────────────────────
 *
 * Pas en demandant au modèle d'être prudent — en ne lui donnant pas de quoi
 * nuire. Il ne reçoit jamais le document : il reçoit une **liste numérotée de
 * fragments de prose**, et doit rendre la même liste corrigée. Le réassemblage
 * est fait ici, mécaniquement. Trois garde-fous, tous vérifiables :
 *
 *  1. **le compte** : une liste d'une autre longueur est rejetée en bloc ;
 *  2. **les caractères de balisage** : un fragment qui revient avec `@`, `#`,
 *     `~`, `{` ou `}` alors qu'il n'en avait pas est ignoré — le modèle a
 *     inventé un jeton ;
 *  3. **la longueur** : un fragment qui double ou disparaît est ignoré. Une
 *     correction orthographique ne réécrit pas une phrase.
 *
 * Un fragment rejeté garde sa version d'origine. Une passe n'est jamais
 * partiellement appliquée sans qu'on le sache : le nombre de fragments retenus
 * et refusés est rendu à l'appelant.
 */

import { callModel } from "../ai/router";
import { GEMINI_PROSE_POLISH_PROMPT } from "./prompts";
import { textPart, type ModelCallContext } from "../ai/types";

/** Marqueurs de balisage : leur apparition dans un fragment corrigé le disqualifie. */
const MARKUP_CHARS = /[@#~{}]/;

/** Lignes rendues telles quelles : métadonnées, sections, images. */
function isProtectedLine(line: string): boolean {
  const trimmed = line.trimStart();
  return (
    trimmed.startsWith(">>") ||
    trimmed.startsWith("==") ||
    trimmed.startsWith("![") ||
    trimmed.startsWith("--")
  );
}

/** Un jeton CookLang, ou une image markdown, dans une ligne de prose. */
const TOKEN_RE =
  /(@[^{@#~\n]+\{[^}]*\}|#[^{@#~\n]+\{[^}]*\}|~[^{@#~\s]*\{[^}]*\}|!\[[^\]]*\]\([^)]+\))/g;

/** Le découpage d'un CookLang en morceaux figés et fragments corrigibles. */
export interface ProseSplit {
  /** Morceaux dans l'ordre. `null` marque l'emplacement d'un fragment. */
  frame: Array<string | null>;
  /** Les fragments de prose, dans l'ordre des `null` du cadre. */
  segments: string[];
}

/**
 * Sépare le texte corrigible du reste.
 *
 * Un fragment n'est retenu que s'il contient au moins une lettre : les espaces,
 * la ponctuation isolée et les nombres n'ont rien à corriger et n'ont pas à
 * coûter des jetons.
 */
export function splitProse(cooklang: string): ProseSplit {
  const frame: Array<string | null> = [];
  const segments: string[] = [];

  const lines = cooklang.split("\n");
  lines.forEach((line, index) => {
    const suffix = index < lines.length - 1 ? "\n" : "";

    if (isProtectedLine(line) || line.trim() === "") {
      frame.push(line + suffix);
      return;
    }

    let cursor = 0;
    for (const match of line.matchAll(TOKEN_RE)) {
      const start = match.index ?? 0;
      if (start > cursor) pushProse(line.slice(cursor, start));
      frame.push(match[0]);
      cursor = start + match[0].length;
    }
    if (cursor < line.length) pushProse(line.slice(cursor));
    frame.push(suffix);
  });

  function pushProse(text: string): void {
    if (/\p{L}/u.test(text)) {
      frame.push(null);
      segments.push(text);
      return;
    }
    frame.push(text);
  }

  return { frame, segments };
}

/** Ce qu'une passe a retenu, et ce qu'elle a refusé. */
export interface ProsePolishResult {
  cooklang: string;
  /** Fragments réellement corrigés. */
  applied: number;
  /** Fragments rendus par le modèle mais refusés par les garde-fous. */
  rejected: number;
  /** Vrai quand la réponse était inexploitable : rien n'a été changé. */
  abandoned: boolean;
}

/**
 * Réassemble le document à partir des fragments corrigés.
 *
 * Fonction pure — c'est elle qui porte les garde-fous, et c'est elle qui est
 * testée. Le modèle n'intervient pas ici.
 */
export function reassembleProse(split: ProseSplit, corrected: string[]): ProsePolishResult {
  // Le compte d'abord : une liste d'une autre longueur signifie que le modèle a
  // fusionné, coupé ou inventé des fragments. Rien n'est applicable.
  if (corrected.length !== split.segments.length) {
    return {
      cooklang: rebuild(split, split.segments),
      applied: 0,
      rejected: 0,
      abandoned: true,
    };
  }

  let applied = 0;
  let rejected = 0;
  const kept = split.segments.map((original, i) => {
    const candidate = corrected[i];
    if (typeof candidate !== "string") {
      rejected++;
      return original;
    }
    if (candidate === original) return original;

    // Un jeton inventé : le modèle a débordé sur le balisage.
    if (MARKUP_CHARS.test(candidate) && !MARKUP_CHARS.test(original)) {
      rejected++;
      return original;
    }
    // Une phrase réécrite : une correction orthographique ne change pas la
    // longueur du simple au double.
    const ratio = candidate.trim().length / Math.max(1, original.trim().length);
    if (ratio < 0.5 || ratio > 2) {
      rejected++;
      return original;
    }
    // Espacement de bord : on garantit **au moins** celui d'origine, sans
    // l'imposer. Le supprimer collerait le mot au jeton (« la#poêle ») ; le
    // figer interdirait la correction même qu'on vient chercher — « l'poêle »
    // devient « la poêle », et cette réparation ajoute un espace là où
    // l'apostrophe n'en demandait aucun.
    let text = candidate;
    const leading = original.match(/^\s*/)?.[0] ?? "";
    const trailing = original.match(/\s*$/)?.[0] ?? "";
    if (leading && !/^\s/.test(text)) text = leading + text;
    if (trailing && !/\s$/.test(text)) text = text + trailing;
    applied++;
    return text;
  });

  return { cooklang: rebuild(split, kept), applied, rejected, abandoned: false };
}

function rebuild(split: ProseSplit, segments: string[]): string {
  let next = 0;
  return split.frame.map((piece) => (piece === null ? segments[next++] : piece)).join("");
}

/**
 * Corrige la prose d'une recette. Rend le document inchangé si la réponse du
 * modèle n'est pas exploitable — jamais une version à moitié appliquée.
 */
export async function polishRecipeProse(
  apiKey: string,
  cooklang: string,
  ctx: ModelCallContext,
): Promise<ProsePolishResult> {
  const split = splitProse(cooklang);
  if (split.segments.length === 0) {
    return { cooklang, applied: 0, rejected: 0, abandoned: false };
  }

  const numbered = split.segments.map((s, i) => `${i + 1}. ${s}`).join("\n");
  const result = await callModel({
    parts: [textPart(`${GEMINI_PROSE_POLISH_PROMPT}\n\n---\n${numbered}`)],
    ctx: { ...ctx, feature: "prose_polish", timeoutMs: 2 * 60 * 1000 },
    outputSchema: {
      name: "prose_polish",
      schema: {
        type: "object",
        properties: {
          segments: { type: "array", items: { type: "string" } },
        },
        required: ["segments"],
      },
    },
  });

  let corrected: unknown;
  try {
    corrected = JSON.parse(result.text).segments;
  } catch {
    corrected = null;
  }
  if (!Array.isArray(corrected)) {
    return { cooklang, applied: 0, rejected: 0, abandoned: true };
  }

  return reassembleProse(split, corrected as string[]);
}
