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
  | "violent_content"
  | "suggestive_content"
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
  | "manual_rejected"
  // Image déjà affichée hors des dossiers modérés, rangée sous `recipes/{id}/`
  // par le backfill « Ranger les illustrations » après validation de
  // l'administrateur : pas d'analyse (`illustrationFoldersMoveBackfillCallable.ts`).
  | "manual_folder_move";

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
  /**
   * Contenu sexuel explicite. C'est **lui seul** qui refuse sans appel.
   *
   * Il était autrefois confondu avec `racy` par un `max()` des deux. Le
   * résultat s'est vu : une photo de violence conjugale, où la personne porte
   * un débardeur, a été refusée pour « contenu sexuel explicite ». Le refus
   * était juste, le motif était faux — et un motif faux se propage : il
   * s'affiche à l'administrateur, oriente le réglage des seuils, et fait rater
   * la vraie raison.
   */
  adult: number | null;
  /**
   * Contenu suggestif. Une épaule nue, un maillot de bain, un décolleté.
   *
   * Ne refuse **jamais** à lui seul. Sur des photos ordinaires de personnes en
   * tenue d'été, il se déclenche constamment ; en faire un motif de refus,
   * c'est refuser une famille au barbecue.
   */
  racy: number | null;
  violence: number | null;
  medical: number | null;
  /** Paliers d'origine du moteur, conservés tels quels pour l'affichage. */
  raw: Record<string, string>;
  labels: ModerationLabel[];
}

export interface ModerationThresholds {
  /** Au-delà, le contenu sexuel explicite (`adult`) est refusé sans appel. */
  sexualReject: number;
  /**
   * Au-delà, et sans contexte culinaire, la violence est refusée — pas mise en
   * file.
   *
   * Aucune recette n'a besoin d'une scène de violence certaine. Envoyer
   * celles-là en revue obligerait un administrateur à les regarder pour
   * conclure ce que les signaux disaient déjà.
   */
  violenceReject: number;
  /** Au-delà, la violence demande un contexte pour passer. */
  violenceAlert: number;
  /**
   * Au-delà, un contenu suggestif part en revue — jamais au refus.
   *
   * Haut par construction : `racy` se déclenche sur des tenues d'été
   * ordinaires, et une file pleine de faux positifs n'est pas relue.
   */
  racyReview: number;
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
  violenceReject: 1,
  violenceAlert: 0.75,
  racyReview: 1,
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
 * **L'ordre porte tout le sens, et il n'est pas commutatif :**
 *
 * 1. contenu sexuel explicite (`adult`) → refusé. Aucun contexte ne le rattrape.
 * 2. violence **avec** contexte culinaire fort → publié. C'est la découpe de
 *    poulet, et elle passe avant tout jugement sur la violence.
 * 3. violence certaine, sans contexte → refusé, **pour violence**.
 * 4. violence probable, sans contexte → revue.
 * 5. contenu suggestif marqué → revue. Jamais un refus.
 * 6. sinon → publié.
 *
 * Le classement de la violence vient **avant** celui du suggestif, et c'est le
 * cœur d'un correctif : une scène de violence où quelqu'un porte un débardeur
 * déclenche `racy`, et l'ancienne règle — qui confondait `racy` et `adult` —
 * la refusait pour « contenu sexuel explicite ». Le verdict était bon, le motif
 * était faux, et un motif faux se lit à l'écran, oriente le réglage des seuils
 * et fait rater la vraie raison.
 *
 * Un critère que le moteur n'a pas su lire (`null`) ne vaut pas zéro : il part
 * en revue. Ne pas savoir n'autorise pas à publier.
 */
export function decideModeration(
  signals: ModerationSignals,
  thresholds: ModerationThresholds = DEFAULT_MODERATION_THRESHOLDS,
): ModerationDecision {
  const culinary = culinaryContext(signals.labels, thresholds);

  if (signals.adult === null || signals.violence === null) {
    return { status: "manual_review", reason: "unreadable_signal", culinaryMatches: culinary };
  }

  if (signals.adult >= thresholds.sexualReject) {
    return { status: "rejected", reason: "sexual_explicit", culinaryMatches: culinary };
  }

  // Le contexte culinaire est évalué AVANT le refus pour violence : une
  // découpe de volaille est une scène violente pour le moteur, et c'est
  // l'arbitrage assumé du projet qu'elle passe.
  if (signals.violence >= thresholds.violenceAlert && culinary.length > 0) {
    return { status: "approved", reason: "culinary_context", culinaryMatches: culinary };
  }

  if (signals.violence >= thresholds.violenceReject) {
    return { status: "rejected", reason: "violent_content", culinaryMatches: culinary };
  }

  if (signals.violence >= thresholds.violenceAlert) {
    return {
      status: "manual_review",
      reason: "violence_no_culinary_context",
      culinaryMatches: culinary,
    };
  }

  // Le suggestif ne refuse jamais seul. Il passe en dernier, une fois la
  // violence classée : sinon il volerait le motif à une image dont le vrai
  // problème est ailleurs.
  if (signals.racy !== null && signals.racy >= thresholds.racyReview && culinary.length === 0) {
    return { status: "manual_review", reason: "suggestive_content", culinaryMatches: culinary };
  }

  return { status: "approved", reason: "no_signal", culinaryMatches: culinary };
}
