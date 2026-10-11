/**
 * Synchronisation nutrition d'une recette.
 *
 * Ce fichier exposait autrefois son propre déclencheur `onDocumentWritten` sur
 * `recipes/{recipeId}`, en parallèle de celui des produits d'achat. Deux
 * déclencheurs sur le même document, chacun réécrivant ce document, donc
 * chacun réveillant l'autre : quatre invocations de fonction 512 MiB pour une
 * seule sauvegarde de recette. Le traitement vit désormais sous le déclencheur
 * unique `onRecipeWritten`.
 */

import type { DocumentSnapshot } from "firebase-admin/firestore";
import { FieldValue, getFirestore } from "firebase-admin/firestore";

import { recipeBudgetUserId } from "../ai/budget";
import { COLL_NUTRITION_INGREDIENTS } from "../config";
import { logAiText, logError, logInfo } from "../logging";
import { normalizeIngredientCanonicalId } from "../nutrition/ingredientName";
import {
  getKnownUnitMetadata,
  isBareIngredientLine,
  resolveWeighingInput,
} from "../nutrition/quantityConversion";
import {
  resolveIngredientUnitFields,
  type UnitResolvedIngredient,
} from "../nutrition/ingredientUnitResolution";
import { hasPer100gValues } from "../nutrition/per100gEnrichment";
import {
  enrichUnknownIngredientsWithAI,
  enrichUnknownUnitsWithAI,
  estimateUsualPortionsWithAI,
} from "../nutrition/aiEnrichment";
import { upsertNutritionUnitReference } from "../nutrition/unitReference";
import {
  computeAndPersistRecipeNutrition,
  persistFailedNutritionSnapshot,
} from "../nutrition/recipeNutrition";
import { writeDocsMerged } from "../nutrition/firestoreBatch";
import {
  resolveShoppingProductsWithAI,
  type ShoppingAliasCandidate,
} from "../nutrition/shoppingAliases";
import { examineIngredientAllergens } from "../nutrition/allergenExamination";

import type { StoredIngredient } from "./recipeIngredients";

/**
 * Poste de coût du produit acheté d'un ingrédient NEUF, résolu ici même — à
 * distinguer de `backfill_shopping_aliases`, qui a rattrapé le passé (retiré le
 * 5 octobre 2026). Voir « Un poste d'IA vit à trois endroits » : ce nom
 * apparaît aussi dans `ROUTABLE_FEATURES` et `kFeatureCatalog`/`kFeatureProcess`.
 */
const SHOPPING_ALIAS_AUTO_FEATURE = "shopping_product_alias_auto";

/**
 * Poste de coût des allergènes d'un ingrédient pas encore examiné, posés ici
 * même — à distinguer de `backfill_allergens`, qui rattrape le passé. Même
 * règle des trois endroits que le produit acheté.
 */
const ALLERGENS_AUTO_FEATURE = "allergens_auto";

type NormalizedIngredientInput = UnitResolvedIngredient;

function toPositiveNumber(value: unknown): number | undefined {
  if (typeof value === "number" && Number.isFinite(value) && value > 0) {
    return value;
  }
  if (typeof value === "string") {
    const parsed = Number(value.replace(",", "."));
    if (Number.isFinite(parsed) && parsed > 0) {
      return parsed;
    }
  }
  return undefined;
}

/**
 * Recalcule la nutrition d'une recette et entretient les référentiels
 * (ingrédients, unités) à partir de ce que la recette déclare.
 *
 * Appelé par le déclencheur unique `onRecipeWritten`, qui a déjà écarté les
 * suppressions et les pages non-recette.
 */
export async function syncRecipeNutrition(args: {
  after: DocumentSnapshot;
  data: Record<string, unknown>;
  /**
   * Ce qui a provoqué ce recalcul, tel qu'il s'écrira dans les journaux.
   *
   * C'était un booléen `ingredientsChanged`. Il décidait de la garde et du
   * compteur de tentatives ; les deux ayant disparu, il ne servait plus qu'à
   * remplir une ligne de journal — et il ne savait pas dire d'où venait un
   * recalcul lancé par le rattrapage planifié.
   */
  cause: string;
  /** Traitement auquel ce recalcul appartient — fourni par `onRecipeWritten`. */
  correlationId: string;
  /** Scan de l'utilisateur d'où vient ce travail, quand il en vient un. */
  scanId?: string;
}): Promise<void> {
  const { after, data, cause, correlationId, scanId } = args;

  const ingredients = (data.ingredients as StoredIngredient[] | undefined) ?? [];

  const inputs: NormalizedIngredientInput[] = ingredients
    .filter((i) => (i.name ?? "").trim().length > 0)
    .map((i) => resolveIngredientUnitFields(i));

  const db = getFirestore();

  // Aucune garde ici, et c'est voulu.
  //
  // Elle vivait dans ce fichier et demandait « la nutrition existe-t-elle
  // déjà ? » — une question sur la SORTIE, donc fausse pendant tout le temps du
  // calcul et fausse à jamais après un échec. Elle a été remplacée par une
  // garde sur les ENTRÉES, à l'entrée du déclencheur
  // (`recipeTriggerInputsFingerprint`) : quand on arrive ici, une entrée a
  // réellement changé, il y a réellement du travail.
  //
  // Le compteur `nutrition_enrichment_attempts` et le drapeau
  // `nutrition_stale` ont disparu avec elle : ils ne servaient qu'à borner une
  // boucle qui n'existe plus, et ils ne la bornaient pas.

  // Jamais vide : une recette sans propriétaire s'impute au compte des
  // recettes orphelines, plafonné comme un autre (`ai/budget.ts`). Un uid vide
  // faisait passer l'appel hors de tout plafond.
  const userId = recipeBudgetUserId(data.created_by);

  // Le texte de la recette, tracé une fois qu'on sait qu'il y a du travail.
  //
  // Ces journaux ne portaient que des compteurs — treize ingrédients, douze
  // références mises à jour — et pas une ligne de la recette. Quand une recette
  // s'écarte du livre, ils ne permettaient pas de dire si le texte était déjà
  // abîmé en arrivant ici, ou s'il l'a été plus loin. Ce traitement ne touche
  // pas au texte : ce qu'on lit ici est ce qui sortait de l'étape précédente.
  //
  // La trace était AVANT la garde, donc émise à chaque réveil — y compris les
  // deux échos que ce déclencheur se provoque à lui-même en écrivant les
  // courses puis la nutrition. Trois groupes de journaux par recette, dont deux
  // ne disaient rien d'autre que « rien à faire », chacun traînant douze mille
  // caractères de recette. Un journal qui répète le texte pour dire qu'il ne
  // s'est rien passé rend illisibles ceux qui parlent.
  await logAiText({
    stage: "declencheur.entree",
    text: (data.raw_cooklang as string | undefined) ?? "",
    message: "Texte de la recette à l'entrée du déclencheur",
    moduleType: "DESIGN",
    correlationId,
    scanId,
    userId,
    extra: { recipeId: after.id, cause },
  });

  let createdRefs = 0;
  let updatedRefs = 0;
  let enriched = 0;
  let failedEnrichment = 0;
  let createdUnitRefs = 0;
  let updatedUnitRefs = 0;
  let unknownUnitRefs = 0;
  let convertibleInputs = 0;
  const invalidQuantities = new Set<string>();
  const unknownUnits = new Set<string>();

  try {
    if (inputs.length === 0) {
      await computeAndPersistRecipeNutrition({
        aiEnabled: true,
        recipeId: after.id,
        selectedPortions: toPositiveNumber(data.portions),
        correlationId,
        scanId,
      });

      await logInfo({
        message: "onRecipeNutritionAutoSync: recette sans ingrédients, nutrition recalculée",
        moduleType: "DESIGN",
        correlationId,
        scanId,
        userId,
        extra: { recipeId: after.id },
      });
      return;
    }

    for (const input of inputs) {
      // Même lecture que le calcul : « sel, pincée » et « poivre » tout court
      // n'écrivent pas de nombre, et l'écran de validation ne doit pas les
      // dénoncer comme des quantités abîmées alors qu'ils se pèsent.
      const weighing = resolveWeighingInput(input.name, input.qty, input.unit_canonical);
      const unit = input.unit;
      const effectiveUnit = weighing?.unit ?? input.unit_canonical;
      const unitMetadata = effectiveUnit ? getKnownUnitMetadata(effectiveUnit, input.name) : null;

      if (weighing == null) {
        invalidQuantities.add(`${input.name}|${input.qty}`);
      }

      if (!unitMetadata) {
        unknownUnits.add(`${input.name}|${unit || "(vide)"}`);
      }

      if (weighing != null && unitMetadata != null) {
        convertibleInputs++;
      }

      const unitForReference = input.unit_raw.length > 0 ? input.unit_raw : input.unit_canonical;
      if (!unitForReference) continue;
      try {
        const result = await upsertNutritionUnitReference({
          db,
          unitRaw: unitForReference,
          ingredientName: input.name,
          recipeId: after.id,
        });
        if (result.normalizedUnit == null) continue;
        if (result.created) {
          createdUnitRefs++;
        } else {
          updatedUnitRefs++;
        }
        if (!result.known) {
          unknownUnitRefs++;
        }
      } catch (err) {
        await logError({
          message: "onRecipeNutritionAutoSync: synchronisation référentiel unités échouée",
          moduleType: "DESIGN",
          correlationId,
          scanId,
          userId,
          errorDescription: err instanceof Error ? err.message : String(err),
          extra: { recipeId: after.id, unit: unitForReference },
        });
      }
    }

    // Enrichissement des unités sans poids — ici, et nulle part ailleurs.
    //
    // La normalisation posait la même question au même moment : un import
    // écrivait la recette, réveillant ce déclencheur, puis normalisait en
    // parallèle. Les deux trouvaient le référentiel vide au même instant et
    // interrogeaient le modèle deux fois pour la même unité. Deux fois la
    // facture, et des journaux où la même passe apparaissait en double sans
    // qu'on sache laquelle avait servi.
    //
    // Ce chemin-ci est le bon : il part sur TOUTES les écritures de recette —
    // import, saisie manuelle, modification — et c'est lui qui a besoin du
    // poids, quelques lignes plus bas, pour convertir les quantités.
    const unitCanonicalsSeen = [
      ...new Set(inputs.map((i) => i.unit_canonical).filter((u) => u.length > 0)),
    ];
    if (unitCanonicalsSeen.length > 0) {
      const unitIngredientNames = new Map<string, string[]>();
      for (const input of inputs) {
        const canonical = input.unit_canonical;
        const name = input.name.trim();
        if (!canonical || !name) continue;
        const list = unitIngredientNames.get(canonical) ?? [];
        if (!list.includes(name)) list.push(name);
        unitIngredientNames.set(canonical, list);
      }
      await enrichUnknownUnitsWithAI({
        unitCanonicals: unitCanonicalsSeen,
        userId,
        recipeId: after.id,
        correlationId,
        scanId,
        unitIngredientNames,
      });
    }

    const ingredientValidationState =
      invalidQuantities.size === 0 && unknownUnits.size === 0
        ? "ok"
        : convertibleInputs > 0
          ? "partial"
          : "unknown";

    // Ce déclencheur n'écrit PAS `ingredients` : ce champ appartient à la
    // normalisation, et lui seul. La résolution d'unité qu'on vient de faire
    // est un intermédiaire de calcul — la reposer sur la recette revenait à
    // disputer un champ dont personne ne relit le contenu, et à effacer au
    // passage la catégorie que la sauvegarde venait d'y écrire.
    await after.ref.set(
      {
        // Le compteur du rattrapage planifié repart de zéro : ce recalcul-ci
        // part d'entrées neuves, il n'a rien à voir avec les tentatives
        // infructueuses de la liste précédente.
        nutrition_catch_up_attempts: 0,
        nutrition_validation: {
          checked_at: FieldValue.serverTimestamp(),
          state: ingredientValidationState,
          checked_ingredients: inputs.length,
          convertible_ingredients: convertibleInputs,
          invalid_quantities: [...invalidQuantities].slice(0, 50),
          unknown_units: [...unknownUnits].slice(0, 50),
          unit_reference_sync: {
            created: createdUnitRefs,
            updated: updatedUnitRefs,
            unknown_observed: unknownUnitRefs,
          },
        },
      },
      { merge: true },
    );

    const aliasesByCanonical = new Map<string, Set<string>>();
    for (const input of inputs) {
      const canonicalId = normalizeIngredientCanonicalId(input.name);
      if (!canonicalId) continue;
      if (!aliasesByCanonical.has(canonicalId)) {
        aliasesByCanonical.set(canonicalId, new Set<string>());
      }
      aliasesByCanonical.get(canonicalId)!.add(input.name);
    }

    // Les ingrédients que CETTE écriture vient de créer — pas ceux qui
    // existaient déjà, dont le produit acheté a soit été résolu, soit
    // délibérément laissé vide par une correction admin. Un ingrédient neuf
    // n'a ni l'un ni l'autre : c'est lui, et lui seul, qui a besoin d'être
    // demandé au modèle.
    const newlyCreated: ShoppingAliasCandidate[] = [];

    for (const [canonicalId, aliasSet] of aliasesByCanonical.entries()) {
      const aliases = [...aliasSet];
      const docRef = db.collection("nutrition_ingredients").doc(canonicalId);
      try {
        await docRef.create({
          canonical_name: canonicalId.replace(/_/g, " "),
          aliases,
          per100g: {},
          source: "recipe_auto_sync",
          source_priority: ["recipe_auto_sync"],
          quality_status: "pending",
          seen_count: 1,
          first_seen_at: FieldValue.serverTimestamp(),
          last_seen_at: FieldValue.serverTimestamp(),
          last_seen_recipe_id: after.id,
          created_at: FieldValue.serverTimestamp(),
          updated_at: FieldValue.serverTimestamp(),
        });
        createdRefs++;
        newlyCreated.push({ id: canonicalId, name: aliases[0] ?? canonicalId.replace(/_/g, " ") });
      } catch (err) {
        const codeRaw = (err as { code?: unknown })?.code;
        const code =
          typeof codeRaw === "string" || typeof codeRaw === "number" ? String(codeRaw) : "";
        const alreadyExists = code.includes("already-exists") || code === "6";
        if (!alreadyExists) throw err;

        await docRef.set(
          {
            aliases: FieldValue.arrayUnion(...aliases),
            seen_count: FieldValue.increment(1),
            last_seen_at: FieldValue.serverTimestamp(),
            last_seen_recipe_id: after.id,
            updated_at: FieldValue.serverTimestamp(),
          },
          { merge: true },
        );
        updatedRefs++;
      }
    }

    // Allergènes des ingrédients de la recette pas encore examinés — neufs ou
    // antérieurs au champ. Ici, et pas avant : le document du référentiel
    // vient d'être créé juste au-dessus, et l'examen ne crée jamais de
    // document (voir `allergenExamination.ts`). En parallèle du produit
    // acheté, qui interroge le modèle au même moment : le délai du
    // déclencheur n'en souffre pas. Ne lève jamais ; `onRecipeWritten`
    // déduit ensuite le champ de la recette, sans appel.
    //
    // Échéance de 120 s : l'enrichissement per100g attend la fin de cet
    // examen avant de démarrer sa propre échéance, et le déclencheur n'a que
    // 300 s. Une recette de plusieurs centaines d'ingrédients neufs garde ses
    // derniers lots pour le backfill, au lieu de faire dépasser le délai.
    const allergensExamination = examineIngredientAllergens({
      ids: [...aliasesByCanonical.keys()],
      ctx: { correlationId, userId, scanId, feature: ALLERGENS_AUTO_FEATURE },
      deadlineMs: Date.now() + 120_000,
      extra: { recipeId: after.id },
    });

    // Produit acheté des ingrédients neufs — un appel de modèle, pour eux
    // seuls. « Beurre fondu » n'a pas encore de lien vers « beurre » dans le
    // référentiel ; sans cette passe, ce lien n'existerait qu'après un
    // backfill manuel, et la liste de courses afficherait le nom brut d'ici
    // là. Best-effort : un échec n'empêche jamais le calcul de nutrition qui
    // suit, l'ingrédient reste sans produit acheté et sera repris au
    // prochain backfill.
    if (newlyCreated.length > 0) {
      try {
        const resolutions = await resolveShoppingProductsWithAI(
          newlyCreated,
          { correlationId, userId, feature: SHOPPING_ALIAS_AUTO_FEATURE },
          (err, failedBatch) => {
            void logError({
              message: "onRecipeNutritionAutoSync: produit acheté — échec d'un lot",
              errorDescription: err instanceof Error ? err.message : String(err),
              moduleType: "DESIGN",
              correlationId,
              scanId,
              userId,
              extra: { recipeId: after.id, lot: failedBatch.map((c) => c.name) },
            });
          },
        );
        if (resolutions.length > 0) {
          const updates = new Map<string, Record<string, unknown>>();
          for (const r of resolutions) {
            updates.set(r.id, {
              shopping_product: r.product,
              shopping_product_source: "ai_estimated",
              updated_at: FieldValue.serverTimestamp(),
            });
          }
          await writeDocsMerged(COLL_NUTRITION_INGREDIENTS, updates);
        }
      } catch (err) {
        await logError({
          message: "onRecipeNutritionAutoSync: produit acheté des ingrédients neufs — échec",
          errorDescription: err instanceof Error ? err.message : String(err),
          moduleType: "DESIGN",
          correlationId,
          scanId,
          userId,
          extra: { recipeId: after.id, ids: newlyCreated.map((c) => c.id) },
        });
      }
    }

    const allergensReport = await allergensExamination;

    // Enrichissement per100g de TOUS les ingrédients de la recette qui n'en ont
    // pas. Ce traitement plafonnait à douze parce qu'il dépensait un appel
    // Gemini par ingrédient, séquentiellement : au treizième, la recette perdait
    // le reste de ses ingrédients sans un mot. Le lot rend le plafond inutile,
    // et l'échéance protège ce qui protégeait vraiment — le timeout de 300 s du
    // déclencheur, partagé avec le rafraîchissement des produits d'achat.
    const enrichmentDeadlineMs = Date.now() + 200_000;
    const candidateIds = [...aliasesByCanonical.keys()];
    enriched = await enrichUnknownIngredientsWithAI({
      ingredientRefIds: candidateIds,
      userId,
      recipeId: after.id,
      correlationId,
      scanId,
      deadlineMs: enrichmentDeadlineMs,
    });

    // Ce qui reste sans valeur après enrichissement : comptabilisé ici pour le
    // journal de fin, le détail par ingrédient étant déjà tracé en erreur.
    {
      const refs = candidateIds.map((id) => db.collection("nutrition_ingredients").doc(id));
      const snaps = refs.length > 0 ? await db.getAll(...refs) : [];
      for (const snap of snaps) {
        if (!snap.exists) continue;
        if (!hasPer100gValues((snap.data() as Record<string, unknown>).per100g)) {
          failedEnrichment++;
        }
      }
    }

    // Portion usuelle des lignes écrites sans quantité — « roquette »,
    // « parmesan pour râper dessus ». Sans elle ces lignes n'ont aucun poids et
    // sortent du calcul. Le déclencheur et le rattrapage passent tous deux par
    // ici : une recette déjà importée l'obtient à sa prochaine reprise, sans
    // passe dédiée. Best-effort — la fonction ne lève pas, et le calcul qui suit
    // n'attend qu'elle.
    await estimateUsualPortionsWithAI({
      ingredientNames: inputs
        .filter((i) => isBareIngredientLine(i.name, i.qty, i.unit_canonical))
        .map((i) => i.name),
      recipeId: after.id,
      correlationId,
      scanId,
      userId,
    });

    await computeAndPersistRecipeNutrition({
      aiEnabled: true,
      recipeId: after.id,
      selectedPortions: toPositiveNumber(data.portions),
      correlationId,
      scanId,
    });

    await logInfo({
      message: "onRecipeNutritionAutoSync: synchronisation nutrition terminée",
      moduleType: "DESIGN",
      correlationId,
      scanId,
      userId,
      extra: {
        recipeId: after.id,
        ingredientsCount: inputs.length,
        createdRefs,
        updatedRefs,
        createdUnitRefs,
        updatedUnitRefs,
        unknownUnitRefs,
        convertibleInputs,
        invalidQuantitiesCount: invalidQuantities.size,
        unknownUnitsCount: unknownUnits.size,
        enriched,
        failedEnrichment,
        allergens: allergensReport,
      },
    });
  } catch (err) {
    // L'échec s'écrit sur la recette, il ne se contente pas d'être journalisé.
    //
    // Sans cette écriture, la recette reste sans `nutrition` : l'écran affiche
    // exactement ce qu'affiche une recette pas encore calculée, et personne ne
    // sait qu'il s'est passé quelque chose. C'était aussi ce champ absent qui
    // faisait repartir la chaîne à chaque écriture suivante, du temps où la
    // garde interrogeait la sortie.
    await persistFailedNutritionSnapshot({
      recipeId: after.id,
      reason: err instanceof Error ? err.message : String(err),
      correlationId,
      scanId,
    });

    await logError({
      message: "onRecipeNutritionAutoSync: échec global (best-effort)",
      moduleType: "DESIGN",
      correlationId,
      scanId,
      userId,
      errorDescription: err instanceof Error ? err.message : String(err),
      extra: {
        recipeId: after.id,
        ingredientsCount: inputs.length,
        createdRefs,
        updatedRefs,
        createdUnitRefs,
        updatedUnitRefs,
        unknownUnitRefs,
        convertibleInputs,
        invalidQuantitiesCount: invalidQuantities.size,
        unknownUnitsCount: unknownUnits.size,
        enriched,
        failedEnrichment,
      },
    });
  }
}
