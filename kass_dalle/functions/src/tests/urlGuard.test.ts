/**
 * Garde SSRF de l'import par lien : forme de l'adresse, adresses IP non
 * publiques, noms d'hôte internes, résolution DNS, normalisation pour le
 * contrôle du doublon, classement des échecs de récupération.
 */

import { test, describe } from "node:test";
import assert from "node:assert/strict";

import {
  UrlRefusedError,
  assertPublicHost,
  expandV6,
  isBlockedHostname,
  isPublicAddress,
  parseImportUrl,
  siteName,
} from "../web/urlGuard";
import {
  WebFetchError,
  classifyNetworkError,
  contentTypeAccepted,
  decodeHtml,
  failureForStatus,
  parseContentType,
} from "../web/safeFetch";
import { boundIngredients, isOwnWebBook, urlImportErrorFrom } from "../pipeline/urlImport";
import { decodedStream } from "../web/safeFetch";
import { PassThrough } from "node:stream";
import { gzipSync } from "node:zlib";
import { remainingImports, urlImportLimit } from "../callable/urlImportCallable";

function refusal(fn: () => unknown): UrlRefusedError {
  try {
    fn();
  } catch (err) {
    assert.ok(err instanceof UrlRefusedError, `erreur inattendue : ${String(err)}`);
    return err;
  }
  assert.fail("aucun refus");
}

describe("adresses IP", () => {
  const blocked = [
    "127.0.0.1",
    "10.1.2.3",
    "172.16.0.1",
    "172.31.255.255",
    "192.168.1.1",
    "169.254.169.254",
    "100.64.0.1",
    "100.127.255.254",
    "0.0.0.0",
    "224.0.0.1",
    "255.255.255.255",
    "::",
    "::1",
    "fc00::1",
    "fd12:3456::1",
    "fe80::1",
    "ff02::1",
    "::ffff:127.0.0.1",
    "::ffff:a9fe:a9fe",
    "64:ff9b::10.0.0.1",
    "2001:db8::1",
    "2001:0:4136:e378:8000:63bf:3fff:fdd2",
    "64:ff9b:1::a00:1",
    "::ffff:0:a00:1",
    "not-an-ip",
  ];
  for (const ip of blocked) {
    test(`${ip} n'est pas publique`, () => assert.equal(isPublicAddress(ip), false));
  }
  const allowed = ["8.8.8.8", "93.184.216.34", "172.32.0.1", "100.128.0.1", "2606:4700::1111"];
  for (const ip of allowed) {
    test(`${ip} est publique`, () => assert.equal(isPublicAddress(ip), true));
  }
  test("développement IPv6", () => {
    assert.deepEqual(expandV6("::1"), [0, 0, 0, 0, 0, 0, 0, 1]);
    assert.deepEqual(expandV6("::ffff:10.0.0.1"), [0, 0, 0, 0, 0, 0xffff, 0x0a00, 1]);
    assert.equal(expandV6("1::2::3"), null);
  });
});

describe("noms d'hôte", () => {
  for (const h of [
    "localhost",
    "foo.localhost",
    "metadata.google.internal",
    "metadata",
    "intranet",
    "printer.local",
  ]) {
    test(`${h} est refusé`, () => assert.equal(isBlockedHostname(h), true));
  }
  test("un domaine public passe", () => assert.equal(isBlockedHostname("www.marmiton.org"), false));
  test("nom du site", () => assert.equal(siteName("WWW.Marmiton.org"), "marmiton.org"));
});

describe("forme de l'adresse", () => {
  test("http et https publics passent", () => {
    const p = parseImportUrl("  https://www.Marmiton.org/recettes/quiche.aspx?utm_source=x#avis ");
    assert.equal(p.normalized, "https://www.marmiton.org/recettes/quiche.aspx");
    assert.equal(p.site, "marmiton.org");
    assert.equal(parseImportUrl("http://example.com/").normalized, "http://example.com/");
  });
  test("paramètres triés, suivi retiré, barre finale retirée", () => {
    assert.equal(
      parseImportUrl("https://a.fr/r/?b=2&fbclid=z&a=1").normalized,
      "https://a.fr/r/?a=1&b=2",
    );
    assert.equal(parseImportUrl("https://a.fr/r/").normalized, "https://a.fr/r");
  });
  test("schéma, identifiants, port, longueur, hôte interne", () => {
    assert.equal(refusal(() => parseImportUrl("ftp://a.fr/x")).reason, "scheme");
    assert.equal(refusal(() => parseImportUrl("javascript:alert(1)")).reason, "scheme");
    assert.equal(refusal(() => parseImportUrl("https://u:p@a.fr/")).reason, "credentials");
    assert.equal(refusal(() => parseImportUrl("https://a.fr:22/")).reason, "port");
    assert.equal(
      refusal(() => parseImportUrl(`https://a.fr/${"x".repeat(2100)}`)).reason,
      "too_long",
    );
    assert.equal(refusal(() => parseImportUrl("pas une adresse")).reason, "malformed");
    assert.equal(refusal(() => parseImportUrl("")).reason, "empty");
    assert.equal(refusal(() => parseImportUrl("http://localhost/")).reason, "hostname");
    assert.equal(
      refusal(() => parseImportUrl("http://metadata.google.internal/computeMetadata/v1/")).reason,
      "hostname",
    );
    assert.equal(
      refusal(() => parseImportUrl("http://169.254.169.254/latest")).reason,
      "private_address",
    );
    assert.equal(refusal(() => parseImportUrl("http://[::1]/")).reason, "private_address");
    assert.equal(refusal(() => parseImportUrl("http://10.0.0.1/")).reason, "private_address");
  });
  test("lien web ou hôte refusé : deux messages", () => {
    assert.equal(refusal(() => parseImportUrl("ftp://a.fr")).notAWebLink, true);
    assert.equal(refusal(() => parseImportUrl("http://localhost")).notAWebLink, false);
  });
});

describe("résolution DNS", () => {
  const url = new URL("https://evil.example.com/");
  test("une seule adresse privée suffit à refuser", async () => {
    await assert.rejects(
      assertPublicHost(url, async () => [
        { address: "93.184.216.34", family: 4 },
        { address: "10.0.0.5", family: 4 },
      ]),
      (err: unknown) => err instanceof UrlRefusedError && err.reason === "private_address",
    );
  });
  test("métadonnées par DNS refusées", async () => {
    await assert.rejects(
      assertPublicHost(url, async () => [{ address: "169.254.169.254", family: 4 }]),
      UrlRefusedError,
    );
  });
  test("résolution en échec", async () => {
    await assert.rejects(
      assertPublicHost(url, async () => {
        throw new Error("ENOTFOUND");
      }),
      (err: unknown) => err instanceof UrlRefusedError && err.reason === "dns",
    );
  });
  test("adresses publiques acceptées", async () => {
    await assertPublicHost(url, async () => [
      { address: "93.184.216.34", family: 4 },
      { address: "2606:2800:220:1::1", family: 6 },
    ]);
  });
});

describe("récupération", () => {
  test("statuts", () => {
    assert.equal(failureForStatus(200), null);
    assert.equal(failureForStatus(403), "blocked");
    assert.equal(failureForStatus(402), "blocked");
    assert.equal(failureForStatus(404), "not_found");
    assert.equal(failureForStatus(503), "network");
  });
  test("types de contenu", () => {
    assert.deepEqual(parseContentType("Text/HTML; charset=ISO-8859-1"), {
      type: "text/html",
      charset: "iso-8859-1",
    });
    assert.equal(contentTypeAccepted("text/html", ["text/html"]), true);
    assert.equal(contentTypeAccepted("image/webp", ["image/"]), true);
    assert.equal(contentTypeAccepted("application/pdf", ["text/html"]), false);
  });
  test("décodage latin-1 annoncé par <meta>", () => {
    const body = Buffer.from('<meta charset="iso-8859-1"><p>crème</p>', "latin1");
    assert.ok(decodeHtml(body, null).includes("crème"));
  });
  test("erreur réseau classée", () => {
    const refused = Object.assign(new Error("x"), { code: "EKASSDALLE_PRIVATE_ADDRESS" });
    assert.equal(classifyNetworkError(refused, false).failure, "refused");
    assert.equal(classifyNetworkError(new Error("reset"), true).failure, "timeout");
    assert.equal(
      classifyNetworkError(Object.assign(new Error("x"), { code: "ECONNRESET" }), false).failure,
      "network",
    );
  });
  test("codes d'échec du job", () => {
    assert.equal(urlImportErrorFrom(new WebFetchError("blocked", "403")).code, "page_blocked");
    assert.equal(urlImportErrorFrom(new WebFetchError("not_found", "404")).code, "page_not_found");
    const t = urlImportErrorFrom(new WebFetchError("timeout", "t"));
    assert.equal(t.code, "timeout");
    assert.equal(t.retryable, true);
    assert.equal(urlImportErrorFrom(new WebFetchError("not_html", "pdf")).code, "url_refused");
    assert.equal(
      urlImportErrorFrom(new UrlRefusedError("private_address", "x")).code,
      "url_refused",
    );
  });
});

describe("plafond quotidien", () => {
  test("dix par jour, multiplié pour le fondateur", () => {
    assert.equal(urlImportLimit(1), 10);
    assert.equal(urlImportLimit(100), 1000);
    assert.equal(urlImportLimit(0), 10);
  });
  test("restants", () => {
    assert.equal(remainingImports(3, 10), 7);
    assert.equal(remainingImports(12, 10), 0);
  });
});

describe("rattachement d'une photo approuvée", () => {
  test("sans drapeau, hors recette ou sans URL : rien n'est écrit", async () => {
    const { attachApprovedIllustration } = await import("../moderation/promote");
    const base = {
      attachOnApproval: true,
      targetKind: "recipe_illustration",
      ownerId: "r1",
      url: "https://x/y.jpg",
      correlationId: "c",
      moderationId: "m",
    };
    assert.equal(await attachApprovedIllustration({ ...base, attachOnApproval: false }), false);
    assert.equal(await attachApprovedIllustration({ ...base, targetKind: "book_cover" }), false);
    assert.equal(await attachApprovedIllustration({ ...base, url: null }), false);
    assert.equal(await attachApprovedIllustration({ ...base, ownerId: "a/b" }), false);
  });
});

describe("flux décompressé", () => {
  test("une réponse détruite fait échouer la lecture aussitôt", async () => {
    const res = Object.assign(new PassThrough(), { complete: false });
    const decoded = decodedStream(res, "gzip");
    const full = gzipSync(Buffer.from("x".repeat(10_000)));
    res.write(full.subarray(0, 20));
    const started = Date.now();
    setTimeout(() => res.destroy(new Error("abandon")), 20);
    await assert.rejects(async () => {
      for await (const chunk of decoded) void chunk;
    });
    assert.ok(Date.now() - started < 2_000);
  });

  test("une réponse complète se lit en entier", async () => {
    const res = Object.assign(new PassThrough(), { complete: true });
    const decoded = decodedStream(res, "gzip");
    res.end(gzipSync(Buffer.from("bonjour")));
    const chunks: Buffer[] = [];
    for await (const chunk of decoded) chunks.push(chunk as Buffer);
    assert.equal(Buffer.concat(chunks).toString(), "bonjour");
  });
});

describe("livre « Mes recettes du web »", () => {
  test("seul le livre du compte, tagué __web, est réutilisé", () => {
    assert.equal(isOwnWebBook({ created_by: "u1", tags: ["__web"] }, "u1"), true);
    assert.equal(isOwnWebBook({ created_by: "intrus", tags: ["__web"] }, "u1"), false);
    assert.equal(isOwnWebBook({ created_by: "u1", tags: [] }, "u1"), false);
    assert.equal(isOwnWebBook(undefined, "u1"), false);
  });
});

describe("bornes des ingrédients écrits", () => {
  test("nom, unité, nombre", () => {
    const line = (nom: string, unite = "g") => ({ nom, unite });
    assert.deepEqual(
      boundIngredients([
        line("farine"),
        line("x".repeat(121)),
        line(""),
        line("sel", "u".repeat(41)),
      ]),
      [line("farine")],
    );
    assert.equal(
      boundIngredients(Array.from({ length: 250 }, (_, i) => line(`i${i}`))).length,
      200,
    );
  });
});
