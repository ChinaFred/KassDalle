/**
 * Lecture des rapports CSP (`csp/reports.ts`).
 *
 * Verrouille les deux formats envoyés par les navigateurs, la réduction des
 * URL (origine pour la ressource bloquée, chemin pour le document, jamais de
 * requête ni de fragment), l'absence de l'extrait de script, le refus d'un
 * corps illisible, et le plafond de journalisation par fenêtre.
 */

import { test, describe } from "node:test";
import assert from "node:assert/strict";

import {
  CSP_REPORT_MAX_ITEMS,
  CspBodyError,
  CspLogBudget,
  cspReportFormat,
  parseCspReports,
  reduceBlocked,
  reduceDocument,
  reduceSource,
  violationKey,
} from "../csp/reports";

describe("cspReportFormat", () => {
  test("reconnaît les deux formats, paramètres de type ignorés", () => {
    assert.equal(cspReportFormat("application/csp-report"), "csp-report");
    assert.equal(cspReportFormat("application/reports+json; charset=utf-8"), "reports");
    assert.equal(cspReportFormat("Application/CSP-Report"), "csp-report");
    assert.equal(cspReportFormat("application/json"), "csp-report");
  });

  test("refuse les autres types et l'absence de type", () => {
    assert.equal(cspReportFormat("text/plain"), null);
    assert.equal(cspReportFormat("multipart/form-data"), null);
    assert.equal(cspReportFormat(undefined), null);
  });
});

describe("réduction des URL", () => {
  test("ressource bloquée : origine seule, requête et chemin retirés", () => {
    assert.equal(
      reduceBlocked("https://www.gstatic.com/flutter-canvaskit/abc/canvaskit.wasm?token=x#f"),
      "https://www.gstatic.com",
    );
    assert.equal(
      reduceBlocked("wss://s-usc1.firebaseio.com/.ws?ns=x"),
      "wss://s-usc1.firebaseio.com",
    );
  });

  test("ressource bloquée : mot-clé ou schéma seul", () => {
    assert.equal(reduceBlocked("inline"), "inline");
    assert.equal(reduceBlocked("eval"), "eval");
    assert.equal(reduceBlocked("data:image/png;base64,AAAA"), "data");
    assert.equal(reduceBlocked("blob:https://kassdale-6d948.web.app/uuid"), "blob");
    assert.equal(reduceBlocked(""), "(vide)");
    assert.equal(reduceBlocked(42), "(vide)");
    assert.equal(reduceBlocked("<script>alert(1)</script>"), "(illisible)");
  });

  test("document : chemin seul, sans origine, requête ni fragment", () => {
    assert.equal(
      reduceDocument("https://kassdale-6d948.web.app/recipes/abc?invite=secret#top"),
      "/recipes/abc",
    );
    assert.equal(reduceDocument("pas une url"), "(illisible)");
  });

  test("fichier source : origine et chemin, sans requête ; http(s) seulement", () => {
    assert.equal(
      reduceSource("https://kassdale-6d948.web.app/main.dart.js?v=1"),
      "https://kassdale-6d948.web.app/main.dart.js",
    );
    assert.equal(reduceSource("chrome-extension://abc/x.js"), null);
    assert.equal(reduceSource(undefined), null);
  });
});

describe("parseCspReports — format report-uri", () => {
  const body = {
    "csp-report": {
      "document-uri": "https://kassdale-6d948.web.app/books?x=1",
      "violated-directive": "script-src-elem",
      "effective-directive": "script-src-elem",
      "original-policy": "default-src 'self'; report-uri /csp-report",
      "blocked-uri": "inline",
      "line-number": 107,
      "column-number": 3,
      "source-file": "https://kassdale-6d948.web.app/",
      "script-sample": "var secret = 'ne pas journaliser';",
      disposition: "report",
    },
  };

  test("lit la violation, sans politique ni extrait", () => {
    const parsed = parseCspReports("csp-report", JSON.stringify(body));
    assert.deepEqual(parsed, [
      {
        directive: "script-src-elem",
        blocked: "inline",
        documentPath: "/books",
        sourceFile: "https://kassdale-6d948.web.app/",
        line: 107,
        column: 3,
        disposition: "report",
      },
    ]);
    assert.ok(!JSON.stringify(parsed).includes("secret"));
  });

  test("disposition : enforce ou report, sinon null", () => {
    const withDisposition = (d: unknown) =>
      parseCspReports(
        "csp-report",
        JSON.stringify({ "csp-report": { ...body["csp-report"], disposition: d } }),
      )?.[0]?.disposition;
    assert.equal(withDisposition("enforce"), "enforce");
    assert.equal(withDisposition("report"), "report");
    assert.equal(withDisposition("Votre compte est suspendu, voir https://exemple.test"), null);
    assert.equal(withDisposition(42), null);
  });

  test("violated-directive en repli, réduite à son nom", () => {
    const legacy = {
      "csp-report": {
        "document-uri": "https://kassdale-6d948.web.app/",
        "violated-directive": "connect-src 'self' https://*.googleapis.com",
        "blocked-uri": "https://example.com/x",
      },
    };
    const [v] = parseCspReports("csp-report", JSON.stringify(legacy)) ?? [];
    assert.equal(v.directive, "connect-src");
    assert.equal(v.blocked, "https://example.com");
    assert.equal(v.line, null);
  });

  test("JSON illisible : CspBodyError ; forme inattendue : null", () => {
    assert.throws(() => parseCspReports("csp-report", "{"), CspBodyError);
    assert.equal(parseCspReports("csp-report", "[]"), null);
    assert.equal(parseCspReports("csp-report", '{"autre": {}}'), null);
  });

  test("rapport sans directive lisible : aucune violation", () => {
    assert.deepEqual(parseCspReports("csp-report", '{"csp-report": {"blocked-uri": "eval"}}'), []);
  });
});

describe("parseCspReports — format report-to", () => {
  const item = (blockedURL: string) => ({
    type: "csp-violation",
    age: 10,
    url: "https://kassdale-6d948.web.app/planning?week=42",
    user_agent: "Mozilla/5.0",
    body: {
      documentURL: "https://kassdale-6d948.web.app/planning?week=42",
      blockedURL,
      effectiveDirective: "connect-src",
      originalPolicy: "default-src 'self'",
      sourceFile: "https://kassdale-6d948.web.app/flutter_bootstrap.js",
      sample: "",
      disposition: "enforce",
      lineNumber: 2,
      columnNumber: 10,
    },
  });

  test("lit les violations et ignore les autres types de rapport", () => {
    const parsed = parseCspReports(
      "reports",
      JSON.stringify([
        item("https://www.gstatic.com/flutter-canvaskit/r/canvaskit.wasm"),
        { type: "deprecation", body: { id: "x" } },
      ]),
    );
    assert.deepEqual(parsed, [
      {
        directive: "connect-src",
        blocked: "https://www.gstatic.com",
        documentPath: "/planning",
        sourceFile: "https://kassdale-6d948.web.app/flutter_bootstrap.js",
        line: 2,
        column: 10,
        disposition: "enforce",
      },
    ]);
  });

  test(`plafonné à ${CSP_REPORT_MAX_ITEMS} éléments par corps`, () => {
    const many = Array.from({ length: CSP_REPORT_MAX_ITEMS + 5 }, (_, i) =>
      item(`https://h${i}.example.com/`),
    );
    assert.equal(parseCspReports("reports", JSON.stringify(many))?.length, CSP_REPORT_MAX_ITEMS);
  });

  test("corps qui n'est pas un tableau : null", () => {
    assert.equal(parseCspReports("reports", JSON.stringify(item("inline"))), null);
  });
});

describe("CspLogBudget", () => {
  const v = (blocked: string) =>
    violationKey({
      directive: "connect-src",
      blocked,
      documentPath: "/",
      sourceFile: null,
      line: null,
      column: null,
      disposition: "report",
    });

  test("une violation déjà vue dans la fenêtre est comptée, pas rejournalisée", () => {
    const budget = new CspLogBudget(3, 60_000);
    assert.equal(budget.roll(0), null);
    assert.equal(budget.admit(v("a")), true);
    assert.equal(budget.admit(v("a")), false);
    assert.equal(budget.roll(30_000), null, "fenêtre en cours");
    assert.deepEqual(budget.roll(60_000), { dropped: 1, refused: 0 });
    assert.equal(budget.admit(v("a")), true, "nouvelle fenêtre : rejournalisée");
  });

  test("au-delà du plafond, les violations distinctes sont comptées", () => {
    const budget = new CspLogBudget(2, 60_000);
    budget.roll(0);
    assert.equal(budget.admit(v("a")), true);
    assert.equal(budget.admit(v("b")), true);
    assert.equal(budget.admit(v("c")), false);
    budget.refuse();
    assert.deepEqual(budget.roll(61_000), { dropped: 1, refused: 1 });
    assert.equal(budget.roll(200_000), null, "rien d'écarté : aucun relevé");
  });

  test("corps illisible : un seul journalisé par fenêtre, tous comptés", () => {
    const budget = new CspLogBudget(30, 60_000);
    budget.roll(0);
    budget.refuse();
    assert.equal(budget.refuseUnreadable(), true);
    assert.equal(budget.refuseUnreadable(), false);
    assert.deepEqual(budget.roll(60_000), { dropped: 0, refused: 3 });
    assert.equal(budget.refuseUnreadable(), true);
  });
});
