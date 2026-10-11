package dev.kassbi.kass_dalle

import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.provider.Settings
import androidx.core.content.FileProvider
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File

/**
 * Kass'Dalle n'est pas distribuée par le Play Store : elle se met à jour
 * elle-même. Ce canal porte les trois gestes qu'Android réserve au code natif —
 * savoir où écrire, savoir si l'installation est autorisée, ouvrir
 * l'installateur du système.
 *
 * Le téléchargement, lui, reste côté Dart : il a besoin de la progression pour
 * l'afficher, et rien dans une requête HTTP n'exige du natif.
 *
 * Un second canal reçoit « Partager vers Kass'Dalle » (filtre `ACTION_SEND`
 * `text/plain` du manifeste) sans paquet tiers : le texte partagé est gardé en
 * attente, rendu par `getInitialSharedText`, et poussé vers Dart par
 * `onSharedText` quand l'application tourne déjà — voir
 * `features/recipes/data/share_intent_source.dart`.
 */
class MainActivity : FlutterActivity() {

    private companion object {
        const val CHANNEL = "dev.kassbi.kass_dalle/app_installer"
        const val AUTHORITY_SUFFIX = ".updateprovider"
        const val UPDATES_DIR = "updates"
        const val APK_MIME = "application/vnd.android.package-archive"
        const val SHARE_CHANNEL = "dev.kassbi.kass_dalle/share"
    }

    private var shareChannel: MethodChannel? = null

    /** Le dernier partage reçu que Dart n'a pas encore pris. */
    private var pendingSharedText: String? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "downloadDir" -> handleDownloadDir(result)
                    "canRequestInstall" -> result.success(canRequestInstall())
                    "openInstallSettings" -> handleOpenInstallSettings(result)
                    "installApk" -> handleInstallApk(call.argument<String>("path"), result)
                    else -> result.notImplemented()
                }
            }

        shareChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, SHARE_CHANNEL)
            .also { channel ->
                channel.setMethodCallHandler { call, result ->
                    when (call.method) {
                        "getInitialSharedText" -> {
                            result.success(pendingSharedText)
                            pendingSharedText = null
                        }
                        else -> result.notImplemented()
                    }
                }
            }
    }

    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        shareChannel?.setMethodCallHandler(null)
        shareChannel = null
        super.cleanUpFlutterEngine(flutterEngine)
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        // Une activité recréée (processus tué puis restauré) ou rouverte
        // depuis les applications récentes reçoit à nouveau l'intention
        // d'origine : le partage a déjà été traité, on ne le rejoue pas.
        val fromHistory = (intent.flags and Intent.FLAG_ACTIVITY_LAUNCHED_FROM_HISTORY) != 0
        if (savedInstanceState == null && !fromHistory) {
            sharedTextOf(intent)?.let { pendingSharedText = it }
        }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        val text = sharedTextOf(intent) ?: return
        pendingSharedText = text
        val channel = shareChannel ?: return
        // Le texte reste en attente tant que Dart n'a pas confirmé l'avoir
        // reçu : sans écouteur côté Dart, `getInitialSharedText` le rendra.
        channel.invokeMethod(
            "onSharedText",
            text,
            object : MethodChannel.Result {
                override fun success(result: Any?) {
                    if (pendingSharedText == text) pendingSharedText = null
                }

                override fun error(code: String, message: String?, details: Any?) = Unit

                override fun notImplemented() = Unit
            },
        )
    }

    /**
     * Le texte d'un partage `ACTION_SEND` `text/plain` : `EXTRA_TEXT`, à défaut
     * `EXTRA_SUBJECT`. Chaîne vide pour un partage sans texte lisible (l'écran
     * dit alors qu'il ne contient pas d'adresse web) ; `null` pour toute autre
     * intention.
     */
    private fun sharedTextOf(intent: Intent?): String? {
        if (intent?.action != Intent.ACTION_SEND) return null
        if (intent.type?.startsWith("text/plain") != true) return null
        val text = intent.getCharSequenceExtra(Intent.EXTRA_TEXT)?.toString()
        if (!text.isNullOrBlank()) return text
        return intent.getCharSequenceExtra(Intent.EXTRA_SUBJECT)?.toString() ?: ""
    }

    /**
     * Le cache, et pas le stockage de données : un APK de 90 Mo qu'on a fini
     * d'installer n'a plus aucune raison d'exister, et le système sait effacer
     * un cache quand la place manque.
     */
    private fun handleDownloadDir(result: MethodChannel.Result) {
        val dir = File(cacheDir, UPDATES_DIR)
        if (!dir.exists() && !dir.mkdirs()) {
            result.error(
                "download_dir_unavailable",
                "Impossible de créer ${dir.absolutePath}",
                null,
            )
            return
        }
        result.success(dir.absolutePath)
    }

    /**
     * Avant Android 8, l'autorisation « sources inconnues » était un réglage
     * global du téléphone : aucune application ne pouvait la demander pour
     * elle-même, et l'installateur s'ouvrait sans condition.
     */
    private fun canRequestInstall(): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return true
        return packageManager.canRequestPackageInstalls()
    }

    private fun handleOpenInstallSettings(result: MethodChannel.Result) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) {
            result.success(false)
            return
        }
        try {
            startActivity(
                Intent(
                    Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES,
                    Uri.parse("package:$packageName"),
                ).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
            )
            result.success(true)
        } catch (e: Exception) {
            result.error("install_settings_failed", e.message, null)
        }
    }

    private fun handleInstallApk(path: String?, result: MethodChannel.Result) {
        if (path.isNullOrEmpty()) {
            result.error("invalid_path", "Chemin de l'APK absent", null)
            return
        }
        val apk = File(path)
        if (!apk.exists()) {
            result.error("apk_missing", "APK introuvable : $path", null)
            return
        }
        try {
            val uri = FileProvider.getUriForFile(this, "$packageName$AUTHORITY_SUFFIX", apk)
            startActivity(
                Intent(Intent.ACTION_VIEW)
                    .setDataAndType(uri, APK_MIME)
                    .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                    .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
            )
            result.success(true)
        } catch (e: Exception) {
            result.error("install_failed", e.message, null)
        }
    }
}
