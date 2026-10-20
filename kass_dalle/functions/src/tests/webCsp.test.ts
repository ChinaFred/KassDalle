/**
 * Content Security Policy du web (`firebase.json`).
 *
 * La politique n'autorise aucun script en ligne par `'unsafe-inline'` : elle
 * nomme chacun par son empreinte SHA-256. Deux sources en produisent :
 *
 *  - les deux scripts de `web/index.html` (écran d'attente, service worker) ;
 *  - FlutterFire : `firebase_core_web` injecte un petit script en ligne par
 *    service Firebase, qui importe le SDK JavaScript depuis www.gstatic.com.
 *    Son texte dépend du service et de la version du SDK, et existe en deux
 *    variantes (avec ou sans Trusted Types, selon le navigateur).
 *
 * Un script modifié, ou une montée de FlutterFire, change l'empreinte : la
 * politique en mode bloquant refuserait alors le script, et l'application ne
 * démarrerait plus. Ce test échoue avant, et donne les empreintes à reporter.
 */

import { test, describe } from "node:test";
import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import * as fs from "node:fs";
import * as path from "node:path";

const ROOT = path.join(__dirname, "..", "..", "..");

/**
 * Version de `firebase_core_web` pour laquelle les empreintes FlutterFire ont
 * été calculées, et version du SDK JavaScript qu'elle charge
 * (`supportedFirebaseJsSdkVersion`, dans `lib/src/firebase_sdk_version.dart`
 * du paquet). Une montée de FlutterFire change les deux : relever la nouvelle
 * version du SDK dans le paquet, mettre à jour ces deux constantes, puis
 * reporter dans `firebase.json` les empreintes que ce test affiche.
 */
const FIREBASE_CORE_WEB_VERSION = "3.12.0";
const FIREBASE_JS_SDK_VERSION = "12.19.0";

/**
 * Les services injectés par FlutterFire : variable globale et fichier du SDK.
 * Un plugin FlutterFire web ajouté ou retiré change cette liste.
 */
const FLUTTERFIRE_SERVICES: Array<{ plugin: string; windowVar: string; file: string }> = [
  { plugin: "firebase_core_web", windowVar: "firebase_core", file: "firebase-app.js" },
  {
    plugin: "cloud_firestore_web",
    windowVar: "firebase_firestore",
    file: "firebase-firestore-pipelines.js",
  },
  { plugin: "cloud_functions_web", windowVar: "firebase_functions", file: "firebase-functions.js" },
  {
    plugin: "firebase_app_check_web",
    windowVar: "firebase_app_check",
    file: "firebase-app-check.js",
  },
  { plugin: "firebase_auth_web", windowVar: "firebase_auth", file: "firebase-auth.js" },
  {
    plugin: "firebase_messaging_web",
    windowVar: "firebase_messaging",
    file: "firebase-messaging.js",
  },
  { plugin: "firebase_storage_web", windowVar: "firebase_storage", file: "firebase-storage.js" },
];

function sha256(text: string): string {
  return `'sha256-${createHash("sha256").update(text, "utf8").digest("base64")}'`;
}

/** Les deux textes injectés par `injectSrcScript` (firebase_core_web 3.12.0), au caractère près. */
function flutterfireScripts(windowVar: string, url: string): string[] {
  const trustedTypes =
    `            window.ff_trigger_${windowVar} = async (callback) => {\n` +
    `              console.debug("Initializing Firebase ${windowVar}");\n` +
    `              callback(await import("${url}"));\n` +
    `            };\n` +
    `          `;
  const plain =
    `      window.ff_trigger_${windowVar} = async (callback) => {\n` +
    `        console.debug("Initializing Firebase ${windowVar}");\n` +
    `        callback(await import("${url}"));\n` +
    `      };\n` +
    `    `;
  return [trustedTypes, plain];
}

function readJson(relative: string): Record<string, unknown> {
  return JSON.parse(fs.readFileSync(path.join(ROOT, relative), "utf8")) as Record<string, unknown>;
}

interface HostingHeader {
  source: string;
  headers: Array<{ key: string; value: string }>;
}
interface HostingRewrite {
  source: string;
  destination?: string;
  function?: { functionId: string; region: string };
}

const hosting = readJson("firebase.json").hosting as {
  headers: HostingHeader[];
  rewrites: HostingRewrite[];
};
const globalHeaders = hosting.headers.find((h) => h.source === "**")?.headers ?? [];
const cspHeader = globalHeaders.find((h) => /^Content-Security-Policy(-Report-Only)?$/.test(h.key));

function directive(name: string): string[] {
  const policy = cspHeader?.value ?? "";
  const found = policy
    .split(";")
    .map((d) => d.trim().split(/\s+/))
    .find((tokens) => tokens[0] === name);
  return found ? found.slice(1) : [];
}

function lockedVersion(pkg: string): string | null {
  const lock = fs.readFileSync(path.join(ROOT, "pubspec.lock"), "utf8");
  const block = lock.match(new RegExp(`\\n {2}${pkg}:\\n((?: {4}.*\\n)+)`));
  const version = block?.[1].match(/\n? {4}version: "([^"]+)"/);
  return version ? version[1] : null;
}

describe("Content Security Policy du web", () => {
  test("une politique est posée sur toutes les réponses", () => {
    assert.ok(cspHeader, "en-tête Content-Security-Policy(-Report-Only) absent de « ** »");
  });

  test("script-src n'autorise ni 'unsafe-inline' ni 'unsafe-eval'", () => {
    const scriptSrc = directive("script-src");
    assert.ok(scriptSrc.length > 0);
    assert.ok(!scriptSrc.includes("'unsafe-inline'"));
    assert.ok(!scriptSrc.includes("'unsafe-eval'"));
  });

  test("les scripts en ligne de web/index.html sont autorisés par leur empreinte", () => {
    const html = fs.readFileSync(path.join(ROOT, "web", "index.html"), "utf8");
    assert.ok(!html.includes("\r"), "web/index.html doit rester en LF (voir .gitattributes)");
    const inline = [...html.matchAll(/<script(?![^>]*\bsrc=)[^>]*>([\s\S]*?)<\/script>/g)];
    assert.ok(inline.length > 0);
    const scriptSrc = directive("script-src");
    for (const [, body] of inline) {
      const hash = sha256(body);
      assert.ok(
        scriptSrc.includes(hash),
        `script en ligne de web/index.html non autorisé : ajouter ${hash} à script-src`,
      );
    }
  });

  test("FlutterFire : la version verrouillée est celle des empreintes", () => {
    assert.equal(
      lockedVersion("firebase_core_web"),
      FIREBASE_CORE_WEB_VERSION,
      "firebase_core_web a changé de version : relever supportedFirebaseJsSdkVersion dans le " +
        "paquet, mettre à jour FIREBASE_CORE_WEB_VERSION et FIREBASE_JS_SDK_VERSION ici, puis " +
        "reporter les empreintes affichées par le test suivant dans firebase.json",
    );
  });

  test("FlutterFire : chaque plugin web verrouillé a ses empreintes", () => {
    const lock = fs.readFileSync(path.join(ROOT, "pubspec.lock"), "utf8");
    const plugins = [...lock.matchAll(/\n {2}((?:firebase|cloud)_[a-z_]+_web):\n/g)]
      .map((m) => m[1])
      .sort();
    assert.deepEqual(
      plugins,
      FLUTTERFIRE_SERVICES.map((s) => s.plugin).sort(),
      "un plugin FlutterFire web a été ajouté ou retiré : mettre à jour FLUTTERFIRE_SERVICES",
    );
  });

  test("FlutterFire : les scripts injectés sont autorisés par leur empreinte", () => {
    const scriptSrc = directive("script-src");
    const missing: string[] = [];
    for (const service of FLUTTERFIRE_SERVICES) {
      const url = `https://www.gstatic.com/firebasejs/${FIREBASE_JS_SDK_VERSION}/${service.file}`;
      for (const script of flutterfireScripts(service.windowVar, url)) {
        const hash = sha256(script);
        if (!scriptSrc.includes(hash)) missing.push(hash);
      }
    }
    assert.deepEqual(
      missing,
      [],
      `empreintes FlutterFire absentes de script-src : ${missing.join(" ")}`,
    );
  });

  test("aucune empreinte périmée dans script-src", () => {
    const html = fs.readFileSync(path.join(ROOT, "web", "index.html"), "utf8");
    const expected = new Set<string>();
    for (const [, body] of html.matchAll(/<script(?![^>]*\bsrc=)[^>]*>([\s\S]*?)<\/script>/g)) {
      expected.add(sha256(body));
    }
    for (const service of FLUTTERFIRE_SERVICES) {
      const url = `https://www.gstatic.com/firebasejs/${FIREBASE_JS_SDK_VERSION}/${service.file}`;
      for (const script of flutterfireScripts(service.windowVar, url)) expected.add(sha256(script));
    }
    const stale = directive("script-src").filter(
      (t) => t.startsWith("'sha256-") && !expected.has(t),
    );
    assert.deepEqual(stale, [], "empreintes sans script correspondant : les retirer de script-src");
  });

  test("les rapports partent vers /csp-report, réécrit vers cspReportFn", () => {
    assert.deepEqual(directive("report-uri"), ["/csp-report"]);
    const index = hosting.rewrites.findIndex((r) => r.source === "/csp-report");
    const catchAll = hosting.rewrites.findIndex((r) => r.source === "**");
    assert.ok(index >= 0, "réécriture /csp-report absente");
    assert.ok(index < catchAll, "la réécriture /csp-report doit précéder « ** »");
    assert.deepEqual(hosting.rewrites[index].function, {
      functionId: "cspReportFn",
      region: "europe-west1",
    });
  });
});
