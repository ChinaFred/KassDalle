import { test, describe } from "node:test";
import assert from "node:assert/strict";

import {
  needsReplyToNotify,
  pushKindForTransition,
  pushTicketTitle,
  ticketPushText,
} from "../tickets/pushRules";

describe("pushKindForTransition", () => {
  test("analysé et livré notifient, un statut inchangé non", () => {
    assert.equal(pushKindForTransition("received", "analyzed"), "ticket_analyzed");
    assert.equal(pushKindForTransition("analyzed", "analyzed"), null);
    assert.equal(pushKindForTransition("in_progress", "delivered"), "ticket_delivered");
    assert.equal(pushKindForTransition("analyzed", "validated"), null);
    assert.equal(pushKindForTransition("analyzed", "refused"), null);
  });
  test("retour à Reçu puis nouvelle analyse : nouvelle notification", () => {
    assert.equal(pushKindForTransition("received", "analyzed"), "ticket_analyzed");
  });
});

describe("pushTicketTitle", () => {
  test("tronque à 60 caractères", () => {
    const t = pushTicketTitle("a".repeat(100));
    assert.equal(Array.from(t).length, 60);
    assert.ok(t.endsWith("…"));
  });
  test("une adresse e-mail est remplacée", () => {
    assert.equal(pushTicketTitle("écrire à jean@example.com"), "Ticket");
    assert.equal(pushTicketTitle(undefined), "Ticket");
    assert.equal(pushTicketTitle("voir http://exemple.test/x"), "Ticket");
  });
  test("textes", () => {
    assert.deepEqual(ticketPushText("ticket_needs_reply", "Titre"), {
      title: "Ticket à compléter",
      body: "Titre — une réponse est attendue",
    });
    assert.equal(ticketPushText("ticket_analyzed", "T").title, "Ticket analysé");
    assert.equal(ticketPushText("ticket_delivered", "T").title, "Ticket livré");
  });
});

describe("needsReplyToNotify", () => {
  const now = Date.parse("2026-11-08T12:00:00Z");
  const fresh = "2026-11-08T11:00:00Z";
  const analysis = (id: number, body: string, at: string) => ({
    comment_id: id,
    body,
    created_at: at,
  });
  test("compléments récents non notifiés", () => {
    assert.equal(
      needsReplyToNotify([analysis(5, "## Analyse — compléments\nx", fresh)], null, now),
      5,
    );
  });
  test("déjà notifié, trop ancien ou simple analyse : rien", () => {
    assert.equal(
      needsReplyToNotify([analysis(5, "## Analyse — compléments", fresh)], 5, now),
      null,
    );
    assert.equal(
      needsReplyToNotify(
        [analysis(5, "## Analyse — compléments", "2026-11-07T00:00:00Z")],
        null,
        now,
      ),
      null,
    );
    assert.equal(needsReplyToNotify([analysis(5, "## Analyse\nx", fresh)], null, now), null);
  });
  test("une analyse postérieure ne masque pas des compléments : seul le dernier compte", () => {
    assert.equal(
      needsReplyToNotify(
        [
          analysis(5, "## Analyse — compléments", fresh),
          analysis(6, "## Analyse — compléments", fresh),
        ],
        5,
        now,
      ),
      6,
    );
  });
});
