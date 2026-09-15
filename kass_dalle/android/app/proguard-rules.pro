# google_mlkit_text_recognition référence, dans son code natif, les options de
# chaque script (chinois, devanagari, japonais, coréen) même quand l'app
# n'utilise que le latin — voir `sandbox_text_recognition.dart`, qui ne demande
# que `TextRecognitionScript.latin`. Ces classes n'étant pas des dépendances de
# l'app, R8 les déclare manquantes et arrête le build en release.
#
# Elles ne sont jamais atteintes à l'exécution : `-dontwarn` dit à R8 de ne pas
# vérifier ces branches, sans rien retirer de ce qui sert réellement.
-dontwarn com.google.mlkit.vision.text.chinese.**
-dontwarn com.google.mlkit.vision.text.devanagari.**
-dontwarn com.google.mlkit.vision.text.japanese.**
-dontwarn com.google.mlkit.vision.text.korean.**
