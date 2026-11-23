import 'package:shared_preferences/shared_preferences.dart';
import '../models/book_models.dart';

class SettingsService {
  static const _kEndpoint = 'translator_endpoint';
  static const _kApiKey = 'translator_api_key';
  static const _kModel = 'translator_model';
  static const _kFallbackModels = 'translator_fallback_models';
  static const _kAutoSwitch = 'translator_auto_switch';
  static const _kLang = 'translator_target_lang';

  Future<TranslatorSettings> loadSettings() async {
    final prefs = await SharedPreferences.getInstance();
    const defaults = TranslatorSettings();
    return TranslatorSettings(
      endpointUrl: prefs.getString(_kEndpoint) ?? defaults.endpointUrl,
      apiKey: prefs.getString(_kApiKey) ?? defaults.apiKey,
      model: prefs.getString(_kModel) ?? defaults.model,
      fallbackModels:
          prefs.getStringList(_kFallbackModels) ?? defaults.fallbackModels,
      autoSwitchModels: prefs.getBool(_kAutoSwitch) ?? defaults.autoSwitchModels,
      targetLanguage: prefs.getString(_kLang) ?? defaults.targetLanguage,
    );
  }

  Future<void> saveSettings(TranslatorSettings settings) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kEndpoint, settings.endpointUrl.trim());
    await prefs.setString(_kApiKey, settings.apiKey.trim());
    await prefs.setString(_kModel, settings.model.trim());
    await prefs.setStringList(
      _kFallbackModels,
      settings.fallbackModels.map((e) => e.trim()).where((e) => e.isNotEmpty).toList(),
    );
    await prefs.setBool(_kAutoSwitch, settings.autoSwitchModels);
    await prefs.setString(_kLang, settings.targetLanguage.trim());
  }
}
