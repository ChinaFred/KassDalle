package dev.kassbi.kass_dalle

import android.content.Intent
import android.net.Uri
import android.os.Build
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
 */
class MainActivity : FlutterActivity() {

    private companion object {
        const val CHANNEL = "dev.kassbi.kass_dalle/app_installer"
        const val AUTHORITY_SUFFIX = ".updateprovider"
        const val UPDATES_DIR = "updates"
        const val APK_MIME = "application/vnd.android.package-archive"
    }

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
