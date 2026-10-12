/**
 * Lire une page web de recette, sans modèle quand c'est possible.
 *
 * La plupart des sites de cuisine publient leur recette en données
 * structurées : un bloc `<script type="application/ld+json">` au format
 * `schema.org/Recipe`, que les moteurs de recherche lisent. Quand il est
 * complet — un titre, des ingrédients, des étapes —, la recette se projette
 * telle quelle dans la forme que rend la transcription (`TranscribedRecipe`),
 * sans appel de modèle : la passe 1 n'a rien à recopier, le site l'a déjà fait.
 *
 * Sinon, on extrait le texte principal de la page (sans scripts, menus,
 * pied de page) et il suit la chaîne du texte collé.
 *
 * Tout est pur ici, et testé par `tests/recipePage.test.ts` sur des pages
 * réelles réduites (`tests/fixtures/web/`).
 */

import { normalizeLanguageCode, type TranscribedRecipe } from "../gemini/transcription";

/** Une recette `schema.org/Recipe` lue dans la page, champs bruts. */
export interface JsonLdRecipe {
  name: string;
  description: string;
  ingredients: string[];
  /** Étapes groupées : un groupe sans titre quand la page n'en a pas. */
  stepSections: Array<{ titre: string; etapes: string[] }>;
  recipeYield: number | null;
  prepTime: string | null;
  cookTime: string | null;
  totalTime: string | null;
  image: string | null;
  inLanguage: string | null;
}

/** Ce qu'une page donne avant tout appel de modèle. */
export interface ParsedRecipePage {
  /** Recettes trouvées en JSON-LD, dans l'ordre de la page. */
  recipes: JsonLdRecipe[];
  /** Blocs JSON-LD illisibles : journalisés par l'appelant, pas bloquants. */
  invalidBlocks: string[];
  /** Langue déclarée par `<html lang>`. */
  htmlLang: string | null;
  /** Titre `<title>` ou `og:title`. */
  title: string | null;
  /** `og:image`, absolue. */
  ogImage: string | null;
  /** Texte principal de la page, sans mobilier. */
  mainText: string;
}

/** Longueur maximale du texte principal transmis au modèle. */
export const MAIN_TEXT_MAX_CHARS = 60_000;

// ── Entités et balises ───────────────────────────────────────────────────────

const NAMED_ENTITIES: Record<string, string> = {
  amp: "&",
  lt: "<",
  gt: ">",
  quot: '"',
  apos: "'",
  nbsp: "\u00a0",
  eacute: "é",
  egrave: "è",
  ecirc: "ê",
  euml: "ë",
  agrave: "à",
  acirc: "â",
  auml: "ä",
  ccedil: "ç",
  icirc: "î",
  iuml: "ï",
  ocirc: "ô",
  ouml: "ö",
  ugrave: "ù",
  ucirc: "û",
  uuml: "ü",
  oelig: "œ",
  aelig: "æ",
  Eacute: "É",
  Egrave: "È",
  Agrave: "À",
  Ccedil: "Ç",
  deg: "°",
  frac12: "½",
  frac14: "¼",
  frac34: "¾",
  hellip: "…",
  rsquo: "’",
  lsquo: "‘",
  rdquo: "”",
  ldquo: "“",
  laquo: "«",
  raquo: "»",
  ndash: "–",
  mdash: "—",
  times: "×",
  middot: "·",
  euro: "€",
};

/** Décode les entités HTML nommées courantes et numériques. */
export function decodeEntities(text: string): string {
  return text.replace(
    /&(#x[0-9a-f]{1,6}|#\d{1,7}|[a-z][a-z0-9]{0,31});/gi,
    (match, body: string) => {
      if (body[0] === "#") {
        const code =
          body[1] === "x" || body[1] === "X"
            ? parseInt(body.slice(2), 16)
            : parseInt(body.slice(1));
        return Number.isFinite(code) && code > 0 && code < 0x110000
          ? String.fromCodePoint(code)
          : match;
      }
      return NAMED_ENTITIES[body] ?? match;
    },
  );
}

// ── Balayage linéaire ────────────────────────────────────────────────────────
//
// Une page vient d'un tiers. Les expressions régulières du type
// `<tag[\s\S]*?</tag>` ou `<[^>]*>` repartent de chaque `<` quand la balise
// n'est jamais fermée : sur trois mégaoctets de `<script` sans `</script>`, le
// temps devient quadratique et le job dépasse son délai. Tout ce qui découpe
// le HTML passe donc par `indexOf`, qui n'avance que dans un sens.

/** Longueur maximale d'une balise ouvrante lue. Au-delà, ce n'est pas une balise. */
const MAX_TAG_CHARS = 8192;

/**
 * Remplace chaque balise `<…>` par ce que rend `replace`, en un seul passage.
 * Un `<` sans `>` après lui laisse le reste tel quel.
 */
export function mapTags(html: string, replace: (tag: string) => string): string {
  const out: string[] = [];
  let pos = 0;
  for (;;) {
    const lt = html.indexOf("<", pos);
    if (lt < 0) break;
    const gt = html.indexOf(">", lt);
    if (gt < 0) break;
    out.push(html.slice(pos, lt), replace(html.slice(lt, gt + 1)));
    pos = gt + 1;
  }
  out.push(html.slice(pos));
  return out.join("");
}

/** Vrai si `lower` porte la balise ouvrante `<name` à `pos` (et non `<names`). */
function opensTag(lower: string, pos: number, name: string): boolean {
  const next = lower.charAt(pos + 1 + name.length);
  return next === "" || next === ">" || next === "/" || /\s/.test(next);
}

/** Position de la prochaine balise ouvrante `<name`, ou -1. */
function nextOpenTag(lower: string, name: string, from: number): number {
  let pos = from;
  for (;;) {
    const at = lower.indexOf(`<${name}`, pos);
    if (at < 0) return -1;
    if (opensTag(lower, at, name)) return at;
    pos = at + 1;
  }
}

/** Fin (`>`) de la balise ouvrante qui commence à `start`, ou -1 si absente ou trop longue. */
function tagEnd(html: string, start: number): number {
  const gt = html.indexOf(">", start);
  return gt < 0 || gt - start > MAX_TAG_CHARS ? -1 : gt;
}

/** Les balises ouvrantes `<name …>` de la page, sans leur contenu. */
function openTags(html: string, name: string): string[] {
  const lower = html.toLowerCase();
  const tags: string[] = [];
  let pos = 0;
  for (;;) {
    const at = nextOpenTag(lower, name, pos);
    if (at < 0) break;
    const end = tagEnd(html, at);
    if (end < 0) break;
    tags.push(html.slice(at, end + 1));
    pos = end + 1;
  }
  return tags;
}

/**
 * Les éléments `<name …>contenu</name>` : `[balise ouvrante, contenu]`. Un
 * élément jamais fermé arrête la lecture.
 */
function elements(html: string, name: string): Array<[string, string]> {
  const lower = html.toLowerCase();
  const out: Array<[string, string]> = [];
  let pos = 0;
  for (;;) {
    const at = nextOpenTag(lower, name, pos);
    if (at < 0) break;
    const end = tagEnd(html, at);
    if (end < 0) break;
    const close = lower.indexOf(`</${name}`, end);
    if (close < 0) break;
    out.push([html.slice(at, end + 1), html.slice(end + 1, close)]);
    pos = close + name.length + 2;
  }
  return out;
}

/** Retire les éléments `<name>…</name>` avec leur contenu ; un élément non fermé emporte la suite. */
export function removeElements(html: string, name: string): string {
  const lower = html.toLowerCase();
  const out: string[] = [];
  let pos = 0;
  for (;;) {
    const at = nextOpenTag(lower, name, pos);
    if (at < 0) break;
    out.push(html.slice(pos, at), " ");
    const close = lower.indexOf(`</${name}`, at);
    if (close < 0) return out.join("");
    const gt = html.indexOf(">", close);
    pos = gt < 0 ? html.length : gt + 1;
  }
  out.push(html.slice(pos));
  return out.join("");
}

/** Retire les commentaires `<!-- … -->` ; un commentaire non fermé emporte la suite. */
function removeComments(html: string): string {
  const out: string[] = [];
  let pos = 0;
  for (;;) {
    const at = html.indexOf("<!--", pos);
    if (at < 0) break;
    out.push(html.slice(pos, at), " ");
    const close = html.indexOf("-->", at + 4);
    if (close < 0) return out.join("");
    pos = close + 3;
  }
  out.push(html.slice(pos));
  return out.join("");
}

/** Contenu du premier `<name>` jusqu'au dernier `</name>`, ou `null`. */
function outerContent(html: string, name: string): string | null {
  const lower = html.toLowerCase();
  const at = nextOpenTag(lower, name, 0);
  if (at < 0) return null;
  const end = tagEnd(html, at);
  const close = lower.lastIndexOf(`</${name}`);
  if (end < 0 || close <= end) return null;
  return html.slice(end + 1, close);
}

/** Retire les balises d'un fragment, décode les entités, resserre les espaces. */
export function cleanText(fragment: string): string {
  return decodeEntities(mapTags(fragment, () => " "))
    .replace(/\s+/g, " ")
    .trim();
}

// ── JSON-LD ──────────────────────────────────────────────────────────────────

function isRecipeType(type: unknown): boolean {
  const types = Array.isArray(type) ? type : [type];
  return types.some(
    (t) => typeof t === "string" && /(^|[/:])Recipe$/i.test(t.trim()) && !/HowTo/i.test(t),
  );
}

/** Parcourt un nœud JSON-LD et collecte les objets `Recipe`, `@graph` et imbrication compris. */
function collectRecipes(node: unknown, out: Record<string, unknown>[], depth = 0): void {
  if (depth > 8 || node == null) return;
  if (Array.isArray(node)) {
    for (const item of node) collectRecipes(item, out, depth + 1);
    return;
  }
  if (typeof node !== "object") return;
  const obj = node as Record<string, unknown>;
  if (isRecipeType(obj["@type"])) {
    if (!out.includes(obj)) out.push(obj);
    return;
  }
  for (const [key, value] of Object.entries(obj)) {
    if (key === "@context") continue;
    if (value && typeof value === "object") collectRecipes(value, out, depth + 1);
  }
}

function asText(value: unknown): string {
  if (typeof value === "string") return cleanText(value);
  if (typeof value === "number") return String(value);
  if (Array.isArray(value)) return value.map(asText).filter(Boolean).join(" ");
  if (value && typeof value === "object") {
    const o = value as Record<string, unknown>;
    return asText(o.text ?? o.name ?? o["@value"] ?? "");
  }
  return "";
}

function asTextList(value: unknown): string[] {
  if (value == null) return [];
  if (typeof value === "string") {
    // Certaines pages mettent toute la liste dans une chaîne, une ligne par ingrédient.
    return value
      .split(/\r?\n/)
      .map((s) => cleanText(s))
      .filter(Boolean);
  }
  if (Array.isArray(value)) return value.map(asText).filter(Boolean);
  const single = asText(value);
  return single ? [single] : [];
}

/** Les étapes, `HowToSection` / `HowToStep` / `ItemList` / texte. */
export function readInstructions(value: unknown): Array<{ titre: string; etapes: string[] }> {
  const sections: Array<{ titre: string; etapes: string[] }> = [];
  const loose: string[] = [];

  const stepsOf = (v: unknown, depth = 0): string[] => {
    if (depth > 6 || v == null) return [];
    if (typeof v === "string") {
      const text = v.replace(/<\/(p|li|div)>/gi, "\n").replace(/<br\s*\/?>/gi, "\n");
      return text
        .split(/\r?\n+/)
        .map((s) => cleanText(s))
        .filter(Boolean);
    }
    if (Array.isArray(v)) return v.flatMap((x) => stepsOf(x, depth + 1));
    if (typeof v === "object") {
      const o = v as Record<string, unknown>;
      if (o.itemListElement != null) return stepsOf(o.itemListElement, depth + 1);
      const text = asText(o.text ?? o.description ?? o.name ?? "");
      return text ? [text] : [];
    }
    return [];
  };

  const visit = (v: unknown, depth = 0): void => {
    if (depth > 6 || v == null) return;
    if (Array.isArray(v)) {
      for (const x of v) visit(x, depth + 1);
      return;
    }
    if (typeof v === "object") {
      const o = v as Record<string, unknown>;
      const types = Array.isArray(o["@type"]) ? o["@type"] : [o["@type"]];
      if (types.some((t) => typeof t === "string" && /HowToSection/i.test(t))) {
        const etapes = stepsOf(o.itemListElement ?? o.steps ?? []);
        if (etapes.length > 0) sections.push({ titre: asText(o.name ?? ""), etapes });
        return;
      }
    }
    loose.push(...stepsOf(v, depth + 1));
  };

  visit(value);
  if (loose.length > 0) sections.unshift({ titre: "", etapes: loose });
  return sections.filter((s) => s.etapes.length > 0);
}

/** Premier entier lu dans `recipeYield` : « 4 », « 4 personnes », ["4", "4 parts"]. */
export function readYield(value: unknown): number | null {
  const candidates = Array.isArray(value) ? value : [value];
  for (const c of candidates) {
    if (typeof c === "number" && Number.isFinite(c) && c > 0) return Math.round(c);
    if (typeof c === "string") {
      const m = /(\d+)/.exec(c);
      if (m) {
        const n = Number(m[1]);
        if (n > 0 && n < 1000) return n;
      }
    }
  }
  return null;
}

/** Première URL d'image : chaîne, tableau, `ImageObject`. */
export function readImage(value: unknown): string | null {
  if (typeof value === "string") return value.trim() || null;
  if (Array.isArray(value)) {
    for (const v of value) {
      const url = readImage(v);
      if (url) return url;
    }
    return null;
  }
  if (value && typeof value === "object") {
    const o = value as Record<string, unknown>;
    return readImage(o.url ?? o.contentUrl ?? null);
  }
  return null;
}

/**
 * Durée ISO 8601 (« PT1H30M », « P0DT20M ») en minutes, ou `null`.
 */
export function isoDurationMinutes(value: unknown): number | null {
  if (typeof value !== "string") return null;
  const m =
    /^P(?:(\d+(?:\.\d+)?)D)?(?:T(?:(\d+(?:\.\d+)?)H)?(?:(\d+(?:\.\d+)?)M)?(?:(\d+(?:\.\d+)?)S)?)?$/i.exec(
      value.trim(),
    );
  if (!m || value.trim().toUpperCase() === "P" || value.trim().toUpperCase() === "PT") return null;
  const [, d, h, min, s] = m;
  const total =
    Number(d ?? 0) * 1440 + Number(h ?? 0) * 60 + Number(min ?? 0) + Number(s ?? 0) / 60;
  return Number.isFinite(total) ? Math.round(total) : null;
}

/** « 90 » → « 1 h 30 min » ; « 20 » → « 20 min ». */
export function formatMinutes(minutes: number): string {
  if (minutes < 60) return `${minutes} min`;
  const h = Math.floor(minutes / 60);
  const m = minutes % 60;
  return m === 0 ? `${h} h` : `${h} h ${m} min`;
}

/** Une durée lisible : ISO 8601 convertie, texte libre gardé, zéro écarté. */
function readDuration(value: unknown): string | null {
  const minutes = isoDurationMinutes(value);
  if (minutes != null) return minutes > 0 ? formatMinutes(minutes) : null;
  if (typeof value === "string" && value.trim() && !/^P/i.test(value.trim())) {
    return cleanText(value);
  }
  return null;
}

function toJsonLdRecipe(obj: Record<string, unknown>): JsonLdRecipe {
  return {
    name: asText(obj.name ?? obj.headline ?? ""),
    description: asText(obj.description ?? ""),
    ingredients: asTextList(obj.recipeIngredient ?? obj.ingredients),
    stepSections: readInstructions(obj.recipeInstructions),
    recipeYield: readYield(obj.recipeYield ?? obj.yield),
    prepTime: readDuration(obj.prepTime),
    cookTime: readDuration(obj.cookTime),
    totalTime: readDuration(obj.totalTime),
    image: readImage(obj.image),
    inLanguage: typeof obj.inLanguage === "string" ? obj.inLanguage : null,
  };
}

/** Remplace les caractères de contrôle (code < 32) par une espace. */
function withoutControlChars(text: string): string {
  let out = "";
  for (const ch of text) out += ch.charCodeAt(0) < 32 ? " " : ch;
  return out;
}

/** Tous les blocs JSON-LD de la page, et leurs recettes. */
export function extractJsonLdRecipes(html: string): {
  recipes: JsonLdRecipe[];
  invalidBlocks: string[];
} {
  const found: Record<string, unknown>[] = [];
  const invalidBlocks: string[] = [];
  for (const [tag, content] of elements(html, "script")) {
    if ((attributesOf(tag).type ?? "").toLowerCase().trim() !== "application/ld+json") continue;
    const raw = content
      .replace(/^\s*<!--/, "")
      .replace(/-->\s*$/, "")
      .replace(/^\s*\/\/\s*<!\[CDATA\[/, "")
      .replace(/\/\/\s*\]\]>\s*$/, "")
      .trim();
    if (!raw) continue;
    let parsed: unknown;
    try {
      // Les retours à la ligne bruts dans une chaîne sont interdits en JSON,
      // et fréquents dans le JSON-LD écrit à la main.
      parsed = JSON.parse(withoutControlChars(raw));
    } catch (err) {
      // Pas avalé : le bloc et l'erreur remontent à l'appelant, qui les
      // journalise. Un bloc illisible n'empêche pas de lire les autres.
      invalidBlocks.push(
        `${err instanceof Error ? err.message : String(err)} — ${raw.slice(0, 80)}`,
      );
      continue;
    }
    collectRecipes(parsed, found);
  }
  return { recipes: found.map(toJsonLdRecipe), invalidBlocks };
}

/**
 * Bornes d'une recette projetée. Une page tierce peut publier un JSON-LD de
 * plusieurs mégaoctets : au-delà de ces bornes, ce n'est pas une recette qu'on
 * balise, et le job finit en `no_recipe` plutôt que d'envoyer le tout au modèle.
 */
export const JSON_LD_BOUNDS = {
  totalChars: 60_000,
  ingredients: 200,
  steps: 150,
  lineChars: 2_000,
} as const;

/** Vrai si la recette dépasse une des bornes de `JSON_LD_BOUNDS`. */
export function exceedsJsonLdBounds(r: JsonLdRecipe): boolean {
  const steps = r.stepSections.flatMap((s) => s.etapes);
  const lines = [
    r.name,
    r.description,
    ...r.ingredients,
    ...steps,
    ...r.stepSections.map((s) => s.titre),
  ];
  const total = lines.reduce((n, l) => n + l.length, 0);
  return (
    total > JSON_LD_BOUNDS.totalChars ||
    r.ingredients.length > JSON_LD_BOUNDS.ingredients ||
    steps.length > JSON_LD_BOUNDS.steps ||
    lines.some((l) => l.length > JSON_LD_BOUNDS.lineChars)
  );
}

/**
 * Vrai si la recette se projette sans modèle : un titre, des ingrédients, des
 * étapes, dans les bornes de `JSON_LD_BOUNDS`.
 */
export function isCompleteRecipe(r: JsonLdRecipe): boolean {
  return (
    r.name.length > 0 &&
    r.ingredients.length > 0 &&
    r.stepSections.some((s) => s.etapes.length > 0) &&
    !exceedsJsonLdBounds(r)
  );
}

/**
 * Projection déterministe d'une recette JSON-LD dans la forme de la
 * transcription. Rien n'est réécrit : les lignes de la page passent telles
 * quelles, et le balisage (passe 2) les traite comme une page de livre.
 */
export function projectJsonLdRecipe(r: JsonLdRecipe, htmlLang: string | null): TranscribedRecipe {
  const etapes = r.stepSections.reduce((n, s) => n + s.etapes.length, 0);
  return {
    titre: r.name,
    langue: normalizeLanguageCode(r.inLanguage ?? htmlLang ?? "fr"),
    introduction: r.description,
    inventaire: {
      sections: r.stepSections.map((s) => s.titre).filter(Boolean),
      lignesIngredients: r.ingredients.length,
      etapes,
    },
    lecturesIncertaines: [],
    page: null,
    portions: r.recipeYield,
    tempsPreparation: r.prepTime,
    tempsCuisson: r.cookTime,
    tempsRepos: null,
    difficulte: null,
    sectionsIngredients: [{ titre: "", lignes: r.ingredients }],
    sectionsEtapes: r.stepSections,
    notes: [],
  };
}

/**
 * Le texte d'une recette projetée, tel qu'on le joint comme document original
 * quand la page n'a pas de texte principal exploitable.
 */
export function recipeAsPlainText(r: JsonLdRecipe): string {
  const out: string[] = [r.name];
  if (r.description) out.push("", r.description);
  if (r.recipeYield != null) out.push("", `Portions : ${r.recipeYield}`);
  if (r.prepTime) out.push(`Préparation : ${r.prepTime}`);
  if (r.cookTime) out.push(`Cuisson : ${r.cookTime}`);
  out.push("", "Ingrédients :", ...r.ingredients.map((i) => `- ${i}`));
  for (const s of r.stepSections) {
    out.push("", s.titre ? `${s.titre} :` : "Préparation :");
    s.etapes.forEach((e, i) => out.push(`${i + 1}. ${e}`));
  }
  return out.join("\n");
}

// ── Méta-données et texte principal ──────────────────────────────────────────

const ATTRIBUTES_MAX_CHARS = 1_024;

/** Attributs d'une balise ouvrante, clés en minuscules. */
function attributesOf(tag: string): Record<string, string> {
  const attrs: Record<string, string> = {};
  // Une balise ouvrante utile tient en quelques centaines de caractères : on la
  // borne. Le nom d'attribut ne démarre qu'en début de mot et se lit d'un bloc
  // (groupe atomique émulé) : sans `=` derrière, l'expression ne revient pas en
  // arrière lettre par lettre, et la lecture reste linéaire sur une page piégée.
  const head = tag.slice(0, ATTRIBUTES_MAX_CHARS);
  for (const m of head.matchAll(
    /(?<![a-z_:-])(?=([a-z_:-]+))\1\s*=\s*("([^"]*)"|'([^']*)'|([^\s>]+))/gi,
  )) {
    attrs[m[1].toLowerCase()] = decodeEntities(m[3] ?? m[4] ?? m[5] ?? "");
  }
  return attrs;
}

/** Valeur d'une balise `<meta property|name=… content=…>`. */
export function metaContent(html: string, key: string): string | null {
  for (const tag of openTags(html, "meta")) {
    const a = attributesOf(tag);
    if ((a.property ?? a.name ?? "").toLowerCase() === key && a.content) return a.content.trim();
  }
  return null;
}

/** Attribut `lang` de `<html>`. */
export function htmlLangOf(html: string): string | null {
  const tag = openTags(html, "html")[0];
  if (!tag) return null;
  return attributesOf(tag).lang ?? null;
}

/** Résout une adresse relative ; `null` si elle n'est ni http ni https. */
export function absoluteHttpUrl(href: string | null, base: string): string | null {
  if (!href || !URL.canParse(href, base)) return null;
  const url = new URL(href, base);
  return url.protocol === "http:" || url.protocol === "https:" ? url.toString() : null;
}

/** Blocs retirés avec leur contenu : ce n'est jamais la recette. */
const NOISE_BLOCKS = [
  "script",
  "style",
  "noscript",
  "template",
  "svg",
  "iframe",
  "nav",
  "header",
  "footer",
  "aside",
  "form",
  "button",
  "select",
];

/**
 * Le texte principal d'une page : `<article>`, sinon `<main>`, sinon
 * `<body>`, sans le mobilier. Les blocs deviennent des lignes, les éléments
 * de liste des puces.
 */
export function extractMainText(html: string, maxChars = MAIN_TEXT_MAX_CHARS): string {
  let doc = removeComments(html);
  for (const tag of NOISE_BLOCKS) doc = removeElements(doc, tag);
  const candidates = [
    outerContent(doc, "article"),
    outerContent(doc, "main"),
    outerContent(doc, "body"),
    doc,
  ];
  let chosen = doc;
  for (const c of candidates) {
    if (c != null && toPlainText(c).length >= 200) {
      chosen = c;
      break;
    }
  }
  const text = toPlainText(chosen);
  return text.length > maxChars ? text.slice(0, maxChars) : text;
}

/** Balises fermantes qui terminent une ligne. */
const BLOCK_END = /^<\/(p|div|li|h[1-6]|tr|section|ul|ol|table|blockquote|dd|dt)\b/i;

function toPlainText(fragment: string): string {
  return decodeEntities(
    mapTags(fragment, (tag) => {
      if (/^<li\b/i.test(tag)) return "\n- ";
      if (/^<(br|hr)\b/i.test(tag)) return "\n";
      if (BLOCK_END.test(tag)) return "\n";
      return " ";
    }),
  )
    .split("\n")
    .map((l) => l.replace(/[ \t\u00a0]+/g, " ").trim())
    .filter((l) => l.length > 0 && l !== "-")
    .join("\n");
}

/** Titre d'une page : `og:title`, sinon `<title>`, sinon `null`. */
export function pageTitleOf(html: string): string | null {
  const titleElement = elements(html, "title")[0];
  return metaContent(html, "og:title") ?? (titleElement ? cleanText(titleElement[1]) : null);
}

/** Lit une page HTML entière. `pageUrl` sert à rendre les images absolues. */
export function parseRecipePage(html: string, pageUrl: string): ParsedRecipePage {
  const { recipes, invalidBlocks } = extractJsonLdRecipes(html);
  return {
    recipes: recipes.map((r) => ({ ...r, image: absoluteHttpUrl(r.image, pageUrl) })),
    invalidBlocks,
    htmlLang: htmlLangOf(html),
    title: pageTitleOf(html),
    ogImage: absoluteHttpUrl(metaContent(html, "og:image"), pageUrl),
    mainText: extractMainText(html),
  };
}
