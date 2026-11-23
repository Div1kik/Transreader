import 'dart:async';
import 'package:connectivity_plus/connectivity_plus.dart';
import '../db/book_database.dart';
import '../models/book_models.dart';
import 'translator_service.dart';

class TranslationProgress {
  final String activeBookId;
  final String activeBookTitle;
  final int currentChapter;
  final int totalChaptersInJob;
  final int translatedParagraphsInChapter;
  final int totalParagraphsInChapter;
  final String activeModel;
  final bool isPausedOffline;
  final int rateLimitWaitSeconds;
  final bool isRunning;
  final String? errorMessage;

  const TranslationProgress({
    this.activeBookId = '',
    this.activeBookTitle = '',
    this.currentChapter = 0,
    this.totalChaptersInJob = 0,
    this.translatedParagraphsInChapter = 0,
    this.totalParagraphsInChapter = 0,
    this.activeModel = '',
    this.isPausedOffline = false,
    this.rateLimitWaitSeconds = 0,
    this.isRunning = false,
    this.errorMessage,
  });

  TranslationProgress copyWith({
    String? activeBookId,
    String? activeBookTitle,
    int? currentChapter,
    int? totalChaptersInJob,
    int? translatedParagraphsInChapter,
    int? totalParagraphsInChapter,
    String? activeModel,
    bool? isPausedOffline,
    int? rateLimitWaitSeconds,
    bool? isRunning,
    String? errorMessage,
    bool clearError = false,
  }) {
    return TranslationProgress(
      activeBookId: activeBookId ?? this.activeBookId,
      activeBookTitle: activeBookTitle ?? this.activeBookTitle,
      currentChapter: currentChapter ?? this.currentChapter,
      totalChaptersInJob: totalChaptersInJob ?? this.totalChaptersInJob,
      translatedParagraphsInChapter:
          translatedParagraphsInChapter ?? this.translatedParagraphsInChapter,
      totalParagraphsInChapter:
          totalParagraphsInChapter ?? this.totalParagraphsInChapter,
      activeModel: activeModel ?? this.activeModel,
      isPausedOffline: isPausedOffline ?? this.isPausedOffline,
      rateLimitWaitSeconds: rateLimitWaitSeconds ?? this.rateLimitWaitSeconds,
      isRunning: isRunning ?? this.isRunning,
      errorMessage: clearError ? null : (errorMessage ?? this.errorMessage),
    );
  }
}

class TranslationQueueController {
  final BookDatabase db;
  TranslatorService translator;
  final Connectivity connectivity = Connectivity();

  final _progressController = StreamController<TranslationProgress>.broadcast();
  Stream<TranslationProgress> get progressStream => _progressController.stream;

  TranslationProgress _progress = const TranslationProgress();
  TranslationProgress get currentProgress => _progress;

  bool _cancelled = false;
  final Map<String, DateTime> _modelCooldownUntil = {};

  TranslationQueueController({
    required this.db,
    required this.translator,
  });

  void updateSettings(TranslatorSettings newSettings) {
    translator = TranslatorService(settings: newSettings);
  }

  Future<bool> _hasNetwork() async {
    final results = await connectivity.checkConnectivity();
    return results.any((r) => r != ConnectivityResult.none);
  }

  bool _isRateLimitOrModelError(Object error) {
    final msg = error.toString().toLowerCase();
    return msg.contains('429') ||
        msg.contains('rate_limit') ||
        msg.contains('rate limit') ||
        msg.contains('too many requests') ||
        msg.contains('quota') ||
        msg.contains('model_not_found') ||
        msg.contains('503');
  }

  bool _isTransientError(Object error) {
    final msg = error.toString().toLowerCase();
    return error is FormatException ||
        msg.contains('formatexception') ||
        msg.contains('socketexception') ||
        msg.contains('clientexception') ||
        msg.contains('connection refused') ||
        msg.contains('connection reset') ||
        msg.contains('handshakeexception') ||
        msg.contains('timed out') ||
        msg.contains('api 500') ||
        msg.contains('api 502') ||
        msg.contains('api 504');
  }

  Duration _parseCooldownDuration(Object error) {
    final msg = error.toString();
    final lower = msg.toLowerCase();

    if (lower.contains('model_not_found')) {
      return const Duration(hours: 24);
    }

    final match = RegExp(
      r'try again in\s+(?:(\d+)h)?(?:(\d+)m)?(\d+(?:\.\d+)?)\s*(ms|s)',
      caseSensitive: false,
    ).firstMatch(msg);

    if (match != null) {
      final hours = int.tryParse(match.group(1) ?? '') ?? 0;
      final minutes = int.tryParse(match.group(2) ?? '') ?? 0;
      final value = double.tryParse(match.group(3) ?? '') ?? 20.0;
      final unit = (match.group(4) ?? 's').toLowerCase();
      final sec = unit == 'ms' ? (value / 1000.0).ceil() : value.ceil();
      return Duration(hours: hours, minutes: minutes, seconds: sec + 2);
    }

    if (lower.contains('per day') || lower.contains('tpd') || lower.contains('rpd')) {
      return const Duration(minutes: 30);
    }

    return const Duration(seconds: 25);
  }

  String? _pickAvailableModel(List<String> pool) {
    final now = DateTime.now();
    for (final m in pool) {
      final until = _modelCooldownUntil[m];
      if (until == null || !until.isAfter(now)) {
        return m;
      }
    }
    return null;
  }

  Duration _shortestWait(List<String> pool) {
    final now = DateTime.now();
    Duration? minWait;
    for (final m in pool) {
      final until = _modelCooldownUntil[m];
      if (until != null && until.isAfter(now)) {
        final diff = until.difference(now);
        if (minWait == null || diff < minWait) {
          minWait = diff;
        }
      }
    }
    return minWait ?? const Duration(seconds: 15);
  }

  Future<void> _waitWithCountdown(int totalSeconds) async {
    for (int left = totalSeconds; left > 0; left--) {
      if (_cancelled) break;
      _progress = _progress.copyWith(
        rateLimitWaitSeconds: left,
        clearError: true,
      );
      _progressController.add(_progress);
      await Future.delayed(const Duration(seconds: 1));
    }
    if (!_cancelled) {
      _progress = _progress.copyWith(rateLimitWaitSeconds: 0);
      _progressController.add(_progress);
    }
  }

  void stop() {
    _cancelled = true;
    _progress = _progress.copyWith(
      isRunning: false,
      isPausedOffline: false,
      rateLimitWaitSeconds: 0,
    );
    _progressController.add(_progress);
  }

  Future<void> startTranslation({
    required String bookId,
    required String bookTitle,
    required int currentReadingChapter,
    required TranslateMode mode,
    int chaptersAhead = 3,
    int batchSize = 4,
    String targetLanguage = 'русский',
  }) async {
    if (_progress.isRunning) {
      stop();
      await Future.delayed(const Duration(milliseconds: 250));
    }

    _cancelled = false;
    final allChapters = await db.getChapters(bookId);
    if (allChapters.isEmpty) return;

    final modelPool = translator.settings.activeModelChain;
    if (modelPool.isEmpty) return;

    final startIdx = currentReadingChapter.clamp(0, allChapters.length - 1);
    final endIdx = mode == TranslateMode.fullBook
        ? allChapters.length - 1
        : (startIdx + chaptersAhead - 1).clamp(startIdx, allChapters.length - 1);

    final targetChapters = allChapters.sublist(startIdx, endIdx + 1);

    _progress = TranslationProgress(
      activeBookId: bookId,
      activeBookTitle: bookTitle,
      isRunning: true,
      totalChaptersInJob: targetChapters.length,
      activeModel: modelPool.first,
    );
    _progressController.add(_progress);

    for (int i = 0; i < targetChapters.length; i++) {
      if (_cancelled) break;

      final chapter = targetChapters[i];
      final paragraphs = await db.getChapterParagraphs(bookId, chapter.index);
      final pendingParagraphs =
          paragraphs.where((p) => !p.isTranslated).toList();

      if (pendingParagraphs.isEmpty) {
        await db.updateChapterStatus(
          bookId,
          chapter.index,
          ChapterStatus.completed,
        );
        continue;
      }

      await db.updateChapterStatus(
        bookId,
        chapter.index,
        ChapterStatus.inProgress,
      );

      // Берём последние 2 уже переведённых абзаца главы как начальный контекст
      final recentContext = paragraphs
          .where((p) => p.isTranslated)
          .map((p) => p.translatedText!.trim())
          .where((t) => t.isNotEmpty)
          .toList();
      if (recentContext.length > 2) {
        recentContext.removeRange(0, recentContext.length - 2);
      }

      int doneCount = paragraphs.length - pendingParagraphs.length;
      int offset = 0;
      int transientRetries = 0;

      while (offset < pendingParagraphs.length) {
        if (_cancelled) break;

        while (!await _hasNetwork()) {
          if (_cancelled) break;
          _progress = _progress.copyWith(
            isPausedOffline: true,
            rateLimitWaitSeconds: 0,
            currentChapter: chapter.index + 1,
            translatedParagraphsInChapter: doneCount,
            totalParagraphsInChapter: paragraphs.length,
          );
          _progressController.add(_progress);
          await Future.delayed(const Duration(seconds: 2));
        }

        if (_cancelled) break;

        var chosenModel = _pickAvailableModel(modelPool);
        if (chosenModel == null) {
          await db.updateChapterStatus(
            bookId,
            chapter.index,
            ChapterStatus.partial,
          );
          final waitDuration = _shortestWait(modelPool);
          final waitSec = waitDuration.inSeconds.clamp(1, 3600);
          await _waitWithCountdown(waitSec);
          continue;
        }

        _progress = _progress.copyWith(
          isPausedOffline: false,
          rateLimitWaitSeconds: 0,
          isRunning: true,
          activeModel: chosenModel,
          currentChapter: chapter.index + 1,
          translatedParagraphsInChapter: doneCount,
          totalParagraphsInChapter: paragraphs.length,
          clearError: true,
        );
        _progressController.add(_progress);

        final chunk = pendingParagraphs
            .skip(offset)
            .take(batchSize)
            .toList();

        try {
          final translations = await translator.translateBatch(
            paragraphs: chunk.map((e) => e.sourceText).toList(),
            targetLanguage: targetLanguage,
            contextTail: List<String>.from(recentContext),
            overrideModel: chosenModel,
          );

          for (int k = 0; k < chunk.length; k++) {
            final item = chunk[k];
            if (item.id != null) {
              await db.saveParagraphTranslation(item.id!, translations[k]);
              doneCount++;
              recentContext.add(translations[k]);
              if (recentContext.length > 2) {
                recentContext.removeAt(0);
              }
            }
          }

          offset += chunk.length;
          transientRetries = 0;

          _progress = _progress.copyWith(
            translatedParagraphsInChapter: doneCount,
          );
          _progressController.add(_progress);

          if (offset < pendingParagraphs.length && !_cancelled) {
            await Future.delayed(const Duration(milliseconds: 1200));
          }
        } catch (e) {
          if (_isRateLimitOrModelError(e)) {
            final cooldown = _parseCooldownDuration(e);
            _modelCooldownUntil[chosenModel] = DateTime.now().add(cooldown);

            final nextFree = _pickAvailableModel(modelPool);
            if (nextFree != null) {
              _progress = _progress.copyWith(activeModel: nextFree);
              _progressController.add(_progress);
              continue;
            }

            await db.updateChapterStatus(
              bookId,
              chapter.index,
              ChapterStatus.partial,
            );
            final waitSec = _shortestWait(modelPool).inSeconds.clamp(1, 3600);
            await _waitWithCountdown(waitSec);
            continue;
          }

          if (_isTransientError(e) && transientRetries < 4) {
            transientRetries++;
            await Future.delayed(Duration(seconds: 2 * transientRetries));
            continue;
          }

          await db.updateChapterStatus(
            bookId,
            chapter.index,
            ChapterStatus.partial,
          );
          _progress = _progress.copyWith(
            isRunning: false,
            rateLimitWaitSeconds: 0,
            errorMessage: e.toString(),
          );
          _progressController.add(_progress);
          return;
        }
      }

      if (!_cancelled) {
        final updated = await db.getChapters(bookId);
        final currentUpdated =
            updated.firstWhere((c) => c.index == chapter.index);
        final allDone = (await db.getChapterParagraphs(bookId, chapter.index))
            .every((p) => p.isTranslated);

        await db.updateChapterStatus(
          bookId,
          chapter.index,
          allDone ? ChapterStatus.completed : currentUpdated.status,
        );
      }
    }

    _progress = _progress.copyWith(
      isRunning: false,
      isPausedOffline: false,
      rateLimitWaitSeconds: 0,
    );
    _progressController.add(_progress);
  }

  void dispose() {
    _progressController.close();
  }
}
