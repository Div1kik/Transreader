import 'package:google_mlkit_translation/google_mlkit_translation.dart';

class OfflineTranslatorService {
  static final OfflineTranslatorService instance = OfflineTranslatorService._();
  OfflineTranslatorService._();

  final OnDeviceTranslatorModelManager _modelManager =
      OnDeviceTranslatorModelManager();

  TranslateLanguage _mapTargetLang(String targetLanguage) {
    final lower = targetLanguage.toLowerCase();
    if (lower.contains('english') || lower.contains('англ')) {
      return TranslateLanguage.english;
    }
    if (lower.contains('german') || lower.contains('немец')) {
      return TranslateLanguage.german;
    }
    if (lower.contains('french') || lower.contains('франц')) {
      return TranslateLanguage.french;
    }
    if (lower.contains('spanish') || lower.contains('испан')) {
      return TranslateLanguage.spanish;
    }
    return TranslateLanguage.russian;
  }

  Future<bool> isPairDownloaded({
    TranslateLanguage source = TranslateLanguage.english,
    String targetLanguage = 'Russian',
  }) async {
    final target = _mapTargetLang(targetLanguage);
    final hasSource = await _modelManager.isModelDownloaded(source.bcpCode);
    final hasTarget = await _modelManager.isModelDownloaded(target.bcpCode);
    return hasSource && hasTarget;
  }

  Future<void> downloadLanguagePair({
    TranslateLanguage source = TranslateLanguage.english,
    String targetLanguage = 'Russian',
    void Function(String step)? onProgress,
  }) async {
    final target = _mapTargetLang(targetLanguage);

    if (!await _modelManager.isModelDownloaded(source.bcpCode)) {
      onProgress?.call('Загрузка базового пакета (${source.bcpCode})...');
      final okSource = await _modelManager
          .downloadModel(source.bcpCode, isWifiRequired: false)
          .timeout(
            const Duration(seconds: 90),
            onTimeout: () => throw Exception(
              'Таймаут загрузки (${source.bcpCode}). Проверьте VPN (для Google ML Kit лучше отключить VPN или разрешить «Диспетчер загрузок»).',
            ),
          );
      if (!okSource) {
        throw Exception('Не удалось скачать базовый пакет (${source.bcpCode})');
      }
    }

    if (!await _modelManager.isModelDownloaded(target.bcpCode)) {
      onProgress?.call('Загрузка языкового пакета (${target.bcpCode})...');
      final okTarget = await _modelManager
          .downloadModel(target.bcpCode, isWifiRequired: false)
          .timeout(
            const Duration(seconds: 90),
            onTimeout: () => throw Exception(
              'Таймаут загрузки (${target.bcpCode}). Проверьте VPN (для Google ML Kit лучше отключить VPN или разрешить «Диспетчер загрузок»).',
            ),
          );
      if (!okTarget) {
        throw Exception('Не удалось скачать языковой пакет (${target.bcpCode})');
      }
    }
  }

  Future<String> translateText(
    String text, {
    TranslateLanguage source = TranslateLanguage.english,
    String targetLanguage = 'Russian',
  }) async {
    final trimmed = text.trim();
    if (trimmed.isEmpty) return '';

    final target = _mapTargetLang(targetLanguage);
    await downloadLanguagePair(source: source, targetLanguage: targetLanguage);

    final translator = OnDeviceTranslator(
      sourceLanguage: source,
      targetLanguage: target,
    );
    try {
      return await translator.translateText(trimmed);
    } finally {
      await translator.close();
    }
  }
}
