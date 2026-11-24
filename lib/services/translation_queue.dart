import 'dart:async';
import 'package:connectivity_plus/connectivity_plus.dart';
import '../db/book_database.dart';
import '../models/book_models.dart';
import 'settings_service.dart';
import 'translator_service.dart';

enum TranslateMode {
  nextChapters,
  fullBook,
}

class TranslationProgress {
  final bool isRunning;
  final bool isPausedOffline;
  final String activeBookId;
  final String activeBookTitle;
  final String activeModel;
  final int currentChapter;
  final int totalChaptersInJob;
  final int translatedParagraphsInChapter;
  final int totalParagraphsInChapter;
  final int rateLimitWaitSeconds;
  final String? errorMessage;

  const TranslationProgress({
    this.isRunning = false,
    this.isPausedOffline = false,
    this.activeBookId = '',
    this.activeBookTitle = '',
    this.activeModel = '',
    this.currentChapter = 0,
    this.totalChaptersInJob = 0,
    this.translatedParagraphsInChapter = 0,
    this.totalParagraphsInChapter = 0,
    this.rateLimitWaitSeconds = 0,
    this.errorMessage,
  });
}

class TranslationQueueController {
  final BookDatabase db;
  final TranslatorService translator;

  final _progressController = StreamController<TranslationProgress>.broadcast();
  Stream<TranslationProgress> get progressStream => _progressController.stream;

  TranslationProgress _currentProgress = const TranslationProgress();
  TranslationProgress get currentProgress => _currentProgress;

  bool _cancelRequested = false;
  int _jobToken = 0;

  TranslationQueueController({
    required this.db,
    required this.translator,
  });

  void updateSettings(TranslatorSettings newSettings) {
    translator.settings = newSettings;
  }

  void _emit(TranslationProgress p) {
    _currentProgress = p;
    if (!_progressController.isClosed) {
      _progressController.add(p);
    }
  }

  void stop() {
    _cancelRequested = true;
    _jobToken++;
    _emit(const TranslationProgress(isRunning: false));
  }

  void dispose() {
    _progressController.close();
  }

  Future<bool> _hasInternet() async {
    if (translator.settings.engineMode == TranslationEngineMode.offlineLocal) {
      return true;
    }
    final res = await Connectivity().checkConnectivity();
    return res.any((r) => r != ConnectivityResult.none);
  }

  Future<void> _waitForInternet(
    int token,
    String bookId,
    String bookTitle,
  ) async {
    while (!_cancelRequested && token == _jobToken) {
      if (await _hasInternet()) return;
      _emit(
        TranslationProgress(
          isRunning: true,
          isPausedOffline: true,
          activeBookId: bookId,
          activeBookTitle: bookTitle,
        ),
      );
      await Future.delayed(const Duration(seconds: 2));
    }
  }

  Future<void> startTranslation({
    required String bookId,
    required String bookTitle,
    required int currentReadingChapter,
    required TranslateMode mode,
    int chaptersAhead = 3,
    required String targetLanguage,
  }) async {
    _cancelRequested = false;
    final token = ++_jobToken;

    final allChapters = await db.getChapters(bookId);
    if (allChapters.isEmpty) return;

    final int startIdx =
        mode == TranslateMode.fullBook ? 0 : currentReadingChapter;
    final int endIdx = mode == TranslateMode.fullBook
        ? allChapters.length - 1
        : (currentReadingChapter + chaptersAhead)
            .clamp(0, allChapters.length - 1);

    final targetChapters = <Chapter>[];
    for (int i = startIdx; i <= endIdx; i++) {
      if (allChapters[i].status != ChapterStatus.completed) {
        targetChapters.add(allChapters[i]);
      }
    }

    if (targetChapters.isEmpty) {
      _emit(const TranslationProgress(isRunning: false));
      return;
    }

    String activeModel = '';

    try {
      for (int cIdx = 0; cIdx < targetChapters.length; cIdx++) {
        if (_cancelRequested || token != _jobToken) return;

        final chapter = targetChapters[cIdx];
        await db.updateChapterStatus(
          bookId,
          chapter.index,
          ChapterStatus.inProgress,
        );

        final paragraphs = await db.getChapterParagraphs(
          bookId,
          chapter.index,
        );
        final untranslated =
            paragraphs.where((p) => !p.isTranslated).toList();

        if (untranslated.isEmpty) {
          await db.updateChapterStatus(
            bookId,
            chapter.index,
            ChapterStatus.completed,
          );
          continue;
        }

        int doneInChapter = paragraphs.length - untranslated.length;
        const batchSize = 5;

        for (int i = 0; i < untranslated.length; i += batchSize) {
          if (_cancelRequested || token != _jobToken) return;

          await _waitForInternet(token, bookId, bookTitle);
          if (_cancelRequested || token != _jobToken) return;

          final chunk = untranslated.skip(i).take(batchSize).toList();
          final firstOrder = chunk.first.orderIndex;

          final prevContext = paragraphs
              .where((p) => p.orderIndex < firstOrder && p.isTranslated)
              .toList()
              .reversed
              .take(3)
              .toList()
              .reversed
              .map((p) => p.translatedText!)
              .toList();

          _emit(
            TranslationProgress(
              isRunning: true,
              activeBookId: bookId,
              activeBookTitle: bookTitle,
              activeModel: activeModel,
              currentChapter: chapter.index + 1,
              totalChaptersInJob: targetChapters.length,
              translatedParagraphsInChapter: doneInChapter,
              totalParagraphsInChapter: paragraphs.length,
            ),
          );

          List<String> translatedChunk;
          while (true) {
            if (_cancelRequested || token != _jobToken) return;
            try {
              translatedChunk = await translator.translateBatch(
                paragraphs: chunk.map((e) => e.sourceText).toList(),
                previousContext: prevContext,
                targetLanguage: targetLanguage,
                onModelSelected: (m) => activeModel = m,
              );
              break;
            } on ModelRateLimitException catch (rateErr) {
              for (int sec = rateErr.retryAfterSeconds; sec > 0; sec--) {
                if (_cancelRequested || token != _jobToken) return;
                _emit(
                  TranslationProgress(
                    isRunning: true,
                    activeBookId: bookId,
                    activeBookTitle: bookTitle,
                    activeModel: activeModel,
                    currentChapter: chapter.index + 1,
                    totalChaptersInJob: targetChapters.length,
                    translatedParagraphsInChapter: doneInChapter,
                    totalParagraphsInChapter: paragraphs.length,
                    rateLimitWaitSeconds: sec,
                  ),
                );
                await Future.delayed(const Duration(seconds: 1));
              }
            }
          }

          for (int k = 0; k < chunk.length; k++) {
            final item = chunk[k];
            if (item.id != null) {
              await db.updateParagraphTranslation(item.id!, translatedChunk[k]);
            }
          }

          doneInChapter += chunk.length;
          _emit(
            TranslationProgress(
              isRunning: true,
              activeBookId: bookId,
              activeBookTitle: bookTitle,
              activeModel: activeModel,
              currentChapter: chapter.index + 1,
              totalChaptersInJob: targetChapters.length,
              translatedParagraphsInChapter: doneInChapter,
              totalParagraphsInChapter: paragraphs.length,
            ),
          );
        }

        await db.updateChapterStatus(
          bookId,
          chapter.index,
          ChapterStatus.completed,
        );
      }

      if (token == _jobToken) {
        _emit(const TranslationProgress(isRunning: false));
      }
    } catch (e) {
      if (token == _jobToken) {
        _emit(
          TranslationProgress(
            isRunning: false,
            activeBookId: bookId,
            activeBookTitle: bookTitle,
            errorMessage: e.toString().replaceFirst('Exception: ', ''),
          ),
        );
      }
    }
  }
}
