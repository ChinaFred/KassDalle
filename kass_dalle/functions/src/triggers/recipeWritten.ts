/**
 * onRecipeWritten — déclencheur unique sur `recipes/{recipeId}`.
 *
 * Deux déclencheurs écoutaient autrefois ce même document : l'un recalculait
 * les produits d'achat, l'autre la nutrition. Chacun réécrivait la recette à la
 * fin de son travail, donc chacun réveillait l'autre. Une seule sauvegarde de
 * recette déclenchait ainsi quatre invocations de fonctions 512 MiB — trois de
 * trop, dont deux ne servaient qu'à constater qu'il n'y avait rien à faire.
 *
 * Les gardes communes (suppression, type de page, empreinte des ingrédients)
 * sont évaluées une fois ici, puis les traitements partent ensemble. Ils
 * restent indépendants : l'échec de l'un ne prive pas la recette des autres.
 * Le rôle dans un repas et les durées estimées échappent à la garde
 * d'empreinte : voir plus bas.
 * Les allergènes de la recette se déduisent en dernier, une fois les
 * ingrédients neufs examinés par la chaîne nutrition.
 */

import { onDocumentWritten } from "firebase-functions/v2/firestore";
import { getFirestore } from "firebase-admin/firestore";
import { ANTHROPIC_API_KEY, COLL_RECIPES, GEMINI_API_KEY, REGION } from "../config";
import { logError, newCorrelationId, qualify } from "../logging";
import {
  ingredientsFingerprint,
  recipeTriggerInputsFingerprint,
  type StoredIngredient,
} from "./recipeIngredients";
import { syncRecipePrivacy } from "./recipePrivacy";
import { ORIGINAL_TEXT_DOC_ID, SUBCOLL_ORIGINAL_TEXT } from "../pipeline/originalText";
import { refreshShoppingProducts } from "./recipeShoppingProducts";
import { syncRecipeNutrition } from "./recipeNutritionAutoSync";
import { syncRecipeMealRole } from "./recipeMealRoleAutoSync";
import { recipeAllergensMissing, syncRecipeAllergens } from "./recipeAllergensSync";
import { syncRecipeEstimatedTimes } from "./recipeEstimatedTimes";
import { onlyTitleKeyChanged, syncRecipeTitleKey } from "./recipeTitleKey";

export const onRecipeWritten = onDocumentWritten(
  {
    document: "recipes/{recipeId}",
    region: REGION,
    secrets: [GEMINI_API_KEY, ANTHROPIC_API_KEY],
    memory: "512MiB" as const,
    // La somme des deux anciens délais : les traitements partent en parallèle,
    // mais le plus lent (nutrition, 180 s) peut désormais devoir attendre son
    // tour derrière les appels Gemini de l'autre en cas de contention.
    timeoutSeconds: 300,
  },
  async (event) => {
    const after = event.data?.after;
    if (!after?.exists) {
      // Suppression : seul le texte d'origine d'une recette traduite reste à
      // retirer. Une sous-collection ne disparaît pas avec son document.
      await deleteOriginalText(event.params.recipeId as string);
      return;
    }

    const data = after.data() as Record<string, unknown>;
    const beforeData = event.data?.before?.data() as Record<string, unknown> | undefined;

    // Le scan d'où vient la recette, quand elle vient d'un scan.
    //
    // Ce déclencheur part sur une écriture Firestore : rien, dans l'événement,
    // ne dit qu'un import l'a provoquée. Le pipeline écrit donc `scan_id` sur
    // la recette, et c'est le seul fil entre les deux. Sans lui, la nutrition
    // et les courses d'un import formaient un groupe de journaux sans lien
    // avec lui, et leur coût — la moitié de celui d'un scan — n'était pas
    // additionné avec le sien.
    //
    // Une recette écrite à la main n'en a pas, et c'est normal : elle ne vient
    // d'aucun scan.
    const scanId = typeof data.scan_id === "string" && data.scan_id ? data.scan_id : undefined;

    // ── La confidentialité descend du livre, avant tout le reste ─────────────
    //
    // Avant la garde de type de page : une page technique rangée dans un livre
    // privé est aussi privée qu'une recette. Avant la garde d'empreinte :
    // celle-ci ne connaît que les entrées des recalculs coûteux, et `book_id`
    // n'en fait pas partie — l'y ajouter relancerait nutrition et courses à
    // chaque rangement de bibliothèque.
    await syncRecipePrivacy({
      recipeId: after.id,
      data,
      beforeData,
      correlationId: newCorrelationId(qualify("ecriture_recette", "confidentialite")),
      scanId,
    });

    // La clé de titre suit le titre, pour toute page : une page technique se
    // compare aussi aux doublons de son livre. L'écriture qu'elle provoque
    // réveille ce déclencheur, qui la trouve alors à jour.
    await syncRecipeTitleKey({
      recipeId: after.id,
      data,
      correlationId: newCorrelationId(qualify("ecriture_recette", "cle_de_titre")),
      scanId,
    });

    // Une écriture qui ne change que `titre_key` (celle de la ligne
    // ci-dessus) ne touche aucune entrée des traitements suivants. Sans cette
    // sortie, le rôle dans un repas d'une recette non classée repartait une
    // seconde fois, et le backfill relançait un appel de modèle par recette
    // sans rôle.
    if (onlyTitleKeyChanged(beforeData, data)) return;

    // Ne traiter que les recettes (pas les pages techniques, notes, etc.)
    if (resolvePageType(data) !== "recipe") return;

    // ── Rôle dans un repas : avant la garde d'entrées, jamais filtré ─────────
    //
    // Une création manuelle sans clic « Suggérer », une recette de l'Explorer
    // IA ou une copie d'une recette non classée n'ont pas de `tags.meal_role`
    // — et aucune de ces trois écritures ne touche les ENTRÉES que la garde
    // ci-dessous protège. La classer ici, avant cette garde, évite qu'une
    // recette reste sans rôle tant que personne n'a changé ses ingrédients.
    //
    // Durées estimées : même place, pour la même raison. Une recette sans
    // durée n'a pas besoin qu'un ingrédient change pour en recevoir une, et
    // une durée saisie à la main doit retirer l'estimation. La décision ne
    // lit que la recette ; l'appel de modèle n'a lieu que si une durée manque
    // et qu'aucune estimation n'existe pour ce contenu (voir
    // `recipeEstimatedTimes.ts`). Les deux traitements partent ensemble : ils
    // n'écrivent pas les mêmes champs.
    await Promise.all([
      syncRecipeMealRole({
        recipeId: after.id,
        data,
        beforeData,
        correlationId: newCorrelationId(qualify("ecriture_recette", "role_repas")),
        scanId,
      }),
      syncRecipeEstimatedTimes({
        recipeRef: after.ref,
        data,
        correlationId: newCorrelationId(qualify("ecriture_recette", "durees_estimees")),
        scanId,
      }),
    ]);

    // ── La garde des recalculs coûteux, et il n'y en a plus d'autre ──────────
    //
    // Ce déclencheur écrit dans la collection qu'il écoute : chacune de ses
    // écritures le réveille. Il sort donc immédiatement quand l'écriture qui
    // l'a réveillé ne touche aucune de ses ENTRÉES — auquel cas elle ne peut
    // pas changer son résultat, et il n'y a rien à recalculer.
    //
    // La garde d'avant demandait « la nutrition existe-t-elle déjà ? ». Elle
    // répondait non pendant toute la durée du calcul, et pour toujours quand il
    // avait échoué : les échos repartaient alors en chaîne complète, chacun
    // écrivant à son tour, chacun en réveillant d'autres. En août, 499 réveils
    // ont appelé le modèle pour 68 recettes, dont une salve de 108 en treize
    // minutes.
    //
    // Une création n'a pas de `before` : elle passe toujours.
    const isCreation = !event.data?.before?.exists;
    const allergensMissing = recipeAllergensMissing(data);
    if (
      !isCreation &&
      recipeTriggerInputsFingerprint(data) === recipeTriggerInputsFingerprint(beforeData)
    ) {
      // Allergènes : une recette antérieure au champ le reçoit à sa prochaine
      // écriture, quelle qu'elle soit. Sans appel de modèle — cette branche
      // reçoit aussi les échos d'un calcul en cours, qui examine déjà les
      // ingrédients (voir `recipeAllergensSync.ts`). Une fois le champ posé,
      // l'écho de cette écriture-ci ne repasse plus par ici.
      if (allergensMissing) {
        await syncRecipeAllergens({
          recipeRef: after.ref,
          data,
          correlationId: newCorrelationId(qualify("ecriture_recette", "allergenes")),
          scanId,
        });
      }
      return;
    }

    const ingredients = (data.ingredients as StoredIngredient[] | undefined) ?? [];
    const beforeIngredients = (beforeData?.ingredients as StoredIngredient[] | undefined) ?? [];
    const ingredientsChanged =
      ingredientsFingerprint(ingredients) !== ingredientsFingerprint(beforeIngredients);

    // Une écriture de recette, un traitement — et le titre dit LEQUEL.
    //
    // Les deux suites tiraient chacune un `randomUUID()` : l'écran de logs y
    // voyait deux traitements anonymes, sans lien entre eux ni avec l'écriture
    // qui les avait déclenchés. Un import produisait ainsi des groupes intitulés
    // « shopping_products_refresh » que rien ne rattachait à la recette importée.
    //
    // Le fil unique a réglé ce point mais en a ouvert un autre : plusieurs
    // écritures de la même recette donnaient plusieurs groupes tous intitulés
    // « Après écriture d'une recette », sans qu'on puisse dire lequel avait
    // travaillé et lequel n'avait fait que constater. La précision le dit.
    // La précision nomme le TRAVAIL, pas l'état interne.
    //
    // « Premier calcul » ne disait pas de quoi : nutrition ? courses ? les
    // deux ? Un titre de groupe doit se lire sans connaître le code.
    // La cause nomme ce qui a bougé, et il n'y a plus que trois possibilités :
    // la recette vient de naître, ses ingrédients ont changé, ou l'une des
    // autres entrées. « rien-a-recalculer » a disparu avec les réveils qui le
    // portaient — on ne se réveille plus pour rien.
    const cause = isCreation
      ? "creation"
      : ingredientsChanged
        ? "ingredients-modifies"
        : "entrees-modifiees";
    const correlationId = newCorrelationId(qualify("ecriture_recette", cause));

    // Le drapeau `nutrition_hold` a disparu avec le besoin qui l'avait créé.
    //
    // L'import écrivait la recette avec les ingrédients bruts, la normalisait,
    // puis la réécrivait : ce déclencheur partait deux fois, et jetait le
    // travail de la première. Le drapeau lui demandait d'attendre. Depuis la
    // transcription en deux passes, la normalisation a lieu AVANT l'écriture et
    // la recette n'est écrite qu'une fois — il n'y a plus rien à attendre.
    const args = { after, data, ingredientsChanged, correlationId, scanId };
    const outcomes = await Promise.allSettled([
      refreshShoppingProducts(args),
      syncRecipeNutrition({ after, data, cause, correlationId, scanId }),
    ]);

    const labels = ["refreshShoppingProducts", "syncRecipeNutrition"];
    outcomes.forEach((outcome, i) => {
      if (outcome.status !== "rejected") return;
      logError({
        message: `onRecipeWritten: ${labels[i]} a échoué`,
        errorDescription:
          outcome.reason instanceof Error ? outcome.reason.message : String(outcome.reason),
        moduleType: "DESIGN",
        correlationId,
        scanId,
        extra: { recipeId: after.id },
      });
    });

    // Allergènes : APRÈS la nutrition, qui vient de créer les documents des
    // ingrédients neufs et de les faire examiner (`allergens_auto`). Ce qui
    // suit n'appelle aucun modèle : l'union des jugements du référentiel. Une
    // modification des portions ou du texte seuls ne change rien aux
    // allergènes d'une recette qui les porte déjà.
    if (isCreation || ingredientsChanged || allergensMissing) {
      await syncRecipeAllergens({ recipeRef: after.ref, data, correlationId, scanId });
    }
  },
);

/**
 * Type de page d'une recette, champ Firestore d'abord, métadonnée CookLang
 * ensuite.
 *
 * Le backend ne lisait que `page_type`. Or le client accepte aussi
 * `>> page_type:` dans le CookLang, et n'écrit le champ Firestore que lorsqu'il
 * vaut autre chose que `recipe` : une page dont le type ne vivait que dans son
 * CookLang était donc traitée ici comme une recette, et recevait un calcul
 * nutritionnel Gemini qu'elle n'aurait jamais dû déclencher.
 */
export function resolvePageType(data: Record<string, unknown>): string {
  const field = (data.page_type as string | undefined)?.trim();
  if (field) return field;

  const cooklang = (data.raw_cooklang as string | undefined) ?? "";
  const match = /^>>\s*page_type\s*:\s*(.+)$/im.exec(cooklang);
  return match ? match[1].trim().toLowerCase() : "recipe";
}

/**
 * Retire le texte d'origine d'une recette qu'on vient de supprimer.
 *
 * Sans condition sur `langue_origine` : le champ a pu être retiré avant la
 * suppression, et supprimer un document absent ne fait rien. Best-effort : un
 * échec laisse un document orphelin, que les règles ne laissent plus lire
 * puisque la recette n'existe plus.
 */
async function deleteOriginalText(recipeId: string): Promise<void> {
  try {
    await getFirestore()
      .collection(COLL_RECIPES)
      .doc(recipeId)
      .collection(SUBCOLL_ORIGINAL_TEXT)
      .doc(ORIGINAL_TEXT_DOC_ID)
      .delete();
  } catch (err) {
    await logError({
      message: "Texte d'origine non supprimé avec sa recette",
      errorDescription: err instanceof Error ? err.message : String(err),
      moduleType: "IMPORT",
      correlationId: newCorrelationId(),
      extra: { recipeId },
    });
  }
}
