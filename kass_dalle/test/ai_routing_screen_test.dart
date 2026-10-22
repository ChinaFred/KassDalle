import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kass_dalle/features/admin/data/ai_routing_repository.dart';
import 'package:kass_dalle/features/admin/presentation/ai_routing_screen.dart';

/// L'écran Moteur d'IA : défauts, « Défaut (…) » par poste, et confirmation
/// avant de changer un défaut suivi.
class _FakeRepository implements AiRoutingRepository {
  _FakeRepository(this.snapshot);

  final AiRoutingSnapshot snapshot;
  AiRoutingPolicy? saved;

  @override
  Future<AiRoutingSnapshot> fetch() async => snapshot;

  @override
  Future<AiRoutingSnapshot> save(AiRoutingPolicy policy) async {
    saved = policy;
    return AiRoutingSnapshot(
      policy: policy,
      anthropicKeyPresent: true,
      routableFeatures: const [],
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

const _models = [
  AnthropicModelChoice(id: 'claude-opus-5', label: 'Opus 5', hint: ''),
  AnthropicModelChoice(id: 'claude-sonnet-5', label: 'Sonnet 5', hint: ''),
  AnthropicModelChoice(
    id: 'claude-haiku-4-5',
    label: 'Haiku 4.5',
    hint: '',
    supportsEffort: false,
  ),
];

const _efforts = [
  AnthropicEffortChoice(id: 'low', label: 'Basse', hint: ''),
  AnthropicEffortChoice(id: 'medium', label: 'Moyenne', hint: ''),
  AnthropicEffortChoice(id: 'high', label: 'Haute', hint: ''),
];

AiRoutingSnapshot _snapshot(
  AiRoutingPolicy policy, {
  List<AiRoutingPreset> presets = const [],
}) => AiRoutingSnapshot(
  policy: policy,
  presets: presets,
  anthropicKeyPresent: true,
  routableFeatures: const [
    RoutableFeature(
      id: 'transcription_page',
      label: 'Transcription',
      group: 'Import',
      codeEffort: 'high',
    ),
    RoutableFeature(
      id: 'generate',
      label: 'Génération',
      group: 'Rédaction',
      codeEffort: 'low',
    ),
  ],
  anthropicModelChoices: _models,
  anthropicEffortChoices: _efforts,
);

/// Hauteur large : la police des tests (Ahem) rend chaque caractère carré,
/// et la liste ne construit que ce qui tient à l'écran.
Future<_FakeRepository> _pump(
  WidgetTester tester,
  AiRoutingPolicy policy, {
  Size size = const Size(400, 12000),
  double textScale = 1,
  List<AiRoutingPreset> presets = const [],
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  tester.platformDispatcher.textScaleFactorTestValue = textScale;
  addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
  final repo = _FakeRepository(_snapshot(policy, presets: presets));
  await tester.pumpWidget(
    ProviderScope(
      overrides: [aiRoutingRepositoryProvider.overrideWithValue(repo)],
      child: const MaterialApp(home: AiRoutingScreen()),
    ),
  );
  await tester.pumpAndSettle();
  return repo;
}

void main() {
  const surClaude = AiRoutingPolicy(
    defaultProvider: AiProvider.anthropic,
    features: {},
    anthropicModel: 'claude-sonnet-5',
    fallbackEnabled: true,
  );

  testWidgets('chaque poste propose « Défaut (…) » à part', (tester) async {
    await _pump(tester, surClaude);

    expect(find.text('Défaut (Claude)'), findsNWidgets(2));
    expect(find.text('Défaut (Sonnet 5)'), findsNWidgets(2));
    expect(find.text('Selon le poste (haute)'), findsOneWidget);
    expect(find.text('Selon le poste (basse)'), findsOneWidget);
    expect(find.text('Suivi par 2 postes.'), findsNWidgets(3));
    expect(find.text('Suivent un défaut (2)'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('changer le modèle par défaut demande confirmation et fige', (
    tester,
  ) async {
    final repo = await _pump(tester, surClaude);

    await tester.tap(find.text('Sonnet 5').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Haiku 4.5').last);
    await tester.pumpAndSettle();

    expect(find.text('Changer le modèle par défaut ?'), findsOneWidget);
    expect(
      find.text(
        '2 postes suivent le modèle par défaut : ils garderont Sonnet 5. '
        'Le nouveau défaut servira aux postes que vous remettrez sur '
        '« Défaut », à ceux que vous passerez sur Claude et à ceux '
        'qu\'ajoutera une mise à jour.',
      ),
      findsOneWidget,
    );
    await tester.tap(find.text('Changer le défaut'));
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Enregistrer le routage en vigueur'));
    await tester.pumpAndSettle();

    expect(repo.saved?.anthropicModel, 'claude-haiku-4-5');
    expect(repo.saved?.anthropicModels, {
      'transcription_page': 'claude-sonnet-5',
      'generate': 'claude-sonnet-5',
    });
  });

  testWidgets('aucune confirmation quand aucun poste ne suit le défaut', (
    tester,
  ) async {
    await _pump(
      tester,
      const AiRoutingPolicy(
        defaultProvider: AiProvider.anthropic,
        features: {
          'transcription_page': AiProvider.anthropic,
          'generate': AiProvider.anthropic,
        },
        anthropicModel: 'claude-sonnet-5',
        fallbackEnabled: true,
      ),
    );

    // Le moteur par défaut n'est suivi par aucun poste.
    await tester.tap(find.text('Gemini').first);
    await tester.pumpAndSettle();

    expect(find.text('Changer le moteur par défaut ?'), findsNothing);
    expect(find.text('Défaut (Gemini)'), findsNWidgets(2));
  });

  testWidgets('un poste sur Haiku 4.5 ne propose pas de réflexion', (
    tester,
  ) async {
    await _pump(
      tester,
      const AiRoutingPolicy(
        defaultProvider: AiProvider.anthropic,
        features: {},
        anthropicModel: 'claude-sonnet-5',
        fallbackEnabled: true,
        anthropicModels: {'generate': 'claude-haiku-4-5'},
        anthropicEfforts: {'generate': 'high'},
      ),
    );

    expect(
      find.text(
        'Pas de réflexion avec Haiku 4.5. Réflexion haute enregistrée, '
        'ignorée tant que le poste est sur Haiku 4.5.',
      ),
      findsOneWidget,
    );
  });

  testWidgets('écran large : aucune erreur de mise en page', (tester) async {
    await _pump(tester, surClaude, size: const Size(1200, 8000));
    expect(find.text('Défaut (Claude)'), findsNWidgets(2));
    expect(tester.takeException(), isNull);
  });

  testWidgets('360 px et texte à 200 % : aucun débordement', (tester) async {
    await _pump(tester, surClaude, size: const Size(360, 30000), textScale: 2);
    expect(find.text('Tout Gemini'), findsOneWidget);
    expect(find.text('Tout Claude'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('changer le moteur par défaut demande confirmation et fige', (
    tester,
  ) async {
    final repo = await _pump(tester, surClaude);

    await tester.tap(find.text('Gemini').first);
    await tester.pumpAndSettle();

    expect(find.text('Changer le moteur par défaut ?'), findsOneWidget);
    expect(
      find.text(
        '2 postes suivent le moteur par défaut : ils garderont Claude. '
        'Le nouveau défaut servira aux postes que vous remettrez sur '
        "« Défaut » et à ceux qu'ajoutera une mise à jour.",
      ),
      findsOneWidget,
    );
    await tester.tap(find.text('Changer le défaut'));
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Enregistrer le routage en vigueur'));
    await tester.pumpAndSettle();

    expect(repo.saved?.defaultProvider, AiProvider.gemini);
    expect(repo.saved?.features, {
      'transcription_page': AiProvider.anthropic,
      'generate': AiProvider.anthropic,
    });
  });

  testWidgets('changer la réflexion par défaut demande confirmation et fige', (
    tester,
  ) async {
    final repo = await _pump(tester, surClaude);

    await tester.tap(find.text('Selon le poste').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Basse').last);
    await tester.pumpAndSettle();

    expect(find.text('Changer la réflexion par défaut ?'), findsOneWidget);
    expect(
      find.text(
        '2 postes suivent la réflexion par défaut : ils garderont la '
        'réflexion propre à chaque poste. Le nouveau défaut servira aux '
        'postes que vous remettrez sur « Défaut », à ceux que vous passerez '
        "sur Claude et à ceux qu'ajoutera une mise à jour.",
      ),
      findsOneWidget,
    );
    await tester.tap(find.text('Changer le défaut'));
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Enregistrer le routage en vigueur'));
    await tester.pumpAndSettle();

    expect(repo.saved?.anthropicEffort, 'low');
    expect(repo.saved?.anthropicEfforts, {
      'transcription_page': 'high',
      'generate': 'low',
    });
  });

  testWidgets('le sélecteur d\'un défaut annonce le titre de sa ligne', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    await _pump(tester, surClaude);

    expect(
      find.bySemanticsLabel(RegExp('^Modèle de Claude par défaut')),
      findsOneWidget,
    );
    expect(
      find.bySemanticsLabel(RegExp('^Réflexion de Claude par défaut')),
      findsOneWidget,
    );
    // Les segments restent deux boutons : le titre nomme leur groupe.
    expect(find.bySemanticsLabel(RegExp('^Moteur par défaut')), findsWidgets);
    semantics.dispose();
  });

  group('filtre « Suivent un défaut »', () {
    // `transcription_page` suit les trois défauts ; `generate` a ses trois
    // choix propres.
    const unSeulSuit = AiRoutingPolicy(
      defaultProvider: AiProvider.anthropic,
      features: {'generate': AiProvider.anthropic},
      anthropicModel: 'claude-sonnet-5',
      fallbackEnabled: true,
      anthropicModels: {'generate': 'claude-sonnet-5'},
      anthropicEfforts: {'generate': 'low'},
    );

    testWidgets('un poste qui sort du filtre reste affiché jusqu\'au '
        'prochain appui', (tester) async {
      await _pump(tester, unSeulSuit);

      await tester.tap(find.text('Suivent un défaut (1)'));
      await tester.pumpAndSettle();
      expect(find.text('Transcription'), findsOneWidget);
      expect(find.text('Génération'), findsNothing);

      // Trois choix propres : le poste ne suit plus aucun défaut.
      await tester.tap(find.widgetWithText(ChoiceChip, 'Claude'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(ChoiceChip, 'Sonnet 5'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(ChoiceChip, 'Haute'));
      await tester.pumpAndSettle();

      // Liste figée : le compteur dit le nombre de postes affichés.
      expect(find.text('Suivent un défaut (1)'), findsOneWidget);
      expect(find.text('Transcription'), findsOneWidget);

      // Désactiver puis réactiver recalcule la liste.
      await tester.tap(find.text('Suivent un défaut (1)'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Suivent un défaut (0)'));
      await tester.pumpAndSettle();
      expect(find.text('Transcription'), findsNothing);
      expect(find.text('Afficher tous les postes'), findsOneWidget);

      await tester.tap(find.text('Afficher tous les postes'));
      await tester.pumpAndSettle();
      expect(find.text('Transcription'), findsOneWidget);
      expect(find.text('Génération'), findsOneWidget);
    });

    testWidgets('charger une configuration retire le filtre figé', (
      tester,
    ) async {
      await _pump(
        tester,
        surClaude,
        presets: const [
          AiRoutingPreset(
            id: 'p1',
            name: 'Tout figé',
            policy: AiRoutingPolicy(
              defaultProvider: AiProvider.anthropic,
              features: {
                'transcription_page': AiProvider.anthropic,
                'generate': AiProvider.anthropic,
              },
              anthropicModel: 'claude-sonnet-5',
              fallbackEnabled: true,
              anthropicModels: {
                'transcription_page': 'claude-sonnet-5',
                'generate': 'claude-sonnet-5',
              },
              anthropicEfforts: {
                'transcription_page': 'high',
                'generate': 'low',
              },
            ),
          ),
        ],
      );

      await tester.tap(find.text('Suivent un défaut (2)'));
      await tester.pumpAndSettle();

      await tester.tap(
        find.byWidgetPredicate(
          (w) => w is DropdownButton<String> && w.hint != null,
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Tout figé').last);
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Charger'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Charger').last);
      await tester.pumpAndSettle();

      // Le filtre figé nommait les postes de l'ancien brouillon.
      final chip = tester.widget<FilterChip>(find.byType(FilterChip));
      expect(chip.selected, isFalse);
      expect(find.text('Suivent un défaut (0)'), findsOneWidget);
      expect(find.text('Transcription'), findsOneWidget);
      expect(find.text('Génération'), findsOneWidget);
    });

    testWidgets('« Tout Claude » ne bascule que les postes affichés', (
      tester,
    ) async {
      final repo = await _pump(
        tester,
        const AiRoutingPolicy(
          defaultProvider: AiProvider.gemini,
          features: {'generate': AiProvider.gemini},
          anthropicModel: 'claude-sonnet-5',
          fallbackEnabled: true,
        ),
      );

      await tester.tap(find.text('Suivent un défaut (1)'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Tout Claude'));
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('Enregistrer le routage en vigueur'));
      await tester.pumpAndSettle();

      expect(repo.saved?.features, {
        'transcription_page': AiProvider.anthropic,
        'generate': AiProvider.gemini,
      });
    });
  });
}
