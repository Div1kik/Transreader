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
  }) async {
    final target = _mapTargetLang(targetLanguage);
    if (!await _modelManager.isModelDownloaded(source.bcpCode)) {
      await _modelManager.downloadModel(source.bcpCode);
    }
    if (!await _modelManager.isModelDownloaded(target.bcpCode)) {
      await _modelManager.downloadModel(target.bcpCode);
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
