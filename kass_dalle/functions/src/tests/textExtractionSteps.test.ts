/**
 * Les étapes annoncées pendant la conversion d'un texte collé.
 *
 * Ce que ces tests verrouillent : chaque étape est annoncée AVANT son appel de
 * modèle, dans l'ordre réel ; la traduction n'est annoncée que pour un texte
 * écrit dans une autre langue ; un échec d'envoi d'un message ne fait pas
 * échouer la conversion ; un client en flux parti arrête la conversion avant
 * l'appel de modèle suivant, un appel classique jamais. L'écran de création affiche ces étapes : une étape
 * annoncée à tort ou dans le désordre lui ferait afficher un travail qui n'a
 * pas lieu.
 */

import { test, describe } from "node:test";
import assert from "node:assert/strict";

import {
  TextExtractionCancelledError,
  extractRecipeFromText,
  type TextExtractionPasses,
  type TextExtractionStep,
} from "../gemini/extractor";
import type { PageTranscription, TranscribedRecipe } from "../gemini/transcription";
import type { TaggedRecipe } from "../gemini/tagging";
import { progressSender } from "../callable/_streaming";
import type { ModelCallContext } from "../ai/types";

const ctx = { userId: "u1", correlationId: "c1" } as ModelCallContext;

function recipe(langue: string): TranscribedRecipe {
  return {
    langue,
    titre: "Omelette",
    introduction: "",
    lecturesIncertaines: [],
    page: null,
    portions: 2,
    tempsPreparation: null,
    tempsCuisson: null,
    tempsRepos: null,
    difficulte: null,
    sectionsIngredients: [{ titre: "", lignes: ["3 oeufs"] }],
    sectionsEtapes: [{ titre: "", etapes: ["Battez les oeufs."] }],
    notes: [],
  };
}

function transcription(recettes: TranscribedRecipe[]): PageTranscription {
  return {
    pageType: recettes.length > 0 ? "recipe" : "no_recipe",
    titre: "Omelette",
    page: null,
    raison: "",
    document: "",
    recettes,
  };
}

function tagged(): TaggedRecipe {
  return {
    cooklang: ">> titre: Omelette\nBattez les @oeufs{3}.",
    ingredients: [{ brut: "3 oeufs", section: "", nom: "oeufs", qte: "3", unite: "", note: "" }],
    cuisines: [],
    dishTypes: [],
    mealRole: null,
    contains: [],
    suggestedSides: [],
    mainProtein: null,
    mainStarch: null,
    mainIngredientsChecked: false,
    styles: [],
    stylesChecked: false,
  };
}

/**
 * Passes factices : chacune note son appel dans [journal], à la suite des
 * étapes annoncées, pour vérifier que l'annonce précède l'appel.
 */
function fakePasses(langue: string, journal: string[], recettes?: TranscribedRecipe[]) {
  const passes: TextExtractionPasses = {
    transcribe: async () => {
      journal.push("appel:transcription");
      return transcription(recettes ?? [recipe(langue)]);
    },
    translate: async (lue) => {
      journal.push("appel:traduction");
      return { ...recipe("fr"), traduction: { langue: lue.langue ?? "", recette: lue } };
    },
    tag: async () => {
      journal.push("appel:balisage");
      return tagged();
    },
    log: async () => undefined,
  };
  return passes;
}

function recorder(journal: string[]) {
  const steps: TextExtractionStep[] = [];
  const onStep = (step: TextExtractionStep) => {
    steps.push(step);
    journal.push(`etape:${step.etape}`);
  };
  return { steps, onStep };
}

describe("extractRecipeFromText — étapes annoncées", () => {
  test("texte en français : lecture puis balisage, sans traduction", async () => {
    const journal: string[] = [];
    const { steps, onStep } = recorder(journal);
    const out = await extractRecipeFromText("texte", ctx, { onStep }, fakePasses("fr", journal));
    assert.deepEqual(steps, [{ etape: "lecture" }, { etape: "balisage" }]);
    assert.deepEqual(journal, [
      "etape:lecture",
      "appel:transcription",
      "etape:balisage",
      "appel:balisage",
    ]);
    assert.ok(out);
    assert.equal(out.langueOrigine, undefined);
  });

  test("texte en anglais : lecture, traduction avec sa langue, balisage", async () => {
    const journal: string[] = [];
    const { steps, onStep } = recorder(journal);
    const out = await extractRecipeFromText("texte", ctx, { onStep }, fakePasses("en-GB", journal));
    assert.deepEqual(steps, [
      { etape: "lecture" },
      { etape: "traduction", langue: "en" },
      { etape: "balisage" },
    ]);
    assert.deepEqual(journal, [
      "etape:lecture",
      "appel:transcription",
      "etape:traduction",
      "appel:traduction",
      "etape:balisage",
      "appel:balisage",
    ]);
    assert.ok(out);
    assert.equal(out.langueOrigine, "en-GB");
  });

  test("aucune recette : seule la lecture est annoncée", async () => {
    const journal: string[] = [];
    const { steps, onStep } = recorder(journal);
    const out = await extractRecipeFromText(
      "texte",
      ctx,
      { onStep },
      fakePasses("fr", journal, []),
    );
    assert.equal(out, null);
    assert.deepEqual(steps, [{ etape: "lecture" }]);
  });

  test("sans rappel : la conversion rend le même résultat", async () => {
    const journal: string[] = [];
    const out = await extractRecipeFromText("texte", ctx, {}, fakePasses("fr", journal));
    assert.ok(out);
    assert.deepEqual(journal, ["appel:transcription", "appel:balisage"]);
  });

  test("un envoi qui échoue est journalisé, et la conversion continue", async () => {
    const journal: string[] = [];
    const failures: unknown[] = [];
    const channel = progressSender<TextExtractionStep>(
      {
        sendChunk: async () => {
          throw new Error("client parti");
        },
        signal: new AbortController().signal,
      },
      true,
      async (error, chunk) => {
        failures.push({ error: (error as Error).message, chunk });
      },
    );
    const out = await extractRecipeFromText(
      "texte",
      ctx,
      { onStep: channel.send, shouldStop: channel.clientGone },
      fakePasses("it", journal),
    );
    assert.ok(out);
    assert.deepEqual(journal, ["appel:transcription", "appel:traduction", "appel:balisage"]);
    assert.deepEqual(failures, [
      { error: "client parti", chunk: { etape: "lecture" } },
      { error: "client parti", chunk: { etape: "traduction", langue: "it" } },
      { error: "client parti", chunk: { etape: "balisage" } },
    ]);
  });
});

describe("extractRecipeFromText — client parti", () => {
  test("signal déjà interrompu : aucune passe n'est appelée", async () => {
    const journal: string[] = [];
    const aborted = new AbortController();
    aborted.abort();
    const channel = progressSender<TextExtractionStep>(
      { sendChunk: async () => false, signal: aborted.signal },
      true,
      async () => assert.fail("aucun échec d'envoi attendu"),
    );
    await assert.rejects(
      extractRecipeFromText(
        "texte",
        ctx,
        { onStep: channel.send, shouldStop: channel.clientGone },
        fakePasses("fr", journal),
      ),
      (e: unknown) => e instanceof TextExtractionCancelledError && e.etape === "lecture",
    );
    assert.deepEqual(journal, []);
  });

  test("client parti pendant la lecture : le balisage n'est pas appelé", async () => {
    const journal: string[] = [];
    const controller = new AbortController();
    const passes = fakePasses("fr", journal);
    const transcribe = passes.transcribe;
    passes.transcribe = async (...args) => {
      const out = await transcribe(...args);
      controller.abort();
      return out;
    };
    const channel = progressSender<TextExtractionStep>(
      { sendChunk: async () => !controller.signal.aborted, signal: controller.signal },
      true,
      async () => assert.fail("aucun échec d'envoi attendu"),
    );
    await assert.rejects(
      extractRecipeFromText(
        "texte",
        ctx,
        { onStep: channel.send, shouldStop: channel.clientGone },
        passes,
      ),
      (e: unknown) => e instanceof TextExtractionCancelledError && e.etape === "balisage",
    );
    assert.deepEqual(journal, ["appel:transcription"]);
  });

  test("sendChunk rend false sans signal interrompu : arrêt avant la passe", async () => {
    const journal: string[] = [];
    const channel = progressSender<TextExtractionStep>(
      { sendChunk: async () => false, signal: new AbortController().signal },
      true,
      async () => assert.fail("aucun échec d'envoi attendu"),
    );
    await assert.rejects(
      extractRecipeFromText(
        "texte",
        ctx,
        { onStep: channel.send, shouldStop: channel.clientGone },
        fakePasses("fr", journal),
      ),
      TextExtractionCancelledError,
    );
    assert.deepEqual(journal, []);
  });

  test("appel classique : jamais d'arrêt, même signal interrompu", async () => {
    const journal: string[] = [];
    const aborted = new AbortController();
    aborted.abort();
    const channel = progressSender<TextExtractionStep>(
      { sendChunk: async () => false, signal: aborted.signal },
      false,
      async () => undefined,
    );
    const out = await extractRecipeFromText(
      "texte",
      ctx,
      { onStep: channel.send, shouldStop: channel.clientGone },
      fakePasses("fr", journal),
    );
    assert.ok(out);
    assert.deepEqual(journal, ["appel:transcription", "appel:balisage"]);
  });
});

describe("progressSender", () => {
  test("client en flux : chaque message part, dans l'ordre", async () => {
    const sent: unknown[] = [];
    const channel = progressSender<string>(
      {
        sendChunk: async (chunk) => {
          sent.push(chunk);
          return true;
        },
        signal: new AbortController().signal,
      },
      true,
      async () => assert.fail("aucun échec attendu"),
    );
    await channel.send("a");
    await channel.send("b");
    assert.deepEqual(sent, ["a", "b"]);
    assert.equal(channel.clientGone(), false);
  });

  test("appel classique ou réponse absente : rien n'est envoyé", async () => {
    const sent: unknown[] = [];
    const response = {
      sendChunk: async (chunk: string) => {
        sent.push(chunk);
        return true;
      },
      signal: new AbortController().signal,
    };
    await progressSender<string>(response, false, async () => undefined).send("a");
    await progressSender<string>(undefined, true, async () => undefined).send("b");
    assert.deepEqual(sent, []);
  });
});
