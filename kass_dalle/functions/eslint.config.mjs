// Configuration ESLint 9 (flat config) pour les Cloud Functions Kass'Dalle.
// Remplace l'ancien .eslintrc.json, qui n'avait ni parser TypeScript ni règles :
// il ne lintait donc rien du tout.

import js from "@eslint/js";
import tseslint from "typescript-eslint";

export default tseslint.config(
  {
    ignores: ["lib/**", "node_modules/**", "eslint.config.mjs"],
  },
  js.configs.recommended,
  ...tseslint.configs.recommended,
  {
    languageOptions: {
      ecmaVersion: 2022,
      sourceType: "module",
      globals: {
        console: "readonly",
        process: "readonly",
        Buffer: "readonly",
        setTimeout: "readonly",
        clearTimeout: "readonly",
        setInterval: "readonly",
        clearInterval: "readonly",
        URL: "readonly",
        fetch: "readonly",
      },
    },
    rules: {
      // ── Règle cardinale du projet : aucun catch silencieux ────────────────
      // Un `catch {}` vide est une erreur, jamais un raccourci acceptable.
      // Voir CLAUDE.md § « Règles de code ».
      "no-empty": ["error", { allowEmptyCatch: false }],

      // Un `catch` dont la variable n'est pas utilisée est le signe d'une
      // erreur avalée : on veut au minimum la passer à logError().
      "@typescript-eslint/no-unused-vars": [
        "error",
        {
          argsIgnorePattern: "^_",
          varsIgnorePattern: "^_",
          caughtErrors: "all",
          caughtErrorsIgnorePattern: "^$",
        },
      ],

      // Les prompts Gemini sont des littéraux de gabarit en français : les
      // espaces insécables typographiques y sont légitimes.
      "no-irregular-whitespace": ["error", { skipTemplates: true }],

      // `console.error` / `console.warn` sont le repli documenté quand Cloud
      // Logging est indisponible ; `console.log` n'a pas sa place en production.
      "no-console": ["error", { allow: ["error", "warn"] }],

      // Tolérances assumées sur une base existante.
      "@typescript-eslint/no-explicit-any": "warn",
    },
  },
);
