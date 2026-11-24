import 'package:shared_preferences/shared_preferences.dart';

enum TranslationEngineMode {
  groqCloud,
  offlineLocal,
  customApi,
}

class TranslatorSettings {
  final TranslationEngineMode engineMode;
  final String endpointUrl;
  final String apiKey;
  final String model;
  final List<String> fallbackModels;
  final String targetLanguage;

  const TranslatorSettings({
    this.engineMode = TranslationEngineMode.groqCloud,
    this.endpointUrl = 'https://api.groq.com/openai/v1/chat/completions',
    this.apiKey = '',
    this.model = 'llama-3.3-70b-versatile',
    this.fallbackModels = const [
      'openai/gpt-oss-120b',
      'openai/gpt-oss-20b',
      'meta-llama/llama-4-scout-17b-16e-instruct',
    ],
    this.targetLanguage = 'Russian',
  });

  List<String> get activeModelPool {
    final list = <String>[];
    final primary = model.trim();
    if (primary.isNotEmpty) list.add(primary);
    for (final m in fallbackModels) {
      final clean = m.trim();
      if (clean.isNotEmpty && !list.contains(clean)) {
        list.add(clean);
      }
    }
    return list;
  }

  TranslatorSettings copyWith({
    TranslationEngineMode? engineMode,
    String? endpointUrl,
    String? apiKey,
    String? model,
    List<String>? fallbackModels,
    String? targetLanguage,
  }) {
    return TranslatorSettings(
      engineMode: engineMode ?? this.engineMode,
      endpointUrl: endpointUrl ?? this.endpointUrl,
      apiKey: apiKey ?? this.apiKey,
      model: model ?? this.model,
      fallbackModels: fallbackModels ?? this.fallbackModels,
      targetLanguage: targetLanguage ?? this.targetLanguage,
    );
  }
}

class SettingsService {
  static const _kEngineMode = 'translator_engine_mode';
  static const _kEndpoint = 'translator_endpoint';
  static const _kApiKey = 'translator_api_key';
  static const _kModel = 'translator_model';
  static const _kFallbacks = 'translator_fallback_models';
  static const _kLang = 'translator_target_lang';

  Future<TranslatorSettings> loadSettings() async {
    final prefs = await SharedPreferences.getInstance();
    final modeIdx =
        prefs.getInt(_kEngineMode) ?? TranslationEngineMode.groqCloud.index;

    final savedEndpoint = prefs.getString(_kEndpoint) ?? '';
    final effectiveEndpoint = savedEndpoint.isEmpty ||
            savedEndpoint.contains('openrouter.ai')
        ? 'https://api.groq.com/openai/v1/chat/completions'
        : savedEndpoint;

    final savedModel = prefs.getString(_kModel) ?? '';
    final effectiveModel =
        savedModel.isEmpty || savedModel.contains(':free')
            ? 'llama-3.3-70b-versatile'
            : savedModel;

    return TranslatorSettings(
      engineMode: TranslationEngineMode
          .values[modeIdx.clamp(0, TranslationEngineMode.values.length - 1)],
      endpointUrl: effectiveEndpoint,
      apiKey: prefs.getString(_kApiKey) ?? '',
      model: effectiveModel,
      fallbackModels: prefs.getStringList(_kFallbacks) ??
          const [
            'openai/gpt-oss-120b',
            'openai/gpt-oss-20b',
            'meta-llama/llama-4-scout-17b-16e-instruct',
          ],
      targetLanguage: prefs.getString(_kLang) ?? 'Russian',
    );
  }

  Future<void> saveSettings(TranslatorSettings settings) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_kEngineMode, settings.engineMode.index);
    await prefs.setString(_kEndpoint, settings.endpointUrl.trim());
    await prefs.setString(_kApiKey, settings.apiKey.trim());
    await prefs.setString(_kModel, settings.model.trim());
    await prefs.setStringList(_kFallbacks, settings.fallbackModels);
    await prefs.setString(_kLang, settings.targetLanguage.trim());
  }
}
