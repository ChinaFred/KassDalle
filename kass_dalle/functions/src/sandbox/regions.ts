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
import { codeEffortFor } from "../ai/featureEfforts";
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
  /**
   * Ce qui délimite la zone, et ce qui prouve une coupure quand elle en
   * touche une autre.
   *
   * Une découpe erronée se lit ici avant de se voir : le modèle qui scinde une
   * photo pleine page en deux ne sait pas nommer ce qui les sépare.
   */
  boundedBy: string;
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
4. Pour chaque zone, encadre-la d'un rectangle DROIT.

UNE ZONE = UNE PHOTOGRAPHIE. C'est la définition, et elle tranche tout.

Une photographie est une prise de vue : une scène, un moment, un cadrage. Deux
photographies distinctes valent DEUX zones — **même si elles se touchent bord à
bord**, sans marge blanche entre elles. Le montage à fond perdu est courant en
édition culinaire : deux plats empilés l'un au-dessus de l'autre, sans le
moindre filet pour les séparer. Ça reste deux photos.

Le test est donc celui de la SCÈNE, jamais celui de l'espace blanc :

- la scène CONTINUE d'un bord à l'autre de la ligne que tu envisages ? Le même
  verre, la même nappe, la même table qui se prolonge, des assiettes qui se
  chevauchent, la même lumière et la même perspective ? Alors c'est **UNE
  SEULE** photographie, et ta ligne la découperait à tort.
- la scène CHANGE ? Un décor différent, un angle différent, un éclairage
  différent, ou une COUTURE NETTE où deux images se rencontrent sans que rien ne
  se poursuive ? Alors ce sont **DEUX** photographies.

**AVANT DE COUPER, NOMME LA PREUVE.** Pour tracer une ligne à l'intérieur d'un
bloc imagé continu, tu dois pouvoir désigner ce qui atteste la coupure : un
objet tranché qui ne se poursuit pas de l'autre côté, un bord de table qui ne
s'aligne pas, un fond qui change brutalement. Si tu ne peux pas le nommer, il
n'y a pas de coupure — c'est une seule photo.

DEUX PIÈGES, et ce sont les deux qu'on rencontre :

- **plusieurs plats ne font pas plusieurs photos.** Une photographie de cuisine
  montre couramment deux ou trois préparations dans la même scène, l'une au
  premier plan, l'autre derrière ou plus haut sur la table.
- **une légende qui nomme deux plats ne prouve rien.** « X (en haut) et Y »
  décrit le plus souvent UNE SEULE image où les deux figurent, X étant
  simplement placé plus haut dans le cadre. Ne compte jamais les zones d'après
  la légende.

CADRAGE : serre au bord de la zone. Pas de marge de papier autour, pas de
légende, pas la zone voisine. Les zones ne doivent pas se chevaucher.

Le rectangle est DROIT, et c'est normal : cette page a déjà été mise à plat et
remise à l'endroit. Une photo imprimée dessus est donc alignée sur ses bords.
Rien ici n'est de travers, tu n'as pas de perspective à décrire.

COORDONNÉES — la partie qu'on rate.

Repère NORMALISÉ, indépendant de la taille de l'image :
  • le HAUT de la page vaut 0, le BAS vaut 1000 ;
  • la GAUCHE vaut 0, la DROITE vaut 1000 ;
  • la boîte s'écrit [y_min, x_min, y_max, x_max] — la VERTICALE D'ABORD.

Ni pixels, ni pourcentages, ni valeurs entre 0 et 1 : des entiers de 0 à 1000.
Et forcément y_min < y_max, x_min < x_max.

RÉPONSE : UNIQUEMENT un tableau JSON, sans markdown ni explication. Un objet par
zone, avec ces cinq champs :

- "box"        : [y_min, x_min, y_max, x_max], entiers de 0 à 1000.
- "kind"       : "photo", "dessin", "schema", "texte_manuscrit" ou "autre".
- "label"      : ce que la zone montre, en trois ou quatre mots.
- "bounded_by" : ce qui délimite cette zone du reste de la page, en quelques
                 mots — « marge blanche sur les quatre côtés », « bord de la
                 page en haut et à droite, marge en bas ». Si la zone touche une
                 AUTRE zone imagée, dis ce qui prouve la séparation : l'objet
                 tranché, le fond qui change, la couture. Ce champ existe pour
                 rendre une coupure vérifiable ; une coupure qu'on ne sait pas
                 justifier ne doit pas être faite.
- "confidence" : un nombre entre 0 et 1.

Rends [] si la page ne porte aucune zone imagée. Aucun exemple rempli ne t'est
donné : il n'y a rien à recopier, réponds sur CETTE page.
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

/**
 * Lit une boîte droite et en fait un quadrilatère.
 *
 * On demandait auparavant les quatre coins libres, et le modèle les rendait
 * dans le désordre : le cadre dessiné se croisait en nœud papillon, alors que
 * les libellés, eux, étaient justes. Il voyait bien les zones, il plaçait mal
 * les sommets — le même défaut qu'à l'étape du cadrage, corrigé de la même
 * façon : lui demander ce qu'il sait faire.
 *
 * Et ici il n'y a rien à perdre. La page a déjà été mise à plat et remise à
 * l'endroit : une photo imprimée dessus est alignée sur ses bords. Un
 * quadrilatère libre n'exprimait aucune information qu'un rectangle n'exprime.
 *
 * Les bornes sont remises en ordre plutôt que rejetées : un modèle qui inverse
 * `y_min` et `y_max` a quand même désigné la bonne zone.
 */
function parseBoxAsQuad(raw: unknown): Quad | null {
  if (!Array.isArray(raw) || raw.length !== 4) return null;
  const values = raw.map(clamp1000);
  if (values.some((value) => value === null)) return null;

  const [a, b, c, d] = values as number[];
  const yMin = Math.min(a, c);
  const yMax = Math.max(a, c);
  const xMin = Math.min(b, d);
  const xMax = Math.max(b, d);

  // Une zone plus fine que deux pour cent de la page dans un sens n'est pas une
  // image : c'est une ligne de texte, un filet, ou une erreur de lecture.
  if (yMax - yMin < 20 || xMax - xMin < 20) return null;

  return [
    [yMin, xMin],
    [yMin, xMax],
    [yMax, xMax],
    [yMax, xMin],
  ];
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

  const { result, requested } = await askModel({
    parts: [filePart(mimeType, bytes), textPart(entete + DETECT_PROMPT)],
    ctx: { ...ctx, timeoutMs: 60_000, effort: codeEffortFor(ctx.feature) },
    choice,
  });

  const text = result.text.trim();

  // Le moteur est relevé sur la RÉPONSE, pas sur la demande : un repli
  // automatique change de fournisseur en cours de route.
  const engines: SandboxEngine[] = [
    {
      stage: "sandbox_detect_regions",
      provider: result.provider,
      model: result.model,
      ...(requested ? { requested } : {}),
    },
  ];

  // Le texte rendu par le modèle est la matière de l'expérience : sans lui, un
  // cadrage faux ne s'explique pas. Il part dans les journaux comme celui des
  // autres postes, et se retrouve sous « Texte IA ».
  await logAiText({
    stage: "sandbox_detect_regions",
    text,
    correlationId: ctx.correlationId,
    scanId: ctx.scanId,
    callId: result.callId,
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
    const quad = parseBoxAsQuad(source?.box);
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
      boundedBy: String(source?.bounded_by ?? "").slice(0, 160),
      confidence: Number.isFinite(confidence) ? Math.min(1, Math.max(0, confidence)) : 0,
    });
  }

  return { regions, engines };
}
