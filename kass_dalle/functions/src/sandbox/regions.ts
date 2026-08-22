/**
 * Détection des zones imagées d'une page — bac à sable.
 *
 * DÉRIVÉ de `gemini/detector.ts`, pas branché dessus. Le détecteur de
 * production cherche des *photographies culinaires dans un livre* et rejette
 * explicitement les schémas et les dessins. Sur une page de notes manuscrites,
 * il rend zéro zone. Ce fichier lui emprunte sa méthode — quatre coins en
 * repère 0-1000, réponse en JSON pur — et change ce qu'il cherche.
 *
 * Rien ici n'est importé par la production. Voir la section « Bac à sable » de
 * `CLAUDE.md` : dériver oui, modifier non.
 */

import { askModel, type SandboxModelChoice } from "./model";
import type { SandboxEngine } from "./page";
import { filePart, textPart, type ModelCallContext } from "../ai/types";
import { logAiText, logError } from "../logging";

/** Un coin, en repère normalisé 0-1000, dans l'ordre [y, x]. */
export type Corner = [number, number];

/**
 * Quatre coins : haut-gauche, haut-droit, bas-droit, bas-gauche.
 *
 * L'ordre décide quel côté du résultat sera le haut. Deux coins intervertis
 * rendent une découpe nette et retournée.
 */
export type Quad = [Corner, Corner, Corner, Corner];

/** Ce que la zone contient, tel que le modèle le qualifie. */
export type RegionKind = "photo" | "dessin" | "schema" | "texte_manuscrit" | "autre";

export interface DetectedRegion {
  quad: Quad;
  kind: RegionKind;
  /** Ce que la zone montre, en trois ou quatre mots. */
  label: string;
  /** Confiance du modèle, entre 0 et 1. */
  confidence: number;
}

export interface DetectedRegionsResult {
  regions: DetectedRegion[];
  /** Le moteur qui a réellement répondu — relevé sur la réponse. */
  engines: SandboxEngine[];
}

const KINDS: readonly RegionKind[] = ["photo", "dessin", "schema", "texte_manuscrit", "autre"];

const DETECT_PROMPT = String.raw`
TÂCHE : trouver TOUTES les zones IMAGÉES de cette page, et dire ce que chacune contient.

CE QUE TU REGARDES est une page à plat : une page de livre, une feuille
imprimée, ou des notes manuscrites. Elle a déjà été redressée.

CE QUE TU CHERCHES — quatre natures, et une zone appartient à une seule :
- "photo"          : une photographie imprimée ou collée.
- "dessin"         : un dessin, un croquis, une illustration au trait, une
                     aquarelle. Fait à la main ou imprimé, peu importe.
- "schema"         : un schéma, un plan, un diagramme, un tableau dessiné —
                     de la géométrie porteuse d'information, pas une image.
- "texte_manuscrit": un bloc d'écriture à la main. Une annotation dans la marge
                     en est un.
- "autre"          : imagé, mais aucune des quatre natures ci-dessus.

CE QUE TU NE CHERCHES PAS :
- le texte imprimé courant : titres, paragraphes, listes d'ingrédients,
  numéros de page, en-têtes. Ne les liste JAMAIS.
- les filets, cadres décoratifs, puces, logos et culs-de-lampe.
- la page elle-même : une zone qui couvre presque toute l'image est presque
  toujours fausse.

COMPTER D'ABORD, CADRER ENSUITE :
1. Balaye la page et COMPTE les zones imagées distinctes.
2. Une grille de vignettes vaut une zone PAR case. Une grille 3×3 vaut 9 zones.
3. Une grande image ne se découpe pas : elle vaut UNE zone.
4. Pour chaque zone, repère ses quatre coins réels.

CADRAGE : serre au bord de la zone. Pas de marge de papier autour, pas de
légende, pas la zone voisine. Les zones ne doivent pas se chevaucher.

COORDONNÉES — la partie qu'on rate.

Repère NORMALISÉ, indépendant de la taille de l'image :
  • le HAUT vaut 0, le BAS vaut 1000 ;
  • la GAUCHE vaut 0, la DROITE vaut 1000 ;
  • chaque coin s'écrit [y, x] — la VERTICALE D'ABORD.

Ni pixels, ni pourcentages, ni valeurs entre 0 et 1 : des entiers entre 0 et 1000.

Les quatre coins dans cet ordre : haut-gauche, haut-droit, bas-droit,
bas-gauche — le sens des aiguilles d'une montre en partant du coin supérieur
gauche DE LA ZONE, pas de l'image. Donne-les tels que tu les VOIS, de travers
s'ils le sont. C'est le programme qui redressera.

RÉPONSE : UNIQUEMENT un tableau JSON, sans markdown ni explication.
Un objet par zone :
[{"quad":[[y,x],[y,x],[y,x],[y,x]],"kind":"photo","label":"gâteau au chocolat","confidence":0.9}]
ou [] si la page ne porte aucune zone imagée.
`;

/**
 * Extrait le tableau JSON d'une réponse de modèle.
 *
 * Copié de `gemini/client.ts` — trois lignes, contre un import qui tirerait le
 * SDK Gemini dans ce module.
 */
function extractJsonArray(text: string): string {
  const cleaned = text.replace(/```json?|```/g, "").trim();
  const match = cleaned.match(/\[[\s\S]*\]/);
  return match ? match[0] : cleaned;
}

function clamp1000(value: unknown): number | null {
  const n = typeof value === "number" ? value : Number(value);
  if (!Number.isFinite(n)) return null;
  return Math.min(1000, Math.max(0, Math.round(n)));
}

function parseQuad(raw: unknown): Quad | null {
  if (!Array.isArray(raw) || raw.length !== 4) return null;
  const corners: Corner[] = [];
  for (const corner of raw) {
    if (!Array.isArray(corner) || corner.length !== 2) return null;
    const y = clamp1000(corner[0]);
    const x = clamp1000(corner[1]);
    if (y === null || x === null) return null;
    corners.push([y, x]);
  }
  return corners as Quad;
}

function parseKind(raw: unknown): RegionKind {
  const value = String(raw ?? "").toLowerCase();
  return (KINDS as readonly string[]).includes(value) ? (value as RegionKind) : "autre";
}

/** Aire du quadrilatère, en millionièmes de page (repère 0-1000). */
function quadArea(quad: Quad): number {
  let sum = 0;
  for (let i = 0; i < 4; i++) {
    const [y1, x1] = quad[i];
    const [y2, x2] = quad[(i + 1) % 4];
    sum += x1 * y2 - x2 * y1;
  }
  return Math.abs(sum) / 2;
}

/**
 * Détecte les zones imagées d'une page déjà redressée.
 *
 * Rend une liste vide plutôt qu'une erreur quand le modèle ne voit rien : une
 * page de texte pur est un cas normal, pas une panne.
 */
export async function detectPageRegions(args: {
  bytes: Buffer;
  mimeType: string;
  widthPx?: number;
  heightPx?: number;
  ctx: ModelCallContext;
  /** Le modèle imposé par l'expérience, `null` pour suivre la politique. */
  choice: SandboxModelChoice | null;
}): Promise<DetectedRegionsResult> {
  const { bytes, mimeType, widthPx, heightPx, ctx, choice } = args;

  const entete =
    widthPx && heightPx
      ? `L'image mesure ${widthPx} pixels de large et ${heightPx} de haut.\n\n`
      : "";

  const result = await askModel({
    parts: [filePart(mimeType, bytes), textPart(entete + DETECT_PROMPT)],
    ctx: { ...ctx, timeoutMs: 60_000, effort: "high" },
    choice,
  });

  const text = result.text.trim();

  // Le moteur est relevé sur la RÉPONSE, pas sur la demande : un repli
  // automatique change de fournisseur en cours de route.
  const engines: SandboxEngine[] = [
    { stage: "sandbox_detect_regions", provider: result.provider, model: result.model },
  ];

  // Le texte rendu par le modèle est la matière de l'expérience : sans lui, un
  // cadrage faux ne s'explique pas. Il part dans les journaux comme celui des
  // autres postes, et se retrouve sous « Texte IA ».
  await logAiText({
    stage: "sandbox_detect_regions",
    text,
    correlationId: ctx.correlationId,
    userId: ctx.userId,
    feature: ctx.feature,
    provider: result.provider,
    model: result.model,
    moduleType: "DESIGN",
  });

  if (!text || text === "[]") return { regions: [], engines };

  let parsed: unknown;
  try {
    parsed = JSON.parse(extractJsonArray(text));
  } catch (err) {
    await logError({
      message: "Bac à sable : réponse de détection illisible",
      errorDescription: err instanceof Error ? err.message : String(err),
      moduleType: "DESIGN",
      correlationId: ctx.correlationId,
      userId: ctx.userId,
      feature: ctx.feature,
    });
    return { regions: [], engines };
  }

  if (!Array.isArray(parsed)) return { regions: [], engines };

  const regions: DetectedRegion[] = [];
  for (const entry of parsed) {
    const source = entry as Record<string, unknown>;
    const quad = parseQuad(source?.quad);
    if (!quad) continue;

    // Une zone qui couvre plus des neuf dixièmes de la page est la page
    // elle-même. Le modèle la rend quand il ne trouve rien d'autre, et elle
    // ne se distingue d'une vraie pleine page que par sa fréquence.
    if (quadArea(quad) > 900_000) continue;

    const confidence = Number(source?.confidence);
    regions.push({
      quad,
      kind: parseKind(source?.kind),
      label: String(source?.label ?? "").slice(0, 120),
      confidence: Number.isFinite(confidence) ? Math.min(1, Math.max(0, confidence)) : 0,
    });
  }

  return { regions, engines };
}
