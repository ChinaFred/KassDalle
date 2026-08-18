/**
 * Règles de décision de la modération d'images.
 *
 * Fonctions **pures** : pas de réseau, pas d'horloge, pas de Firestore. C'est
 * ici que vit l'arbitrage, et c'est ce qui se rejoue dans les tests à partir de
 * `test-fixtures/image_moderation_rules.json`.
 *
 * Aucun jumeau Dart. Le client n'évalue rien : il reçoit un verdict. Écrire la
 * règle des deux côtés « par symétrie » ajouterait une divergence possible sans
 * rien rendre — c'est ce qu'ont montré les règles de créneau du planning, qui
 * ont fini par quitter le client.
 */

/** État d'une image après verdict. */
export type ModerationStatus = "approved" | "rejected" | "manual_review" | "pending";

/**
 * Motif de la décision.
 *
 * Ces clés sont durables : elles sont écrites sur les documents et relues par
 * l'écran d'administration des mois plus tard. Une clé retirée du code reste au
 * catalogue de libellés côté client, sinon les décisions déjà prises cessent de
 * s'expliquer.
 */
export type ModerationReason =
  | "sexual_explicit"
  | "violence_no_culinary_context"
  | "culinary_context"
  | "no_signal"
  | "moderation_disabled"
  // Images qui ne viennent pas d'une personne : produites par l'IA, ou livrées
  // avec l'application. Elles ne sont pas analysées — mais elles passent par le
  // même chemin, et le journal dit pourquoi elles sont passées.
  | "ai_generated"
  | "bundled_asset"
  | "unreadable_signal"
  | "engine_unavailable"
  | "manual_approved"
  | "manual_rejected";

/** Un label rendu par le moteur, avec sa confiance. */
export interface ModerationLabel {
  name: string;
  score: number;
}

/**
 * Ce que le moteur a vu, sous une forme neutre.
 *
 * Les scores sont normalisés `0..1`. `null` n'est pas `0` : il dit que le
 * moteur n'a pas su répondre sur ce critère. Les confondre ferait approuver sur
 * une ignorance.
 */
export interface ModerationSignals {
  sexual: number | null;
  violence: number | null;
  medical: number | null;
  /** Paliers d'origine du moteur, conservés tels quels pour l'affichage. */
  raw: Record<string, string>;
  labels: ModerationLabel[];
}

export interface ModerationThresholds {
  /** Au-delà, le contenu sexuel est refusé sans appel. */
  sexualReject: number;
  /** Au-delà, la violence demande un contexte pour passer. */
  violenceAlert: number;
  /** Score minimal pour qu'un label culinaire compte. */
  culinaryLabelScore: number;
  /** Nombre de labels culinaires qui font un contexte. */
  culinaryLabelCount: number;
  /** Score à partir duquel un seul label suffit. */
  culinaryStrongScore: number;
  /** Labels qui font un contexte culinaire, en minuscules. */
  culinaryLabels: string[];
}

/**
 * Défauts appliqués tant qu'`app_config/image_moderation` n'existe pas.
 *
 * Ce ne sont pas des « valeurs de repli » au sens de la règle du projet :
 * celle-ci vise les données qui doivent être exactes — un prix, un taux de
 * change — dont une constante périmée ferait mentir un montant. Un seuil de
 * modération est une décision, comme les plafonds de dépense quotidiens qui
 * protègent eux aussi avant tout réglage. L'absence de document ne doit pas
 * vouloir dire « aucune modération ».
 */
export const DEFAULT_MODERATION_THRESHOLDS: ModerationThresholds = {
  sexualReject: 0.75,
  violenceAlert: 0.75,
  culinaryLabelScore: 0.6,
  culinaryLabelCount: 2,
  culinaryStrongScore: 0.85,
  culinaryLabels: [
    "food",
    "cuisine",
    "dish",
    "recipe",
    "ingredient",
    "meat",
    "beef",
    "pork",
    "poultry",
    "chicken",
    "fish",
    "seafood",
    "vegetable",
    "fruit",
    "kitchen",
    "kitchen utensil",
    "cutting board",
    "kitchen knife",
    "cookware and bakeware",
    "cooking",
    "baking",
    "tableware",
    "plate",
    "dessert",
    "bread",
  ],
};

export interface ModerationDecision {
  status: ModerationStatus;
  reason: ModerationReason;
  /** Labels culinaires retenus — affichés en évidence dans l'administration. */
  culinaryMatches: string[];
}

/**
 * Vrai si les labels décrivent une scène de cuisine.
 *
 * Un seul label faible ne fait pas un contexte : c'est ce qui distingue une
 * cuisine d'une scène qui contiendrait un couteau.
 */
export function culinaryContext(
  labels: ModerationLabel[],
  thresholds: ModerationThresholds,
): string[] {
  const known = new Set(thresholds.culinaryLabels.map((l) => l.toLowerCase()));
  const matches = labels.filter(
    (l) => known.has(l.name.trim().toLowerCase()) && l.score >= thresholds.culinaryLabelScore,
  );
  if (matches.length === 0) return [];
  const strong = matches.some((l) => l.score >= thresholds.culinaryStrongScore);
  if (strong || matches.length >= thresholds.culinaryLabelCount) {
    return matches.map((l) => l.name);
  }
  return [];
}

/**
 * Verdict à partir des signaux.
 *
 * L'ordre n'est pas commutatif :
 *
 * 1. le contenu sexuel explicite est refusé — aucun contexte ne le rattrape ;
 * 2. la violence avec contexte culinaire fort passe, directement ;
 * 3. la violence sans contexte part en revue ;
 * 4. sinon, on approuve.
 *
 * Un critère que le moteur n'a pas su lire (`null`) ne vaut pas zéro : il part
 * en revue. Ne pas savoir n'autorise pas à publier.
 */
export function decideModeration(
  signals: ModerationSignals,
  thresholds: ModerationThresholds = DEFAULT_MODERATION_THRESHOLDS,
): ModerationDecision {
  const culinary = culinaryContext(signals.labels, thresholds);

  if (signals.sexual === null || signals.violence === null) {
    return { status: "manual_review", reason: "unreadable_signal", culinaryMatches: culinary };
  }

  if (signals.sexual >= thresholds.sexualReject) {
    return { status: "rejected", reason: "sexual_explicit", culinaryMatches: culinary };
  }

  if (signals.violence >= thresholds.violenceAlert) {
    if (culinary.length > 0) {
      return { status: "approved", reason: "culinary_context", culinaryMatches: culinary };
    }
    return {
      status: "manual_review",
      reason: "violence_no_culinary_context",
      culinaryMatches: culinary,
    };
  }

  return { status: "approved", reason: "no_signal", culinaryMatches: culinary };
}
