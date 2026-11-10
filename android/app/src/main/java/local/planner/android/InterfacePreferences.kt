package local.planner.android

import android.app.LocaleManager
import android.app.UiModeManager
import android.content.Context
import android.os.Build
import android.os.LocaleList
import androidx.appcompat.app.AppCompatDelegate
import androidx.core.content.edit
import androidx.core.os.LocaleListCompat

internal enum class InterfaceTheme(val label: Int, val nightMode: Int) {
    System(R.string.settings_follow_device, AppCompatDelegate.MODE_NIGHT_FOLLOW_SYSTEM),
    Light(R.string.settings_theme_light, AppCompatDelegate.MODE_NIGHT_NO),
    Dark(R.string.settings_theme_dark, AppCompatDelegate.MODE_NIGHT_YES),
}

internal enum class InterfaceLanguage(val label: Int, val tag: String) {
    System(R.string.settings_follow_device, ""),
    Russian(R.string.settings_language_russian, "ru"),
    English(R.string.settings_language_english, "en"),
}

private fun interfacePreferences(context: Context) = context.getSharedPreferences("interface_preferences", Context.MODE_PRIVATE)
private const val LEGACY_LANGUAGE = "legacy_language"

internal fun restoreInterfacePreferences(context: Context) {
    applyInterfaceTheme(context, interfaceTheme(context))
    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
        val preferences = interfacePreferences(context)
        val legacy = preferences.getString(LEGACY_LANGUAGE, null) ?: return
        val localeManager = context.getSystemService(LocaleManager::class.java)
        if (localeManager.applicationLocales.isEmpty) {
            localeManager.applicationLocales = LocaleList.forLanguageTags(legacy)
        }
        preferences.edit { remove(LEGACY_LANGUAGE) }
    }
}

internal fun interfaceTheme(context: Context): InterfaceTheme {
    val saved = interfacePreferences(context).getString("theme", null)
    return InterfaceTheme.entries.firstOrNull { it.name == saved } ?: InterfaceTheme.System
}

internal fun setInterfaceTheme(context: Context, theme: InterfaceTheme) {
    interfacePreferences(context).edit { putString("theme", theme.name) }
    applyInterfaceTheme(context, theme)
}

private fun applyInterfaceTheme(context: Context, theme: InterfaceTheme) {
    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
        val mode = when (theme) {
            InterfaceTheme.System -> UiModeManager.MODE_NIGHT_AUTO
            InterfaceTheme.Light -> UiModeManager.MODE_NIGHT_NO
            InterfaceTheme.Dark -> UiModeManager.MODE_NIGHT_YES
        }
        context.getSystemService(UiModeManager::class.java).setApplicationNightMode(mode)
    } else {
        AppCompatDelegate.setDefaultNightMode(theme.nightMode)
    }
}

internal fun interfaceLanguage(context: Context): InterfaceLanguage {
    val locale = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
        context.getSystemService(LocaleManager::class.java).applicationLocales[0]
    } else {
        AppCompatDelegate.getApplicationLocales()[0]
    }
    val language = locale?.language
    return InterfaceLanguage.entries.firstOrNull { it.tag == language } ?: InterfaceLanguage.System
}

internal fun setInterfaceLanguage(context: Context, language: InterfaceLanguage) {
    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
        context.getSystemService(LocaleManager::class.java).applicationLocales = LocaleList.forLanguageTags(language.tag)
    } else {
        interfacePreferences(context).edit {
            if (language == InterfaceLanguage.System) remove(LEGACY_LANGUAGE) else putString(LEGACY_LANGUAGE, language.tag)
        }
        AppCompatDelegate.setApplicationLocales(LocaleListCompat.forLanguageTags(language.tag))
    }
}
