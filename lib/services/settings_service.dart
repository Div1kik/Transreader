import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';

enum TranslationEngineMode {
  groqCloud,
  offlineLocal,
  customApi,
}

class ApiProviderProfile {
  final String id;
  final String name;
  final String endpointUrl;
  final String apiKey;
  final List<String> models;
  final bool enabled;

  const ApiProviderProfile({
    required this.id,
    required this.name,
    required this.endpointUrl,
    required this.apiKey,
    required this.models,
    this.enabled = true,
  });

  ApiProviderProfile copyWith({
    String? id,
    String? name,
    String? endpointUrl,
    String? apiKey,
    List<String>? models,
    bool? enabled,
  }) {
    return ApiProviderProfile(
      id: id ?? this.id,
      name: name ?? this.name,
      endpointUrl: endpointUrl ?? this.endpointUrl,
      apiKey: apiKey ?? this.apiKey,
      models: models ?? this.models,
      enabled: enabled ?? this.enabled,
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'name': name,
      'endpointUrl': endpointUrl,
      'apiKey': apiKey,
      'models': models,
      'enabled': enabled,
    };
  }

  factory ApiProviderProfile.fromMap(Map<String, dynamic> map) {
    final rawModels = map['models'];
    final parsedModels = rawModels is List
        ? rawModels
            .map((e) => e.toString().trim())
            .where((e) => e.isNotEmpty)
            .toList()
        : <String>[];

    return ApiProviderProfile(
      id: (map['id'] as String?) ??
          DateTime.now().microsecondsSinceEpoch.toString(),
      name: (map['name'] as String?) ?? 'API Провайдер',
      endpointUrl: (map['endpointUrl'] as String?) ??
          'https://api.groq.com/openai/v1/chat/completions',
      apiKey: (map['apiKey'] as String?) ?? '',
      models: parsedModels,
      enabled: (map['enabled'] as bool?) ?? true,
    );
  }
}

class TranslatorSettings {
  final TranslationEngineMode engineMode;
  final String endpointUrl;
  final String apiKey;
  final String model;
  final List<String> fallbackModels;
  final List<ApiProviderProfile> providers;
  final bool fallbackToOfflineOnError;
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
    this.providers = const [],
    this.fallbackToOfflineOnError = false,
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

  /// Возвращает упорядоченный список всех активных провайдеров с заполненным ключом
  List<ApiProviderProfile> get effectiveProviders {
    final result = <ApiProviderProfile>[];

    for (final p in providers) {
      if (p.enabled &&
          p.apiKey.trim().isNotEmpty &&
          p.endpointUrl.trim().isNotEmpty &&
          p.models.isNotEmpty) {
        result.add(p);
      }
    }

    if (result.isEmpty && apiKey.trim().isNotEmpty) {
      final models = activeModelPool;
      if (models.isNotEmpty) {
        result.add(
          ApiProviderProfile(
            id: 'primary_default',
            name: endpointUrl.contains('groq.com')
                ? 'Groq'
                : endpointUrl.contains('openrouter.ai')
                    ? 'OpenRouter'
                    : 'Основной API',
            endpointUrl: endpointUrl.trim(),
            apiKey: apiKey.trim(),
            models: models,
            enabled: true,
          ),
        );
      }
    }

    return result;
  }

  bool get hasAnyOnlineKey => effectiveProviders.isNotEmpty;

  TranslatorSettings copyWith({
    TranslationEngineMode? engineMode,
    String? endpointUrl,
    String? apiKey,
    String? model,
    List<String>? fallbackModels,
    List<ApiProviderProfile>? providers,
    bool? fallbackToOfflineOnError,
    String? targetLanguage,
  }) {
    return TranslatorSettings(
      engineMode: engineMode ?? this.engineMode,
      endpointUrl: endpointUrl ?? this.endpointUrl,
      apiKey: apiKey ?? this.apiKey,
      model: model ?? this.model,
      fallbackModels: fallbackModels ?? this.fallbackModels,
      providers: providers ?? this.providers,
      fallbackToOfflineOnError:
          fallbackToOfflineOnError ?? this.fallbackToOfflineOnError,
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
  static const _kProvidersJson = 'translator_providers_json';
  static const _kFallbackOffline = 'translator_fallback_offline_on_err';
  static const _kLang = 'translator_target_lang';

  static const List<String> defaultGeminiModels = [
    'gemini-4-hydrogen',
    'gemini-3.8-flash',
    'gemini-3.5-flash-lite',
  ];

  static const Set<String> _deprecatedGeminiModels = {
    'gemini-2.5-flash',
    'gemini-2.5-flash-lite',
    'gemini-2.5-pro',
    'gemini-2.0-flash',
    'gemini-2.0-flash-lite',
    'gemini-1.5-flash',
    'gemini-1.5-pro',
  };

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

    final savedApiKey = prefs.getString(_kApiKey) ?? '';
    final savedFallbacks = prefs.getStringList(_kFallbacks) ??
        const [
          'openai/gpt-oss-120b',
          'openai/gpt-oss-20b',
          'meta-llama/llama-4-scout-17b-16e-instruct',
        ];

    List<ApiProviderProfile> loadedProviders = [];
    bool needsResave = false;
    final rawProviders = prefs.getString(_kProvidersJson);
    if (rawProviders != null && rawProviders.isNotEmpty) {
      try {
        final decoded = jsonDecode(rawProviders);
        if (decoded is List) {
          loadedProviders = decoded.whereType().map((m) {
            var profile =
                ApiProviderProfile.fromMap(Map<String, dynamic>.from(m));
            // Автообновление закрытых моделей Gemini на актуальные в уже сохранённых настройках
            if (profile.endpointUrl
                .contains('generativelanguage.googleapis.com')) {
              final hasDeprecated = profile.models
                  .any((mdl) => _deprecatedGeminiModels.contains(mdl));
              if (hasDeprecated || profile.models.isEmpty) {
                profile = profile.copyWith(models: defaultGeminiModels);
                needsResave = true;
              }
            }
            return profile;
          }).toList();
        }
      } catch (_) {}
    }

    if (loadedProviders.isEmpty && savedApiKey.trim().isNotEmpty) {
      final initialModels = <String>[
        effectiveModel,
        ...savedFallbacks.where((m) => m != effectiveModel),
      ];
      loadedProviders = [
        ApiProviderProfile(
          id: 'groq_main',
          name: effectiveEndpoint.contains('groq.com')
              ? 'Groq (Основной)'
              : 'Основной провайдер',
          endpointUrl: effectiveEndpoint,
          apiKey: savedApiKey.trim(),
          models: initialModels,
          enabled: true,
        ),
      ];
      needsResave = true;
    }

    final settings = TranslatorSettings(
      engineMode: TranslationEngineMode
          .values[modeIdx.clamp(0, TranslationEngineMode.values.length - 1)],
      endpointUrl: effectiveEndpoint,
      apiKey: savedApiKey,
      model: effectiveModel,
      fallbackModels: savedFallbacks,
      providers: loadedProviders,
      fallbackToOfflineOnError: prefs.getBool(_kFallbackOffline) ?? false,
      targetLanguage: prefs.getString(_kLang) ?? 'Russian',
    );

    if (needsResave) {
      await saveSettings(settings);
    }

    return settings;
  }

  Future<void> saveSettings(TranslatorSettings settings) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_kEngineMode, settings.engineMode.index);
    await prefs.setString(_kEndpoint, settings.endpointUrl.trim());
    await prefs.setString(_kApiKey, settings.apiKey.trim());
    await prefs.setString(_kModel, settings.model.trim());
    await prefs.setStringList(_kFallbacks, settings.fallbackModels);
    await prefs.setString(
      _kProvidersJson,
      jsonEncode(settings.providers.map((p) => p.toMap()).toList()),
    );
    await prefs.setBool(
      _kFallbackOffline,
      settings.fallbackToOfflineOnError,
    );
    await prefs.setString(_kLang, settings.targetLanguage.trim());
  }
}
