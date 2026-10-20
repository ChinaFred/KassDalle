import { test } from "node:test";
import assert from "node:assert/strict";
import { TASK_QUEUE_COVER_FUNCTION, TASK_QUEUE_FUNCTION, taskQueueFunctionFor } from "../config";

test("une couverture de livre va dans sa propre file", () => {
  assert.equal(taskQueueFunctionFor("bookCoverScan"), TASK_QUEUE_COVER_FUNCTION);
});

test("les pages, le livre entier, les liens et un type absent restent dans la file des pages", () => {
  for (const type of ["recipeScan", "bookDocumentScan", "urlImport", undefined, null, ""]) {
    assert.equal(taskQueueFunctionFor(type), TASK_QUEUE_FUNCTION);
  }
});

test("les deux files sont deux fonctions distinctes", () => {
  assert.notEqual(TASK_QUEUE_COVER_FUNCTION, TASK_QUEUE_FUNCTION);
});
