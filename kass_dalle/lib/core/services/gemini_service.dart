import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:google_generative_ai/google_generative_ai.dart';
import '../../features/recipes/domain/recipe.dart';

/// Service d'extraction de recettes via Gemini.
///
/// La clé API est fournie à la construction (lue depuis Firestore/Remote Config
/// ou via --dart-define=GEMINI_API_KEY=xxx au build).
///
/// [onTokenUsage] : callback appelé après chaque appel API pour logger l'usage.
/// Signature : (feature, inputTokens, outputTokens, totalTokens)
class GeminiService {
  static const _modelName = 'gemini-2.5-flash';

  late final GenerativeModel _model;
  final Future<void> Function(
    String feature,
    int inputTokens,
    int outputTokens,
    int totalTokens,
  )?
  onTokenUsage;

  GeminiService(String apiKey, {this.onTokenUsage})
    : _model = GenerativeModel(model: _modelName, apiKey: apiKey);

  /// Log l'usage des tokens après un appel Gemini.
  Future<void> _logUsage(
    String feature,
    GenerateContentResponse response,
  ) async {
    final meta = response.usageMetadata;
    if (meta == null || onTokenUsage == null) return;
    final input = meta.promptTokenCount ?? 0;
    final output = meta.candidatesTokenCount ?? 0;
    final total = meta.totalTokenCount ?? (input + output);
    await onTokenUsage!(feature, input, output, total);
  }

  static const _prompt = r'''
Tu es un expert en cuisine et en format CookLang.
Extrais TOUTES les recettes présentes dans ce document et convertis-les en format CookLang strict.

Règle FONDAMENTALE — COPIE FIDÈLE :
- Conserve le texte des étapes AUSSI PROCHE QUE POSSIBLE de l'original.
- Ne reformule PAS, ne résume PAS, ne réinterprète PAS, n'invente AUCUN ingrédient ni quantité.
- Respecte EXACTEMENT les quantités, les ingrédients et le découpage des étapes du document.
- Si l'original dit "coupez le chou en dés", écris "coupez le @chou{} en dés" — ne remplace pas par une autre formulation.
- Si une information n'est pas dans le document, ne l'invente pas.

Règles CookLang :
- Métadonnées (lignes commençant par >>) :
    >> titre: Nom de la recette
    >> page: 42
    >> portions: 4
    >> difficulté: facile|moyen|difficile
    >> temps_préparation: 20 min
    >> temps_cuisson: 35 min
    >> dish_types: liste séparée par virgules parmi : viande, volaille, poisson, fruits de mer, végétarien, vegan, dessert, pâtisserie, soupe, entrée, plat complet, snack
  Règle importante : si un numéro de page est visible dans le document (coin de page, en-tête, pied de page), indique-le dans « >> page: N ».
- Les ingrédients sont intégrés dans le texte des étapes : @nom{quantité%unité}
  Règles importantes :
  1. Utilise des ESPACES dans les noms multi-mots (jamais des underscores).
  2. Les accolades {} sont obligatoires, et TOUJOURS remplies avec quantité%unité quand connus.
  3. Si l'ingrédient est mesuré en « brin », « filet », « noisette », « pince », « pincee », « bouquet », etc., utilise ce mot comme unité même si c'est aussi le début du nom.
  4. Ne laisse JAMAIS les accolades vides si la quantité ou l'unité est connue.
  5. COHÉRENCE ABSOLUE : utilise EXACTEMENT la même orthographe pour un même ingrédient dans toutes les étapes de la recette (même forme singulier/pluriel, même ordre des mots, même casse). Ne jamais écrire @côte de veau dans une étape et @côtes de veau dans une autre.
  Exemples corrects : @oeufs{3}, @farine{200%g}, @sel{1%pincée}, @brin de romarin{1%brin}, @brin de sauge{2%brins}, @filet d'huile d'olive{1%filet}, @noisette de beurre{1%noisette}, @huile d'olive{2%cuillères à soupe}, @côtes de veau{2%pièces}
  Mauvais exemples (à éviter) : @brin_de_romarin{1}, @brin de romarin{}, @brin_de_romarin{}, écrire @côte de veau dans une étape et @côtes de veau dans une autre
- Les équipements : #nom{quantité}  Exemples : #four{}, #poêle{}, #moule à tarte{}, #moule à muffin{12}, #plaque de cuisson{}, #saladier{}, #casserole{}, #mixeur{}
  RÈGLE CRITIQUE — ustensiles vs ingrédients :
  • Un ustensile, contenant ou accessoire de cuisine est TOUJOURS un équipement (#), JAMAIS un ingrédient (@),
    même si la recette précise une quantité ou des dimensions (ex : "12 moules à muffin" → #moule à muffin{12}).
  • Les mots suivants désignent TOUJOURS des équipements (#) : moule à, plaque, casserole, poêle, saladier,
    bol, mixeur, fouet, spatule, rouleau, tamis, passoire, cocotte, wok, sauteuse, ramequin, terrine.
  • EXCEPTION : « moule » seul (sans complément) peut être le mollusque (@moule{}) ou l'ustensile selon le contexte ;
    si le texte parle de cuisine de pâtisserie/cuisson au four → équipement (#moule{}) ;
    si le texte parle de fruits de mer/plat de la mer → ingrédient (@moule{}).
  • Les températures ("180°C", "thermostat 6") sont du texte plain dans les étapes, jamais des ingrédients (@).
    Écris : "Préchauffez le #four{} à 180°C" et NON "à @180°C{}"
  INTERDIT avec @ :
  • Le plat ou produit FINAL que la recette crée ou confectionne (ex : si la recette fabrique des chaussons, des boulettes, des croquettes, des raviolis… le nom du produit fini N'EST PAS un ingrédient : n'écris JAMAIS @chaussons{}, @boulette{}, etc.).
  • Les instructions de division ou de découpe ("20 parts égales", "en portions"…) : écris-les en texte plain, jamais avec @.
  • Le résultat d'une découpe d'un ingrédient déjà listé : si la recette dit "découpez les blancs de poulet en lanières", l'ingrédient est @blanc de poulet{} ; écris "découpez en lanières" en texte plain — n'écris PAS @lanière de poulet{} séparément.
  • Les sous-préparations fabriquées dans la recette : si une étape prépare une vinaigrette, une sauce, une marinade, une pâte… cette préparation N'EST PAS un ingrédient externe. Dans les étapes suivantes, réfère-t'y en texte plain ("ajoutez la vinaigrette") et NON comme @vinaigrette{}, @sauce{}, @marinade{}.
- Les timers : ~{durée%unité}  Exemples : ~{20%minutes}, ~{1%heure}
- Sections de préparation (quand la recette a plusieurs parties distinctes) : == Nom de section ==
  Exemples : == La sauce ==, == Le montage ==, == La pâte ==
  Mets == Nom == sur sa propre ligne AVANT les étapes de cette partie.
  N'utilise PAS de section si la recette est simple et linéaire.
  GROUPES D'INGRÉDIENTS : si le livre présente les ingrédients divisés en groupes nommés
  (ex : "Pour la marinade :", "Pour le poulet :", "Pour la sauce :", "Pour la pâte :"),
  tu DOIS créer une section == Nom == pour chaque groupe et placer sous cette section
  les étapes qui utilisent ces ingrédients. Respecte l'ordre des groupes du livre.
- Notes et conseils (accompagnement, variante, astuce, conservation…) : > Texte de la note
  Exemples : > Idée d'accompagnement : servir avec une salade verte., > Conseil : peut se préparer la veille.
  Mets > Note sur sa propre ligne, après l'étape concernée ou en fin de recette.
  N'utilise PAS de note si l'information est déjà dans les étapes.
- Chaque étape est une ligne de texte plain
- Séparateur entre plusieurs recettes : ---

Exemple de sortie attendue :
>> titre: Tarte aux pommes
>> page: 42
>> portions: 6
>> difficulté: facile
>> dish_types: dessert, pâtisserie

Préchauffez le #four{} à 180°C.
Épluchez et découpez @pommes{6} en fines tranches.
Étalez la @pâte brisée{1} dans un #moule à tarte{}.
Disposez les pommes et saupoudrez de @sucre roux{2%cuillères à soupe}.
Enfournez pendant ~{35%minutes} jusqu'à coloration dorée.

---

Retourne UNIQUEMENT le contenu demandé, sans explication, sans markdown, sans ``` .
Si plusieurs recettes, sépare-les avec ---.

IMPORTANT — Gestion des pages non-recettes :
Si la page ne contient PAS de recette(s) mais présente un contenu culinaire utile (astuce ou technique culinaire, explication d'ingrédient, description de matériel, cours de cuisine, conseils, glossaire culinaire, etc.), retourne ce contenu sous cette forme exacte :
>> page_type: technique        (pour astuces/techniques culinaires)
             ou equipment       (pour descriptions de matériel/ustensiles)
             ou ingredient_note (pour explications sur les ingrédients)
             ou other           (pour tout autre contenu non-recette utile)
>> titre: Titre ou sujet de la page (5 mots max)
>> page: N   (si un numéro de page est visible)
[Texte COPIÉ MOT POUR MOT depuis le document, sans reformulation, sans résumé, sans ajout.
Respecte exactement les sauts de ligne, les listes, les tirets, les numérotations et la mise en page originale.
Si une image, un schéma ou un diagramme est présent, indique-le brièvement entre crochets : [schéma : description courte].]

Si la page est vide, une page de garde, un index, une table des matières, une publicité ou sans contenu utile : retourne exactement : NO_RECIPE
''';

  static const _freeTextPrompt = r'''
Tu es un expert en cuisine et en format CookLang.
L'utilisateur t'a fourni le texte brut d'une recette. Convertis-la en format CookLang strict.

Règle FONDAMENTALE — COPIE FIDÈLE :
- Conserve le texte des étapes AUSSI PROCHE QUE POSSIBLE de l'original.
- Ne reformule PAS, ne résume PAS, ne réinterprète PAS, n'invente AUCUN ingrédient ni quantité.
- Respecte EXACTEMENT les quantités, les ingrédients et le découpage des étapes.
- Ton seul travail est d'identifier les ingrédients (@), les équipements (#) et les timers (~) dans le texte existant.
- Si une information n'est pas dans le texte, ne l'invente pas.

Règles CookLang :
- Métadonnées (lignes commençant par >>) :
    >> titre: Nom de la recette
    >> portions: 4
    >> difficulté: facile|moyen|difficile
    >> temps_préparation: 20 min
    >> temps_cuisson: 35 min
- Les ingrédients sont intégrés dans le texte des étapes : @nom{quantité%unité}
  Règles importantes :
  1. Utilise des ESPACES dans les noms multi-mots (jamais des underscores).
  2. Les accolades {} sont obligatoires, et TOUJOURS remplies avec quantité%unité quand connus.
  3. Si l'ingrédient est mesuré en « brin », « filet », « noisette », « pincée », « bouquet », etc., utilise ce mot comme unité même si c'est aussi le début du nom.
  4. Ne laisse JAMAIS les accolades vides si la quantité ou l'unité est connue.
  5. COHÉRENCE ABSOLUE : utilise EXACTEMENT la même orthographe pour un même ingrédient dans toutes les étapes (même forme singulier/pluriel, même ordre des mots). Ne jamais écrire @côte de veau dans une étape et @côtes de veau dans une autre.
  Exemples corrects : @oeufs{3}, @farine{200%g}, @sel{1%pincée}, @brin de romarin{1%brin}, @brin de sauge{2%brins}, @filet d'huile d'olive{1%filet}, @noisette de beurre{1%noisette}, @huile d'olive{2%cuillères à soupe}
  Mauvais exemples (à éviter) : @brin_de_romarin{1}, @brin de romarin{}, @brin_de_romarin{}, écrire @côte de veau dans une étape et @côtes de veau dans une autre
- Les équipements : #nom{quantité}  Exemples : #four{}, #poêle{}, #moule à muffin{12}, #plaque de cuisson{}, #saladier{}
  RÈGLE CRITIQUE — ustensiles vs ingrédients :
  • Un ustensile, contenant ou accessoire de cuisine est TOUJOURS un équipement (#), JAMAIS un ingrédient (@),
    même si la recette précise une quantité ou des dimensions (ex : "12 moules à muffin" → #moule à muffin{12}).
  • Les mots suivants désignent TOUJOURS des équipements (#) : moule à, plaque, casserole, poêle, saladier,
    bol, mixeur, fouet, spatule, rouleau, tamis, passoire, cocotte, wok, sauteuse, ramequin, terrine.
  • EXCEPTION : « moule » seul peut être le mollusque (@moule{}) ou l'ustensile selon le contexte.
  • Les températures ("180°C") sont du texte plain, jamais des ingrédients (@).
    Écris : "Préchauffez le #four{} à 180°C" et NON "à @180°C{}"
  INTERDIT avec @ :
  • Le plat ou produit FINAL que la recette crée ou confectionne (ex : si la recette fabrique des chaussons, des boulettes, des croquettes, des raviolis… le nom du produit fini N'EST PAS un ingrédient : n'écris JAMAIS @chaussons{}, @boulette{}, etc.).
  • Les instructions de division ou de découpe ("20 parts égales", "en portions"…) : écris-les en texte plain, jamais avec @.
  • Le résultat d'une découpe d'un ingrédient déjà listé : si la recette dit "découpez les blancs de poulet en lanières", l'ingrédient est @blanc de poulet{} ; écris "découpez en lanières" en texte plain — n'écris PAS @lanière de poulet{} séparément.
  • Les sous-préparations fabriquées dans la recette : si une étape prépare une vinaigrette, une sauce, une marinade, une pâte… cette préparation N'EST PAS un ingrédient externe. Dans les étapes suivantes, réfère-t'y en texte plain ("ajoutez la vinaigrette") et NON comme @vinaigrette{}, @sauce{}, @marinade{}.
- Les timers : ~{durée%unité}  Exemples : ~{20%minutes}, ~{1%heure}
- Sections de préparation (quand la recette a plusieurs parties distinctes) : == Nom de section ==
  Exemples : == La sauce ==, == Le montage ==, == La pâte ==
  Mets == Nom == sur sa propre ligne AVANT les étapes de cette partie.
  N'utilise PAS de section si la recette est simple et linéaire.
  GROUPES D'INGRÉDIENTS : si le texte présente les ingrédients divisés en groupes nommés
  (ex : "Pour la marinade :", "Pour le poulet :", "Pour la sauce :", "Pour la pâte :"),
  tu DOIS créer une section == Nom == pour chaque groupe et placer sous cette section
  les étapes qui utilisent ces ingrédients. Respecte l'ordre des groupes.
- Notes et conseils (accompagnement, variante, astuce, conservation…) : > Texte de la note
  Exemples : > Idée d'accompagnement : servir avec une salade verte., > Conseil : peut se préparer la veille.
  Mets > Note sur sa propre ligne, après l'étape concernée ou en fin de recette.
  N'utilise PAS de note si l'information est déjà dans les étapes.
- Chaque étape est une ligne de texte plain

Retourne UNIQUEMENT le contenu CookLang, sans explication, sans markdown, sans ```.
Si aucune recette n'est trouvée, retourne exactement : NO_RECIPE
''';

  static const _bookCoverPrompt = r'''
Tu analyses une page de garde de livre de cuisine.
Retourne strictement un JSON valide, sans markdown, sans texte additionnel.

Schema attendu:
{
  "titre": "string",
  "sous_titre": "string|null",
  "auteur": "string",
  "editeur": "string|null",
  "serie": "string|null",
  "annee": 2024,
  "langue": "fr|en|nl",
  "isbn": "string|null",
  "description": "string|null",
  "tags": ["tag1", "tag2"]
}

Contraintes:
- "titre" et "auteur" doivent etre non vides.
- Si valeur inconnue, utilise null.
- "annee" doit etre un entier ou null.
- "langue" doit etre l'une des valeurs fr/en/nl (par defaut fr).
- "tags" doit etre une liste (vide possible).
''';

  static const _multiPagePrefix = r'''
IMPORTANT : Les images fournies sont des PAGES CONSÉCUTIVES d'un même document.
Traite-les comme un document continu, dans l'ordre où elles apparaissent.
Une recette peut commencer sur une page et se terminer sur la suivante : dans ce cas, reconstitue-la en une seule recette complète.
Ne retourne PAS NO_RECIPE simplement parce qu'une page seule semble incomplète.

''';

  /// Envoie un fichier (PDF, DOCX, image) à Gemini et retourne le CookLang extrait.
  /// Retourne une liste de strings CookLang (une par recette détectée).
  /// [additionalPages] : pages supplémentaires (multi-page scan).
  Future<List<String>> extractRecipes(
    Uint8List bytes,
    String mimeType, {
    List<({Uint8List bytes, String mimeType})> additionalPages = const [],
  }) async {
    final prompt = additionalPages.isNotEmpty
        ? _multiPagePrefix + _prompt
        : _prompt;
    final parts = <Part>[
      DataPart(mimeType, bytes),
      ...additionalPages.map((p) => DataPart(p.mimeType, p.bytes)),
      TextPart(prompt),
    ];
    final content = Content.multi(parts);

    final response = await _model
        .generateContent([content])
        .timeout(
          // 5 min pour les scans multi-pages (plusieurs images volumineuses)
          const Duration(minutes: 5),
          onTimeout: () => throw TimeoutException('Gemini API timeout'),
        );
    await _logUsage('scan_extraction', response);
    final text = response.text?.trim() ?? '';

    if (text.isEmpty || text == 'NO_RECIPE') return [];

    // Sépare les recettes multiples
    return text
        .split(RegExp(r'\n---+\n'))
        .map((s) => s.trim())
        .where((s) => s.isNotEmpty)
        .toList();
  }

  /// Détecte les zones de photos culinaires dans une image de recette.
  /// Retourne une liste de bounding boxes [yMin, xMin, yMax, xMax] (valeurs 0-1000).
  /// Retourne [] si aucune photo trouvée ou si le fichier n'est pas une image.
  Future<List<List<int>>> detectIllustrationRegions(
    Uint8List bytes,
    String mimeType,
  ) async {
    const prompt = '''
Analyse cette image de livre de cuisine. Elle peut contenir :
- une seule page avec du texte ET une photo culinaire
- une double page (deux pages côte à côte, gauche/droite)
- une double page dont les pages sont en haut et en bas de l'image

Identifie toutes les PHOTOGRAPHIES culinaires présentes : photos du plat final, d'étapes de préparation, de nourriture, d'ingrédients mis en scène.

Une photographie culinaire peut occuper :
- une petite zone dans une page (photo encadrée dans un coin)
- la moitié inférieure de l'image (page du bas d'une double page verticale)
- la moitié supérieure de l'image (page du haut d'une double page verticale)
- la moitié gauche ou droite (double page horizontale classique)
- toute la surface (page entièrement illustrée)

N'inclus PAS : zones de texte, tableaux d'ingrédients, fonds de page blancs, borders, illustrations vectorielles, schémas.

Pour chaque photographie trouvée, retourne ses coordonnées [y_min, x_min, y_max, x_max] en entiers 0-1000
(0 = coin supérieur gauche, 1000 = coin inférieur droit de l'image entière).
Exemple : une photo occupant la moitié basse → [500, 0, 1000, 1000]
Exemple : une photo en bas à droite →  [500, 500, 1000, 1000]

Retourne UNIQUEMENT un tableau JSON valide, sans explication ni markdown :
- Si photos trouvées : [[y1,x1,y2,x2], [y1,x1,y2,x2]]
- Si aucune photo : []
''';
    try {
      final content = Content.multi([
        DataPart(mimeType, bytes),
        TextPart(prompt),
      ]);
      final response = await _model
          .generateContent([content])
          .timeout(
            const Duration(seconds: 60),
            onTimeout: () =>
                throw TimeoutException('detectIllustrationRegions timeout'),
          );
      await _logUsage('detect_illustrations', response);
      final text = (response.text ?? '')
          .trim()
          .replaceAll(RegExp(r'```json?|```'), '')
          .trim();
      if (text.isEmpty || text == '[]') return [];
      // Extrait le premier tableau JSON valide (au cas où Gemini ajoute du texte)
      final jsonMatch = RegExp(r'\[.*\]', dotAll: true).firstMatch(text);
      final jsonText = jsonMatch?.group(0) ?? text;
      final parsed = jsonDecode(jsonText) as List;
      return parsed
          .whereType<List>()
          .map((e) {
            final vals = e.map((v) => (v as num).toDouble()).toList();
            // Détecte si les coordonnées sont en 0–1 (flottants) plutôt que 0–1000
            final maxVal = vals.fold(0.0, (m, v) => v > m ? v : m);
            final scale = maxVal <= 1.5 ? 1000.0 : 1.0;
            return vals.map((v) => (v * scale).round()).toList();
          })
          .where((box) => box.length == 4)
          .toList();
    } catch (_) {
      return [];
    }
  }

  /// Détection simplifiée : demande à Gemini où se trouve LA photo culinaire principale.
  /// Utilisé en repli si [detectIllustrationRegions] retourne [].
  /// Retourne null si aucune photo n'est trouvée.
  Future<List<int>?> detectMainCulinaryPhoto(
    Uint8List bytes,
    String mimeType,
  ) async {
    const prompt = '''
Regarde cette image. Y a-t-il une photographie d'un plat cuisiné, d'un repas ou d'une nourriture préparée ?

Si OUI : donne les coordonnées de la zone photo [y_min, x_min, y_max, x_max] en entiers 0-1000.
Si NON : réponds [].

Réponds UNIQUEMENT avec le tableau JSON, rien d'autre.
Exemple pour une photo en bas de l'image : [480, 0, 1000, 1000]
''';
    try {
      final content = Content.multi([
        DataPart(mimeType, bytes),
        TextPart(prompt),
      ]);
      final response = await _model
          .generateContent([content])
          .timeout(
            const Duration(seconds: 45),
            onTimeout: () => throw TimeoutException('detectMainCulinaryPhoto timeout'),
          );
      await _logUsage('detect_main_photo', response);
      final text = (response.text ?? '')
          .trim()
          .replaceAll(RegExp(r'```json?|```'), '')
          .trim();
      if (text.isEmpty || text == '[]') return null;
      final jsonMatch = RegExp(r'\[.*?\]', dotAll: true).firstMatch(text);
      if (jsonMatch == null) return null;
      final parsed = jsonDecode(jsonMatch.group(0)!) as List;
      if (parsed.isEmpty) return null;
      // Accepte [[y,x,y,x]] ou [y,x,y,x]
      final raw = parsed.first is List ? parsed.first as List : parsed;
      if (raw.length != 4) return null;
      final vals = raw.map((v) => (v as num).toDouble()).toList();
      final maxVal = vals.fold(0.0, (m, v) => v > m ? v : m);
      final scale = maxVal <= 1.5 ? 1000.0 : 1.0;
      return vals.map((v) => (v * scale).round()).toList();
    } catch (_) {
      return null;
    }
  }

  /// Convertit un texte libre (recette saisie à la main) en CookLang via Gemini.
  /// Retourne null si aucune recette n'est détectée dans le texte.
  Future<String?> extractRecipeFromText(String text) async {
    final content = Content.text('$_freeTextPrompt\n\n---\n$text');
    final response = await _model
        .generateContent([content])
        .timeout(
          const Duration(minutes: 2),
          onTimeout: () => throw TimeoutException('Gemini API timeout'),
        );
    await _logUsage('text_extraction', response);
    final result = response.text?.trim() ?? '';
    if (result.isEmpty || result == 'NO_RECIPE') return null;
    return result;
  }

  /// Corrige l'orthographe, la grammaire et les incohérences sémantiques
  /// d'une recette déjà formatée en CookLang, sans en changer la substance.
  Future<String?> polishCooklang(String cooklang) async {
    const prompt = r'''
Tu es un expert culinaire et en format CookLang. On te donne une recette déjà formatée en CookLang.

Ton rôle est de corriger et améliorer ce contenu sans en changer la substance :

1. ORTHOGRAPHE ET GRAMMAIRE :
   - Corrige les fautes d'orthographe, de grammaire et de ponctuation dans les textes des étapes, les noms d'ingrédients et les métadonnées.
   - Corrige les accents manquants ou incorrects.
   - Corrige la capitalisation (titre en titre case, étapes en minuscules).

2. COHÉRENCE SÉMANTIQUE ET CULINAIRE :
   - Si l'ordre des étapes est manifestement illogique (ex : "enfournez" avant "préchauffez le four"), réordonne-les.
   - Corrige les unités manifestement incohérentes (ex : "200 litres de farine" → "200 g de farine").
   - Si un ingrédient est utilisé dans les étapes mais n'apparaît nulle part dans les @balisages, ajoute-le.

3. FORMAT CookLang :
   - Assure-toi que tous les ingrédients sont balisés @nom{qté%unité}.
   - Assure-toi que les équipements sont balisés #nom{}.
   - Les timers doivent être ~{durée%unité}.
   - Un même ingrédient doit toujours avoir exactement la même orthographe dans tout le document.

4. MÉTADONNÉES (lignes >>) :
   - Corrige l'orthographe du titre et la capitalisation.
   - Ne change pas les valeurs numériques (portions, temps) sauf erreur manifeste.

Ce que tu NE dois PAS faire :
- Ajouter des ingrédients, des étapes ou des notes qui n'existent pas dans l'original.
- Changer les quantités sans raison évidente.
- Reformuler ou paraphraser les étapes (sauf correction orthographique mineure).
- Changer la structure générale (sections, ordre des sections).

Retourne UNIQUEMENT le contenu CookLang corrigé, sans explication, sans markdown, sans ```.
''';
    final content = Content.text('$prompt\n\n---\n$cooklang');
    final response = await _model
        .generateContent([content])
        .timeout(
          const Duration(minutes: 2),
          onTimeout: () => throw TimeoutException('Gemini API timeout'),
        );
    await _logUsage('polish_cooklang', response);
    final result = response.text?.trim() ?? '';
    if (result.isEmpty) return null;
    return result;
  }

  /// Recherche en langage naturel dans une liste de recettes.
  ///
  /// [query] : requête de l'utilisateur en langage naturel.
  /// [recipes] : résumés compacts des recettes à analyser (avec champ `note` si noté).
  /// [ratedRecipes] : sous-ensemble des recettes notées, pour que Gemini infère les goûts.
  ///
  /// Retourne un JSON avec :
  /// - `results` : recettes correspondantes avec raison
  /// - `suggestion` : reformulation si aucun résultat
  /// - `preference_insight` : observation sur les goûts de l'utilisateur (nullable)
  Future<Map<String, dynamic>> searchRecipes({
    required String query,
    required List<Map<String, String>> recipes,
    List<Map<String, String>> ratedRecipes = const [],
  }) async {
    if (recipes.isEmpty) {
      return {'results': [], 'suggestion': null, 'preference_insight': null};
    }

    final recipesJson = json.encode(recipes);
    final preferencesSection = ratedRecipes.isEmpty
        ? ''
        : '''
Préférences connues de l'utilisateur — recettes qu'il a notées (note sur 10) :
${json.encode(ratedRecipes)}
(Interprétation : ≥8 = aime beaucoup, 5–7 = apprécie, ≤4 = n'aime pas ou n'apprécie pas)

En analysant ces notes, déduis ses goûts : quels ingrédients, cuisines ou techniques aime-t-il ou évite-t-il ?
Si un pattern clair existe (ex : tout ce qui est frit est noté bas, les desserts au chocolat sont bien notés…), mentionne-le dans "preference_insight".
Tiens compte de ces préférences pour classer et sélectionner les résultats : priorise les recettes qui correspondent à ses goûts, signale si une recette correspond à quelque chose qu'il n'aime généralement pas.
''';

    final prompt =
        '''
Tu es un assistant culinaire expert qui connaît les goûts de l'utilisateur.

Requête de l'utilisateur : "$query"
$preferencesSection
Collection de recettes disponibles (format JSON, champ "note" = note personnelle /10 ou "non notée") :
$recipesJson

Analyse chaque recette et détermine si elle correspond à la requête.
Prends en compte le titre, les ingrédients, les tags, la difficulté, le livre source et les préférences de l'utilisateur.
Sois généreux dans ta sélection : si une recette contient les ingrédients principaux ou correspond au thème, inclus-la.
Si une recette correspond à la requête mais semble contraire aux goûts de l'utilisateur, inclus-la quand même mais mentionne-le dans la "raison".

Retourne UNIQUEMENT un JSON valide, sans markdown, sans texte additionnel, avec exactement ce format :
{
  "results": [
    {"id": "id_de_la_recette", "raison": "Explication courte (1-2 phrases) de pourquoi cette recette correspond"},
    ...
  ],
  "suggestion": null,
  "preference_insight": null
}

Si AUCUNE recette ne correspond, retourne :
{
  "results": [],
  "suggestion": "Une suggestion de reformulation pour trouver des recettes similaires (1 phrase)",
  "preference_insight": null
}

Si tu as détecté un pattern de goût clair dans les notes, remplis "preference_insight" avec une observation concise (1-2 phrases, ex: "Vous semblez apprécier les plats mijotés et les desserts. Les fritures ont tendance à être moins appréciées.").
Sinon laisse "preference_insight" à null.
''';

    final content = Content.text(prompt);
    final response = await _model
        .generateContent([content])
        .timeout(
          const Duration(minutes: 1),
          onTimeout: () => throw TimeoutException('Gemini search timeout'),
        );
    await _logUsage('search', response);
    final text = response.text?.trim() ?? '';
    if (text.isEmpty) {
      return {'results': [], 'suggestion': null, 'preference_insight': null};
    }

    final jsonText = _extractJsonObject(text);
    return json.decode(jsonText) as Map<String, dynamic>;
  }

  Future<BookCoverExtraction> extractBookCover(
    Uint8List bytes,
    String mimeType,
  ) async {
    final content = Content.multi([
      DataPart(mimeType, bytes),
      TextPart(_bookCoverPrompt),
    ]);

    final response = await _model
        .generateContent([content])
        .timeout(
          const Duration(minutes: 2),
          onTimeout: () => throw TimeoutException('Gemini API timeout'),
        );
    await _logUsage('book_cover', response);
    final text = response.text?.trim() ?? '';
    if (text.isEmpty) {
      throw const FormatException('Reponse vide pour la couverture du livre');
    }

    final jsonText = _extractJsonObject(text);
    final data = json.decode(jsonText) as Map<String, dynamic>;
    return BookCoverExtraction.fromMap(data);
  }

  /// Génère une nouvelle recette originale correspondant à la demande.
  ///
  /// [query] : ce que l'utilisateur recherche.
  /// [preferenceInsight] : profil de goûts déduit des notes précédentes.
  ///
  /// Retourne un Map avec les champs nécessaires pour construire un [Recipe].
  Future<Map<String, dynamic>> generateRecipe({
    required String query,
    String? preferenceInsight,
  }) async {
    final prefSection =
        (preferenceInsight != null && preferenceInsight.isNotEmpty)
        ? '\nTiens compte des préférences connues de l\'utilisateur : $preferenceInsight\n'
        : '';

    final prompt =
        '''
Tu es un chef cuisinier expert francophone. L'utilisateur cherche une recette : "$query"$prefSection
Génère une recette originale complète qui répond exactement à cette demande.
Si des préférences utilisateur sont indiquées, adapte la recette pour lui correspondre.

Retourne la réponse en DEUX sections exactement dans ce format (rien d'autre) :

===METADATA===
{
  "titre": "Nom de la recette",
  "langue": "fr",
  "ingredients_index": ["ingredient1", "ingredient2"],
  "ingredients": [
    {"name": "ingredient", "qty": "200", "unit": "g"}
  ],
  "tags": {
    "themes": ["plat principal"],
    "cuisines": ["française"],
    "occasions": [],    "dish_types": ["viande"],    "difficulty": "facile",
    "prep_time": 20,
    "cook_time": 40
  },
  "portions": 4
}
===COOKLANG===
Contenu complet de la recette au format CookLang (ici pas de JSON, écris directement)
===END===

Règles CookLang (OBLIGATOIRES) :
- Ingrédients : @nom{quantité%unité} — ex : @farine{200%g}, @oeufs{2}, @sel{}
- Matériel : #nom{} — ex : #four{}, #poêle{}
- Temps : ~{hh:mm:ss} — ex : ~{0:30:00} pour 30 minutes, ~{1:30:00} pour 1h30
- Sections de préparation (quand la recette a plusieurs parties distinctes) : == Nom de section ==
  Exemples : == La sauce ==, == Le montage ==, == La pâte ==
  Mets == Nom == sur sa propre ligne AVANT les étapes de cette partie.
  N'utilise PAS de section si la recette est simple et linéaire.
- Notes et conseils (accompagnement, variante, astuce, conservation…) : > Texte de la note
  Exemples : > Idée d'accompagnement : servir avec une salade verte., > Conseil : peut se préparer la veille.
  Mets > Note sur sa propre ligne, après l'étape concernée ou en fin de recette.
  N'utilise PAS de note si l'information est déjà dans les étapes.
- Chaque étape sur une nouvelle ligne distincte.
- Le texte doit être en français.
- INTERDIT : N'utilise JAMAIS ~{0:00:00} — un timer nul n'a aucun sens.
- INTERDIT : Ne mets PAS de timer pour les températures (ex: "préchauffer le four à 200°C" → écris simplement 200°C dans le texte, sans ~{}).
- INTERDIT : Les mesures d'épaisseur ou de taille dans le texte (ex: 0.5 cm, 1 cm) ne sont PAS des ingrédients — écris-les directement dans le texte, jamais avec @.
- INTERDIT : Ne jamais baliser avec @ le plat ou produit FINAL que la recette crée (ex : chaussons, boulettes, croquettes, raviolis… le nom du produit fini n'est pas un ingrédient). Les instructions de division ("20 parts égales") ne sont jamais des ingrédients — écris-les en texte plain.
- Les timers servent UNIQUEMENT pour des durées réelles de cuisson ou d'attente (valeur strictement > 0).
''';

    final content = Content.text(prompt);
    final response = await _model
        .generateContent([content])
        .timeout(
          const Duration(minutes: 2),
          onTimeout: () => throw TimeoutException('Gemini generate timeout'),
        );
    await _logUsage('generate', response);
    final text = response.text?.trim() ?? '';
    if (text.isEmpty) throw const FormatException('Réponse Gemini vide');

    // Parse les deux sections délimitées (évite les problèmes JSON avec le CookLang)
    const metaMarker = '===METADATA===';
    const cooklangMarker = '===COOKLANG===';
    const endMarker = '===END===';
    final metaStart = text.indexOf(metaMarker);
    final cooklangStart = text.indexOf(cooklangMarker);
    if (metaStart == -1 || cooklangStart == -1) {
      throw const FormatException(
        'Format de réponse Gemini invalide (marqueurs manquants)',
      );
    }
    final metaJson = text
        .substring(metaStart + metaMarker.length, cooklangStart)
        .trim();
    final endIdx = text.indexOf(endMarker);
    final cooklang =
        (endIdx == -1
                ? text.substring(cooklangStart + cooklangMarker.length)
                : text.substring(cooklangStart + cooklangMarker.length, endIdx))
            .trim();

    final data =
        json.decode(_extractJsonObject(metaJson)) as Map<String, dynamic>;
    data['cooklang'] = cooklang;
    return data;
  }

  /// Raffine une recette existante en appliquant une instruction de l'utilisateur.
  ///
  /// Transmet la recette complète (CookLang + métadonnées) à Gemini avec
  /// l'instruction de modification. Seule la partie concernée par la consigne
  /// est modifiée, le reste est conservé.
  Future<Map<String, dynamic>> refineRecipe({
    required String currentTitre,
    required String currentCooklang,
    required List<Map<String, dynamic>> currentIngredients,
    required Map<String, dynamic> currentTags,
    required int? currentPortions,
    required String instruction,
  }) async {
    final ingredientsList = currentIngredients
        .map(
          (i) =>
              '- ${[i['qty'], i['unit'], i['name']].where((s) => (s as String?)?.isNotEmpty == true).join(' ')}'
                  .trim(),
        )
        .join('\n');

    final portions = currentPortions != null
        ? '\nPortions : $currentPortions'
        : '';

    final prompt =
        '''
Tu es un chef cuisinier expert francophone. Voici une recette existante :

TITRE: $currentTitre$portions
INGRÉDIENTS:
$ingredientsList

RECETTE AU FORMAT COOKLANG:
$currentCooklang

L'utilisateur souhaite modifier cette recette avec la consigne suivante :
"$instruction"

Applique EXACTEMENT cette consigne en modifiant la recette. Conserve tout ce qui n'est pas concerné par la consigne (structure, autres ingrédients, étapes non touchées, etc.).

Retourne la recette MODIFIÉE en DEUX sections exactement dans ce format (rien d'autre) :

===METADATA===
{
  "titre": "Nom de la recette",
  "langue": "fr",
  "ingredients_index": ["ingredient1", "ingredient2"],
  "ingredients": [
    {"name": "ingredient", "qty": "200", "unit": "g"}
  ],
  "tags": {
    "themes": ["plat principal"],
    "cuisines": ["française"],
    "occasions": [],
    "dish_types": ["viande"],
    "difficulty": "facile",
    "prep_time": 20,
    "cook_time": 40
  },
  "portions": 4
}
===COOKLANG===
Contenu complet de la recette modifiée au format CookLang (ici pas de JSON, écris directement)
===END===

Règles CookLang (OBLIGATOIRES) :
- Ingrédients : @nom{quantité%unité} — ex : @farine{200%g}, @oeufs{2}, @sel{}
- Matériel : #nom{} — ex : #four{}, #poêle{}
- Temps : ~{hh:mm:ss} — ex : ~{0:30:00} pour 30 minutes, ~{1:30:00} pour 1h30
- Sections de préparation (quand la recette a plusieurs parties distinctes) : == Nom de section ==
  Exemples : == La sauce ==, == Le montage ==, == La pâte ==
  Mets == Nom == sur sa propre ligne AVANT les étapes de cette partie.
  N'utilise PAS de section si la recette est simple et linéaire.
- Notes et conseils (accompagnement, variante, astuce, conservation…) : > Texte de la note
  Exemples : > Idée d'accompagnement : servir avec une salade verte., > Conseil : peut se préparer la veille.
  Mets > Note sur sa propre ligne, après l'étape concernée ou en fin de recette.
  N'utilise PAS de note si l'information est déjà dans les étapes.
- Chaque étape sur une nouvelle ligne distincte.
- Le texte doit être en français.
- INTERDIT : N'utilise JAMAIS ~{0:00:00} — un timer nul n'a aucun sens.
- INTERDIT : Ne mets PAS de timer pour les températures (ex: "préchauffer le four à 200°C" → écris simplement 200°C dans le texte, sans ~{}).
- INTERDIT : Les mesures d'épaisseur ou de taille dans le texte (ex: 0.5 cm, 1 cm) ne sont PAS des ingrédients — écris-les directement dans le texte, jamais avec @.
- INTERDIT : Ne jamais baliser avec @ le plat ou produit FINAL que la recette crée (ex : chaussons, boulettes, croquettes, raviolis… le nom du produit fini n'est pas un ingrédient). Les instructions de division ("20 parts égales") ne sont jamais des ingrédients — écris-les en texte plain.
- Les timers servent UNIQUEMENT pour des durées réelles de cuisson ou d'attente (valeur strictement > 0).
''';

    final content = Content.text(prompt);
    final response = await _model
        .generateContent([content])
        .timeout(
          const Duration(minutes: 2),
          onTimeout: () => throw TimeoutException('Gemini refine timeout'),
        );
    await _logUsage('refine', response);
    final text = response.text?.trim() ?? '';
    if (text.isEmpty) throw const FormatException('Réponse Gemini vide');

    const metaMarker = '===METADATA===';
    const cooklangMarker = '===COOKLANG===';
    const endMarker = '===END===';
    final metaStart = text.indexOf(metaMarker);
    final cooklangStart = text.indexOf(cooklangMarker);
    if (metaStart == -1 || cooklangStart == -1) {
      throw const FormatException(
        'Format de réponse Gemini invalide (marqueurs manquants)',
      );
    }
    final metaJson = text
        .substring(metaStart + metaMarker.length, cooklangStart)
        .trim();
    final endIdx = text.indexOf(endMarker);
    final cooklang =
        (endIdx == -1
                ? text.substring(cooklangStart + cooklangMarker.length)
                : text.substring(cooklangStart + cooklangMarker.length, endIdx))
            .trim();

    final data =
        json.decode(_extractJsonObject(metaJson)) as Map<String, dynamic>;
    data['cooklang'] = cooklang;
    return data;
  }

  /// Génère une requête Google optimisée à partir d'une demande libre.
  ///
  /// Corrige les fautes, extrait les mots-clés culinaires pertinents et
  /// retourne une requête courte et efficace (sans le mot "recette",
  /// celui-ci sera ajouté en dehors).
  Future<String> generateWebSearchQuery(String userQuery) async {
    final prompt =
        '''
Tu es un expert SEO spécialisé en cuisine.
L'utilisateur veut chercher une recette sur Google avec la demande suivante : "$userQuery"

Génère UNE SEULE requête Google optimisée pour trouver cette recette.
Règles strictes :
- Corrige les fautes d'orthographe
- Garde uniquement les mots-clés culinaires essentiels (nom du plat, type de cuisine, contraintes clés)
- N'ajoute PAS le mot "recette" (il sera ajouté automatiquement)
- Ne dépasse pas 6 mots
- Réponds UNIQUEMENT avec la requête, sans guillemets, sans explication
''';
    final response = await _model
        .generateContent([Content.text(prompt)])
        .timeout(
          const Duration(seconds: 15),
          onTimeout: () =>
              throw TimeoutException('generateWebSearchQuery timeout'),
        );
    await _logUsage('web_search_query', response);
    final query = response.text?.trim() ?? '';
    if (query.isEmpty) throw const FormatException('Réponse Gemini vide');
    return query;
  }

}

class BookCoverExtraction {
  final String titre;
  final String auteur;
  final String? sousTitre;
  final String? editeur;
  final String? serie;
  final int? annee;
  final String langue;
  final String? isbn;
  final String? description;
  final List<String> tags;

  const BookCoverExtraction({
    required this.titre,
    required this.auteur,
    this.sousTitre,
    this.editeur,
    this.serie,
    this.annee,
    required this.langue,
    this.isbn,
    this.description,
    this.tags = const [],
  });

  factory BookCoverExtraction.fromMap(Map<String, dynamic> data) {
    final rawLangue = (data['langue'] as String? ?? 'fr').toLowerCase();
    final langue = switch (rawLangue) {
      'fr' || 'en' || 'nl' => rawLangue,
      _ => 'fr',
    };

    return BookCoverExtraction(
      titre: (data['titre'] as String? ?? '').trim().isEmpty
          ? 'Livre sans titre'
          : (data['titre'] as String).trim(),
      auteur: (data['auteur'] as String? ?? '').trim().isEmpty
          ? 'Auteur inconnu'
          : (data['auteur'] as String).trim(),
      sousTitre: _nullableTrim(data['sous_titre'] as String?),
      editeur: _nullableTrim(data['editeur'] as String?),
      serie: _nullableTrim(data['serie'] as String?),
      annee: _toNullableInt(data['annee']),
      langue: langue,
      isbn: _nullableTrim(data['isbn'] as String?),
      description: _nullableTrim(data['description'] as String?),
      tags: List<String>.from(
        data['tags'] as List? ?? [],
      ).map((e) => e.trim()).where((e) => e.isNotEmpty).toSet().toList(),
    );
  }
}

// ── Helpers CookLang ──────────────────────────────────────────────────────────

/// Extrait les métadonnées >> d'un bloc CookLang.
Map<String, String> parseCooklangMeta(String cooklang) {
  final meta = <String, String>{};
  for (final line in cooklang.split('\n')) {
    final trimmed = line.trim();
    if (trimmed.startsWith('>>')) {
      final content = trimmed.substring(2);
      final colonIdx = content.indexOf(':');
      if (colonIdx > 0) {
        final key = content.substring(0, colonIdx).trim().toLowerCase();
        final value = content.substring(colonIdx + 1).trim();
        meta[key] = value;
      }
    }
  }
  return meta;
}

/// Retourne true si le nom ressemble à une température (ex: "180°c") ou commence
/// par un chiffre — ces tokens ne sont pas des ingrédients.
bool _isTemperatureLike(String name) {
  final n = name.trim().toLowerCase();
  return n.contains('°') || RegExp(r'^\d').hasMatch(n);
}

/// Extrait la liste des ingrédients (@nom) d'un bloc CookLang.
/// Résultat trié par ordre d'apparition, sans doublons de nom, sans températures.
List<String> extractIngredients(String cooklang) {
  final re = RegExp(r'@([^{@#~\n]+)(?:\{[^}]*\})?');
  final seen = <String>{};
  final result = <String>[];
  for (final m in re.allMatches(cooklang)) {
    final name = m.group(1)!.trim().toLowerCase();
    if (_isTemperatureLike(name)) continue;
    if (seen.add(name)) result.add(name);
  }
  return result;
}

/// Normalise un nom d'ingrédient pour la déduplication.
/// - Met en minuscules.
/// - Normalise les apostrophes typographiques (' ') en apostrophe droite (').
/// - Normalise les caractères accentués courants (ç→c, é→e, etc.) pour que
///   « tronçon » et « troncon » soient traités comme le même ingrédient.
/// - Supprime le 's' final de chaque mot (singulier/pluriel).
String _ingredientKey(String name) {
  final s = name
      .toLowerCase()
      // Apostrophes typographiques → apostrophe droite
      .replaceAll('\u2019', "'")
      .replaceAll('\u2018', "'")
      .replaceAll('\u02BC', "'")
      // Accents français courants
      .replaceAll('à', 'a')
      .replaceAll('â', 'a')
      .replaceAll('é', 'e')
      .replaceAll('è', 'e')
      .replaceAll('ê', 'e')
      .replaceAll('ë', 'e')
      .replaceAll('î', 'i')
      .replaceAll('ï', 'i')
      .replaceAll('ô', 'o')
      .replaceAll('ö', 'o')
      .replaceAll('ù', 'u')
      .replaceAll('û', 'u')
      .replaceAll('ü', 'u')
      .replaceAll('ç', 'c')
      .replaceAll('æ', 'ae')
      .replaceAll('œ', 'oe');
  return s
      .split(' ')
      .map(
        (w) =>
            w.endsWith('s') && w.length > 2 ? w.substring(0, w.length - 1) : w,
      )
      .join(' ');
}

/// Extrait la liste structurée des ingrédients avec quantité, unité et catégorie.
/// Triée par ordre d'apparition dans la recette.
/// Les sections CookLang (== Nom ==) sont utilisées comme catégories.
/// Si un même ingrédient apparaît avec des quantités différentes, elles sont
/// combinées (ex : "45 g + une poignée").
List<RecipeIngredient> extractIngredientsStructured(String cooklang) {
  final re = RegExp(r'@([^{@#~\n]+)\{([^}]*)\}');
  final indexMap = <String, int>{};
  final result = <RecipeIngredient>[];
  String? currentCategory;

  for (final line in cooklang.split('\n')) {
    final trimmed = line.trim();
    if (trimmed.isEmpty || trimmed.startsWith('--')) continue;
    if (trimmed.startsWith('>>')) continue; // métadonnées
    if (trimmed.startsWith('>')) continue; // notes — pas d'ingrédients
    if (trimmed.startsWith('==')) {
      // Nouvelle section — met à jour la catégorie courante
      final sectionName = trimmed.replaceAll('==', '').trim();
      currentCategory = sectionName.isEmpty ? null : sectionName;
      continue;
    }
    for (final m in re.allMatches(trimmed)) {
      final name = m.group(1)!.trim();
      if (_isTemperatureLike(name)) continue;
      final key = _ingredientKey(name);
      final parts = (m.group(2) ?? '').split('%');
      final qty = parts.isNotEmpty ? parts[0].trim() : '';
      final unit = parts.length > 1 ? parts[1].trim() : '';
      if (indexMap.containsKey(key)) {
        // Combine les quantités si elles diffèrent
        final idx = indexMap[key]!;
        final existing = result[idx];
        if (qty.isNotEmpty && qty != existing.qty) {
          final combinedQty = existing.qty.isNotEmpty
              ? '${existing.qty} + $qty'
              : qty;
          result[idx] = RecipeIngredient(
            name: existing.name,
            qty: combinedQty,
            unit: existing.unit.isNotEmpty ? existing.unit : unit,
            category: existing.category,
          );
        }
      } else {
        indexMap[key] = result.length;
        result.add(
          RecipeIngredient(
            name: name,
            qty: qty,
            unit: unit,
            category: currentCategory,
          ),
        );
      }
    }
  }
  return result;
}

/// Extrait le nombre de portions depuis les métadonnées CookLang (>> portions: N).
int? extractPortions(String cooklang) {
  final meta = parseCooklangMeta(cooklang);
  final raw = meta['portions'] ?? meta['servings'];
  if (raw == null) return null;
  return int.tryParse(raw.split(' ').first);
}

int? _parseTimeToMinutes(String? raw) {
  if (raw == null || raw.trim().isEmpty) return null;
  final text = raw.toLowerCase().trim();
  final match = RegExp(r'(\d+)').firstMatch(text);
  if (match == null) return null;
  final value = int.tryParse(match.group(1)!);
  if (value == null) return null;
  if (text.contains('h')) {
    return value * 60;
  }
  return value;
}

RecipeTags extractRecipeTags(String cooklang) {
  final meta = parseCooklangMeta(cooklang);
  return RecipeTags(
    difficulty: meta['difficulte'] ?? meta['difficulté'] ?? meta['difficulty'],
    prepTime: _parseTimeToMinutes(
      meta['temps_preparation'] ??
          meta['temps_préparation'] ??
          meta['prep_time'],
    ),
    cookTime: _parseTimeToMinutes(
      meta['temps_cuisson'] ?? meta['cook_time'] ?? meta['cuisson'],
    ),
    dishTypes: _parseCsvList(meta['dish_types']),
  );
}

/// Parse une valeur CSV en liste de strings normalisés.
List<String> _parseCsvList(String? value) {
  if (value == null || value.trim().isEmpty) return const [];
  return value
      .split(',')
      .map((s) => s.trim().toLowerCase())
      .where((s) => s.isNotEmpty)
      .toList();
}

/// Extrait le titre depuis les métadonnées ou retourne un fallback.
String extractTitle(String cooklang) {
  final meta = parseCooklangMeta(cooklang);
  return meta['titre'] ?? meta['title'] ?? meta['nom'] ?? 'Recette sans titre';
}

/// Extrait le numéro de page depuis les métadonnées CookLang (>> page: N).
int? extractPageNumber(String cooklang) {
  final meta = parseCooklangMeta(cooklang);
  final raw = meta['page'] ?? meta['page_number'];
  if (raw == null) return null;
  return int.tryParse(raw.trim().split(' ').first);
}

/// Détecte le type de page depuis les métadonnées (>> page_type: ...).
/// Retourne [PageType.recipe] par défaut si aucun type non-recette n'est détecté.
PageType extractPageType(String content) {
  final meta = parseCooklangMeta(content);
  final raw = (meta['page_type'] ?? '').toLowerCase().trim();
  return switch (raw) {
    'technique' => PageType.technique,
    'equipment' => PageType.equipment,
    'ingredient_note' || 'ingredient note' => PageType.ingredientNote,
    'other' => PageType.other,
    _ => PageType.recipe,
  };
}

/// Supprime les lignes de métadonnées (>> ...) d'un bloc de contenu.
String stripCooklangMeta(String content) {
  return content
      .split('\n')
      .where((line) => !line.trimLeft().startsWith('>>'))
      .join('\n')
      .trim();
}

String _extractJsonObject(String text) {
  final start = text.indexOf('{');
  if (start == -1) throw const FormatException('JSON invalide');

  int depth = 0;
  bool inString = false;
  bool escape = false;

  for (int i = start; i < text.length; i++) {
    final c = text[i];
    if (escape) {
      escape = false;
      continue;
    }
    if (c == r'\' && inString) {
      escape = true;
      continue;
    }
    if (c == '"') {
      inString = !inString;
      continue;
    }
    if (inString) continue;
    if (c == '{') depth++;
    if (c == '}') {
      depth--;
      if (depth == 0) return text.substring(start, i + 1);
    }
  }

  throw const FormatException('JSON invalide : accolades non appariées');
}

String? _nullableTrim(String? value) {
  if (value == null) return null;
  final trimmed = value.trim();
  return trimmed.isEmpty ? null : trimmed;
}

int? _toNullableInt(dynamic value) {
  if (value == null) return null;
  if (value is int) return value;
  if (value is num) return value.toInt();
  if (value is String) return int.tryParse(value.trim());
  return null;
}
