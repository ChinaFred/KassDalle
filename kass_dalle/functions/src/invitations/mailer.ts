/**
 * Envoi d'un e-mail par le SMTP de Gmail (`nodemailer`).
 *
 * `nodemailer` se charge par `await import()` au premier envoi, et le
 * transport est mémorisé pour l'instance : seule `manageInvitationFn` envoie
 * des e-mails, et les cinquante autres fonctions du bundle n'ont pas à
 * charger ce module au démarrage (CLAUDE.md, « Aucun SDK lourd au niveau
 * module »).
 *
 * L'expéditeur est le compte Gmail du secret `GMAIL_SENDER`, authentifié par
 * un mot de passe d'application (`GMAIL_APP_PASSWORD`). Le nom affiché et le
 * `Reply-To` désignent l'administrateur qui invite : une réponse lui parvient
 * directement.
 */

import type { Transporter } from "nodemailer";

/** Levée quand l'un des deux secrets est absent ou vide. */
export class MailNotConfiguredError extends Error {
  constructor() {
    super("Envoi d'e-mail non configuré.");
    this.name = "MailNotConfiguredError";
  }
}

export interface MailCredentials {
  sender: string;
  appPassword: string;
}

export interface OutgoingMail {
  fromName: string;
  to: string;
  replyTo: string | null;
  subject: string;
  text: string;
  html: string;
}

let cachedTransport: Transporter | null = null;
let cachedKey: string | null = null;

async function transportFor(credentials: MailCredentials): Promise<Transporter> {
  const key = `${credentials.sender}\u0000${credentials.appPassword}`;
  if (cachedTransport && cachedKey === key) return cachedTransport;
  const nodemailer = await import("nodemailer");
  cachedTransport = nodemailer.createTransport({
    host: "smtp.gmail.com",
    port: 465,
    secure: true,
    auth: { user: credentials.sender, pass: credentials.appPassword },
  });
  cachedKey = key;
  return cachedTransport;
}

/**
 * Les identifiants SMTP, ou `MailNotConfiguredError` si l'un manque.
 * Les valeurs viennent des secrets montés sur la fonction.
 */
export function mailCredentials(sender: string, appPassword: string): MailCredentials {
  const s = sender.trim();
  // Google affiche le mot de passe d'application par groupes de quatre lettres.
  const p = appPassword.replace(/\s+/g, "");
  if (s.length === 0 || p.length === 0) throw new MailNotConfiguredError();
  return { sender: s, appPassword: p };
}

/** Envoie l'e-mail. Lève l'erreur du serveur SMTP telle quelle. */
export async function sendMail(credentials: MailCredentials, mail: OutgoingMail): Promise<void> {
  const transport = await transportFor(credentials);
  await transport.sendMail({
    from: { name: mail.fromName, address: credentials.sender },
    to: mail.to,
    ...(mail.replyTo ? { replyTo: mail.replyTo } : {}),
    subject: mail.subject,
    text: mail.text,
    html: mail.html,
  });
}
