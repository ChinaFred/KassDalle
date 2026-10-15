import { test, describe } from "node:test";
import assert from "node:assert/strict";

import {
  chunk,
  isStaleTokenCode,
  notificationText,
  parseApkManifest,
  releaseKey,
} from "../release_notifications/rules";

describe("parseApkManifest", () => {
  test("lit la version et le numéro de build", () => {
    const r = parseApkManifest(
      '{"version":"0.23.81","build_number":"428","file":"app-release.apk"}',
    );
    assert.deepEqual(r, { version: "0.23.81", build: "428" });
  });

  test("accepte un numéro de build numérique", () => {
    assert.deepEqual(parseApkManifest('{"version":"1.0.0","build_number":7}'), {
      version: "1.0.0",
      build: "7",
    });
  });

  test("rejette index.html, un JSON sans version et un JSON non objet", () => {
    assert.equal(parseApkManifest("<!doctype html><html></html>"), null);
    assert.equal(parseApkManifest('{"build_number":"1"}'), null);
    assert.equal(parseApkManifest('{"version":""}'), null);
    assert.equal(parseApkManifest("[1]"), null);
    assert.equal(parseApkManifest("null"), null);
  });
});

describe("releaseKey et texte", () => {
  test("le build distingue deux APK de même version", () => {
    assert.notEqual(
      releaseKey({ version: "0.23.81", build: "428" }),
      releaseKey({ version: "0.23.81", build: "429" }),
    );
  });

  test("texte de la notification", () => {
    assert.deepEqual(notificationText({ version: "0.23.81", build: "428" }), {
      title: "Nouvelle version disponible",
      body: "Kass'Dalle v0.23.81 est prête à installer.",
    });
  });
});

describe("jetons et lots", () => {
  test("seuls les jetons désinstallés ou invalides sont supprimés", () => {
    assert.equal(isStaleTokenCode("messaging/registration-token-not-registered"), true);
    assert.equal(isStaleTokenCode("messaging/invalid-registration-token"), true);
    assert.equal(isStaleTokenCode("messaging/internal-error"), false);
    assert.equal(isStaleTokenCode(undefined), false);
  });

  test("chunk découpe en lots de taille donnée", () => {
    assert.deepEqual(chunk([1, 2, 3, 4, 5], 2), [[1, 2], [3, 4], [5]]);
    assert.deepEqual(chunk([], 2), []);
  });
});
