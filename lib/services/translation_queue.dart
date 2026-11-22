import 'dart:async';
import 'package:connectivity_plus/connectivity_plus.dart';
import '../db/book_database.dart';
import '../models/book_models.dart';
import 'translator_service.dart';

class TranslationProgress {
  final int currentChapter;
  final int totalChaptersInJob;
  final int translatedParagraphsInChapter;
  final int totalParagraphsInChapter;
  final bool isPausedOffline;
  final bool isRunning;
  final String? errorMessage;

  const TranslationProgress({
    this.currentChapter = 0,
    this.totalChaptersInJob = 0,
    this.translatedParagraphsInChapter = 0,
    this.totalParagraphsInChapter = 0,
    this.isPausedOffline = false,
    this.isRunning = false,
    this.errorMessage,
  });

  TranslationProgress copyWith({
    int? currentChapter,
    int? totalChaptersInJob,
    int? translatedParagraphsInChapter,
    int? totalParagraphsInChapter,
    bool? isPausedOffline,
    bool? isRunning,
    String? errorMessage,
    bool clearError = false,
  }) {
    return TranslationProgress(
      currentChapter: currentChapter ?? this.currentChapter,
      totalChaptersInJob: totalChaptersInJob ?? this.totalChaptersInChapter,
      translatedParagraphsInChapter:
          translatedParagraphsInChapter ?? this.translatedParagraphsInChapter,
      totalParagraphsInChapter:
          totalParagraphsInChapter ?? this.totalParagraphsInChapter,
      isPausedOffline: isPausedOffline ?? this.isPausedOffline,
      isRunning: isRunning ?? this.isRunning,
      errorMessage: clearError ? null : (errorMessage ?? this.errorMessage),
    );
  }
}

class TranslationQueueController {
  final BookDatabase db;
  final TranslatorService translator;
  final Connectivity connectivity = Connectivity();

  final _progressController = StreamController<TranslationProgress>.broadcast();
  Stream<TranslationProgress> get progressStream => _progressController.stream;

  TranslationProgress _progress = const TranslationProgress();
  bool _cancelled = false;

  TranslationQueueController({
    required this.db,
    required this.translator,
  });

  Future<bool> _hasNetwork() async {
    final results = await connectivity.checkConnectivity();
    return results.any((r) => r != ConnectivityResult.none);
  }

  void stop() {
    _cancelled = true;
    _progress = _progress.copyWith(isRunning: false, isPausedOffline: false);
    _progressController.add(_progress);
  }

  Future<void> startTranslation({
    required String bookId,
    required int currentReadingChapter,
    required TranslateMode mode,
    int chaptersAhead = 3,
    int batchSize = 8,
    String targetLanguage = 'русский',
  }) async {
    _cancelled = false;
    final allChapters = await db.getChapters(bookId);
    if (allChapters.isEmpty) return;

    final startIdx = currentReadingChapter.clamp(0, allChapters.length - 1);
    final endIdx = mode == TranslateMode.fullBook
        ? allChapters.length - 1
        : (startIdx + chaptersAhead - 1).clamp(startIdx, allChapters.length - 1);

    final targetChapters = allChapters.sublist(startIdx, endIdx + 1);

    _progress = TranslationProgress(
      isRunning: true,
      totalChaptersInJob: targetChapters.length,
    );
    _progressController.add(_progress);

    for (int i = 0; i < targetChapters.length; i++) {
      if (_cancelled) break;

      final chapter = targetChapters[i];
      final paragraphs = await db.getChapterParagraphs(bookId, chapter.index);
      final pendingParagraphs = paragraphs.where((p) => !p.isTranslated).toList();

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

      int doneCount = paragraphs.length - pendingParagraphs.length;

      for (int offset = 0; offset < pendingParagraphs.length; offset += batchSize) {
        if (_cancelled) break;

        // Ждём появления сети, если интернет пропал
        while (!await _hasNetwork()) {
          if (_cancelled) break;
          _progress = _progress.copyWith(
            isPausedOffline: true,
            currentChapter: chapter.index + 1,
            translatedParagraphsInChapter: doneCount,
            totalParagraphsInChapter: paragraphs.length,
          );
          _progressController.add(_progress);
          await Future.delayed(const Duration(seconds: 2));
        }

        if (_cancelled) break;

        _progress = _progress.copyWith(
          isPausedOffline: false,
          isRunning: true,
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
          );

          for (int k = 0; k < chunk.length; k++) {
            final item = chunk[k];
            if (item.id != null) {
              await db.saveParagraphTranslation(item.id!, translations[k]);
              doneCount++;
            }
          }

          _progress = _progress.copyWith(
            translatedParagraphsInChapter: doneCount,
          );
          _progressController.add(_progress);
        } catch (e) {
          await db.updateChapterStatus(
            bookId,
            chapter.index,
            ChapterStatus.partial,
          );
          _progress = _progress.copyWith(
            isRunning: false,
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

    _progress = _progress.copyWith(isRunning: false, isPausedOffline: false);
    _progressController.add(_progress);
  }

  void dispose() {
    _progressController.close();
  }
}
