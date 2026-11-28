import 'dart:async';
import 'package:connectivity_plus/connectivity_plus.dart';
import '../db/book_database.dart';
import '../models/book_models.dart';
import 'settings_service.dart';
import 'translator_service.dart';

enum TranslateMode {
  nextChapters,
  specificChapter,
  fullBook,
}

class TranslationProgress {
  final bool isRunning;
  final bool isPausedOffline;
  final int rateLimitWaitSeconds;
  final String activeBookId;
  final String activeBookTitle;
  final String activeModel;
  final int currentChapter;
  final int totalChaptersInJob;
  final int translatedParagraphsInChapter;
  final int totalParagraphsInChapter;
  final String? errorMessage;

  const TranslationProgress({
    this.isRunning = false,
    this.isPausedOffline = false,
    this.rateLimitWaitSeconds = 0,
    this.activeBookId = '',
    this.activeBookTitle = '',
    this.activeModel = '',
    this.currentChapter = 0,
    this.totalChaptersInJob = 0,
    this.translatedParagraphsInChapter = 0,
    this.totalParagraphsInChapter = 0,
    this.errorMessage,
  });

  TranslationProgress copyWith({
    bool? isRunning,
    bool? isPausedOffline,
    int? rateLimitWaitSeconds,
    String? activeBookId,
    String? activeBookTitle,
    String? activeModel,
    int? currentChapter,
    int? totalChaptersInJob,
    int? translatedParagraphsInChapter,
    int? totalParagraphsInChapter,
    String? errorMessage,
  }) {
    return TranslationProgress(
      isRunning: isRunning ?? this.isRunning,
      isPausedOffline: isPausedOffline ?? this.isPausedOffline,
      rateLimitWaitSeconds: rateLimitWaitSeconds ?? this.rateLimitWaitSeconds,
      activeBookId: activeBookId ?? this.activeBookId,
      activeBookTitle: activeBookTitle ?? this.activeBookTitle,
      activeModel: activeModel ?? this.activeModel,
      currentChapter: currentChapter ?? this.currentChapter,
      totalChaptersInJob: totalChaptersInJob ?? this.totalChaptersInJob,
      translatedParagraphsInChapter:
          translatedParagraphsInChapter ?? this.translatedParagraphsInChapter,
      totalParagraphsInChapter:
          totalParagraphsInChapter ?? this.totalParagraphsInChapter,
      errorMessage: errorMessage,
    );
  }
}

class TranslationQueueController {
  final BookDatabase db;
  final TranslatorService translator;

  final StreamController<TranslationProgress> _progressController =
      StreamController<TranslationProgress>.broadcast();

  Stream<TranslationProgress> get progressStream => _progressController.stream;

  TranslationProgress _current = const TranslationProgress();
  TranslationProgress get currentProgress => _current;

  bool _cancelRequested = false;
  static const int batchSize = 5;

  TranslationQueueController({
    required this.db,
    required this.translator,
  });

  void updateSettings(TranslatorSettings newSettings) {
    translator.settings = newSettings;
  }

  void _emit(TranslationProgress next) {
    _current = next;
    if (!_progressController.isClosed) {
      _progressController.add(next);
    }
  }

  void stop() {
    _cancelRequested = true;
    _emit(
      _current.copyWith(
        isRunning: false,
        isPausedOffline: false,
        rateLimitWaitSeconds: 0,
      ),
    );
  }

  Future<bool> _hasInternet() async {
    final results = await Connectivity().checkConnectivity();
    return results.any((r) => r != ConnectivityResult.none);
  }

  Future<void> _waitForInternet() async {
    while (!_cancelRequested) {
      if (await _hasInternet()) {
        _emit(_current.copyWith(isPausedOffline: false, errorMessage: null));
        return;
      }
      _emit(_current.copyWith(isPausedOffline: true));
      await Future.delayed(const Duration(seconds: 3));
    }
  }

  Future<void> _waitForCooldown(int seconds) async {
    for (int left = seconds; left > 0 && !_cancelRequested; left--) {
      _emit(_current.copyWith(rateLimitWaitSeconds: left, errorMessage: null));
      await Future.delayed(const Duration(seconds: 1));
    }
    if (!_cancelRequested) {
      _emit(_current.copyWith(rateLimitWaitSeconds: 0));
    }
  }

  Future<void> startTranslation({
    required String bookId,
    required String bookTitle,
    required int currentReadingChapter,
    required TranslateMode mode,
    int chaptersAhead = 3,
    int specificChapterIndex = 0,
    bool forceRetranslate = false,
    required String targetLanguage,
  }) async {
    if (_current.isRunning) {
      stop();
      await Future.delayed(const Duration(milliseconds: 250));
    }

    _cancelRequested = false;

    final allChapters = await db.getChapters(bookId);
    if (allChapters.isEmpty) return;

    final List<Chapter> targetChapters;
    if (mode == TranslateMode.fullBook) {
      targetChapters = allChapters;
    } else if (mode == TranslateMode.specificChapter) {
      final safeIdx = specificChapterIndex.clamp(0, allChapters.length - 1);
      targetChapters = [allChapters[safeIdx]];
    } else {
      final startIdx = currentReadingChapter.clamp(0, allChapters.length - 1);
      final endIdx =
          (startIdx + chaptersAhead).clamp(startIdx + 1, allChapters.length);
      targetChapters = allChapters.sublist(startIdx, endIdx);
    }

    if (forceRetranslate) {
      await db.clearTranslationsForChapters(
        bookId,
        targetChapters.map((c) => c.index).toList(),
      );
    }

    _emit(
      TranslationProgress(
        isRunning: true,
        activeBookId: bookId,
        activeBookTitle: bookTitle,
        totalChaptersInJob: targetChapters.length,
      ),
    );

    final isOfflineMode =
        translator.settings.engineMode == TranslationEngineMode.offlineLocal;

    try {
      for (final chapter in targetChapters) {
        if (_cancelRequested) break;

        final paragraphs = await db.getChapterParagraphs(bookId, chapter.index);
        if (paragraphs.isEmpty) continue;

        final alreadyTranslatedCount =
            paragraphs.where((p) => p.isTranslated).length;

        if (alreadyTranslatedCount == paragraphs.length) {
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

        int translatedCount = alreadyTranslatedCount;
        _emit(
          _current.copyWith(
            isRunning: true,
            currentChapter: chapter.index + 1,
            translatedParagraphsInChapter: translatedCount,
            totalParagraphsInChapter: paragraphs.length,
            errorMessage: null,
          ),
        );

        final untranslated =
            paragraphs.where((p) => !p.isTranslated).toList();

        int i = 0;
        while (i < untranslated.length) {
          if (_cancelRequested) break;

          if (!isOfflineMode && !await _hasInternet()) {
            await _waitForInternet();
            if (_cancelRequested) break;
          }

          final batch = untranslated.skip(i).take(batchSize).toList();
          final firstOrder = batch.first.orderIndex;

          final contextStart = (firstOrder - 3).clamp(0, paragraphs.length);
          final previousContext = paragraphs
              .sublist(contextStart, firstOrder)
              .map((p) => p.sourceText)
              .toList();

          try {
            final outputs = await translator.translateBatchWithAlignments(
              paragraphs: batch.map((p) => p.sourceText).toList(),
              previousContext: previousContext,
              targetLanguage: targetLanguage,
              onModelSelected: (activeModel) {
                _emit(_current.copyWith(activeModel: activeModel));
              },
            );

            for (int j = 0; j < batch.length; j++) {
              final item = batch[j];
              if (item.id != null) {
                await db.updateParagraphTranslation(
                  item.id!,
                  outputs[j].translation,
                  wordAlignMap: outputs[j].wordAlignMap,
                );
              }
            }

            translatedCount += batch.length;
            i += batch.length;

            _emit(
              _current.copyWith(
                translatedParagraphsInChapter: translatedCount,
                totalParagraphsInChapter: paragraphs.length,
                errorMessage: null,
              ),
            );

            if (i < untranslated.length && !_cancelRequested && !isOfflineMode) {
              await Future.delayed(const Duration(milliseconds: 800));
            }
          } on ModelRateLimitException catch (rateErr) {
            await _waitForCooldown(rateErr.retryAfterSeconds);
          }
        }

        if (_cancelRequested) {
          await db.updateChapterStatus(
            bookId,
            chapter.index,
            translatedCount > 0
                ? ChapterStatus.partial
                : ChapterStatus.pending,
          );
          break;
        } else {
          await db.updateChapterStatus(
            bookId,
            chapter.index,
            ChapterStatus.completed,
          );
        }
      }

      _emit(
        _current.copyWith(
          isRunning: false,
          isPausedOffline: false,
          rateLimitWaitSeconds: 0,
        ),
      );
    } catch (e) {
      _emit(
        _current.copyWith(
          isRunning: false,
          isPausedOffline: false,
          rateLimitWaitSeconds: 0,
          errorMessage: e.toString().replaceFirst('Exception: ', ''),
        ),
      );
    }
  }

  void dispose() {
    _progressController.close();
  }
}
