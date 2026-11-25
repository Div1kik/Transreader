import 'dart:math' as math;
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import '../models/book_models.dart';
import '../models/reader_theme_settings.dart';

class BookPageSlice {
  final String? chapterHeader;
  final List<ParagraphItem> items;

  const BookPageSlice({
    this.chapterHeader,
    required this.items,
  });
}

class BookPageView extends StatefulWidget {
  final String chapterTitle;
  final List<ParagraphItem> paragraphs;
  final ReaderAppearance appearance;
  final ReaderPalette palette;
  final int initialPage;
  final ValueChanged<int>? onPageChanged;
  final VoidCallback? onNextChapter;
  final VoidCallback? onPrevChapter;
  final VoidCallback? onCenterTap;
  final VoidCallback onTranslateHere;
  final ValueChanged<String> onTranslateSelection;
  final ValueChanged<String> onSaveSelectionToDictionary;
  final Future<String> Function(String word) onLookupWord;

  const BookPageView({
    super.key,
    required this.chapterTitle,
    required this.paragraphs,
    required this.appearance,
    required this.palette,
    this.initialPage = 0,
    this.onPageChanged,
    this.onNextChapter,
    this.onPrevChapter,
    this.onCenterTap,
    required this.onTranslateHere,
    required this.onTranslateSelection,
    required this.onSaveSelectionToDictionary,
    required this.onLookupWord,
  });

  @override
  State<BookPageView> createState() => _BookPageViewState();
}

class _BookPageViewState extends State<BookPageView>
    with SingleTickerProviderStateMixin {
  List<BookPageSlice> _pages = [];
  int _currentPage = 0;
  Size? _lastSize;
  String? _lastLayoutSignature;

  late final AnimationController _curlController;
  double _dragProgress = 0.0;
  bool _isDragging = false;

  DateTime? _tapDownTime;
  Offset? _tapDownPos;
  String _selectedText = '';

  // Состояние синхронной подсветки пары слов в режиме «Билингва»
  int? _highlightedParagraphOrder;
  String? _highlightedSourceWord;
  String? _highlightedTranslatedWord;
  bool _wordTapHandled = false;

  @override
  void initState() {
    super.initState();
    _currentPage = widget.initialPage;
    _curlController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 360),
      lowerBound: -1.0,
      upperBound: 1.0,
      value: 0.0,
    )..addListener(() {
        setState(() {
          _dragProgress = _curlController.value;
        });
      });
  }

  @override
  void dispose() {
    _curlController.dispose();
    super.dispose();
  }

  String _buildSignature(Size size, TextScaler textScaler) {
    return '${size.width.toInt()}x${size.height.toInt()}_'
        '${textScaler.scale(10)}_'
        '${widget.chapterTitle}_'
        '${widget.paragraphs.length}_'
        '${widget.paragraphs.where((p) => p.isTranslated).length}_'
        '${widget.appearance.fontSize}_'
        '${widget.appearance.lineHeight}_'
        '${widget.appearance.textDisplay.index}';
  }

  List<BookPageSlice> _paginate(
    BoxConstraints constraints,
    TextScaler textScaler,
  ) {
    const horizontalPadding = 20.0;
    const verticalPadding = 28.0;
    const footerHeight = 36.0;

    final availableWidth =
        (constraints.maxWidth - horizontalPadding * 2).clamp(120.0, 2000.0);
    final availableHeight =
        (constraints.maxHeight - verticalPadding - footerHeight - 24.0)
            .clamp(140.0, 4000.0);

    final mainStyle = TextStyle(
      fontSize: widget.appearance.fontSize,
      height: widget.appearance.lineHeight,
    );
    final origStyle = TextStyle(
      fontSize: (widget.appearance.fontSize - 3.5).clamp(11.0, 24.0),
      height: 1.38,
      fontStyle: FontStyle.italic,
    );
    final headerStyle = TextStyle(
      fontSize: widget.appearance.fontSize + 5,
      fontWeight: FontWeight.bold,
      height: 1.3,
    );

    double measureTextHeight(String text, TextStyle style) {
      final tp = TextPainter(
        text: TextSpan(text: text, style: style),
        textDirection: TextDirection.ltr,
        textScaler: textScaler,
      )..layout(maxWidth: availableWidth);
      return tp.height + 4.0;
    }

    final result = <BookPageSlice>[];
    var currentItems = <ParagraphItem>[];
    String? pendingHeader = widget.chapterTitle;

    double usedHeight =
        measureTextHeight(widget.chapterTitle, headerStyle) + 18.0;

    for (final p in widget.paragraphs) {
      double itemHeight = 14.0;

      if (widget.appearance.isOriginalOnly) {
        itemHeight += measureTextHeight(p.sourceText, mainStyle);
      } else if (p.isTranslated) {
        itemHeight += measureTextHeight(p.translatedText!, mainStyle);
        if (widget.appearance.showOriginal) {
          itemHeight += measureTextHeight(p.sourceText, origStyle) + 8.0;
        }
      } else {
        itemHeight += measureTextHeight(p.sourceText, mainStyle) + 30.0;
      }

      if (usedHeight + itemHeight > availableHeight &&
          currentItems.isNotEmpty) {
        result.add(
          BookPageSlice(
            chapterHeader: pendingHeader,
            items: List<ParagraphItem>.from(currentItems),
          ),
        );
        pendingHeader = null;
        currentItems = [];
        usedHeight = 0.0;
      }

      currentItems.add(p);
      usedHeight += itemHeight;
    }

    if (currentItems.isNotEmpty || result.isEmpty) {
      result.add(
        BookPageSlice(
          chapterHeader: pendingHeader,
          items: currentItems,
        ),
      );
    }

    return result;
  }

  void _goToPage(int target) {
    if (target < 0) {
      widget.onPrevChapter?.call();
      return;
    }
    if (target >= _pages.length) {
      widget.onNextChapter?.call();
      return;
    }
    setState(() {
      _currentPage = target;
      _dragProgress = 0.0;
      _curlController.value = 0.0;
      _selectedText = '';
      _highlightedParagraphOrder = null;
      _highlightedSourceWord = null;
      _highlightedTranslatedWord = null;
    });
    widget.onPageChanged?.call(_currentPage);
  }

  Future<void> _animateCurlTo(double endValue, int? nextPageIndex) async {
    _curlController.value = _dragProgress;
    await _curlController.animateTo(
      endValue,
      duration: const Duration(milliseconds: 340),
      curve: Curves.easeOutCubic,
    );
    if (!mounted) return;
    if (nextPageIndex != null) {
      _goToPage(nextPageIndex);
    } else {
      setState(() {
        _dragProgress = 0.0;
        _curlController.value = 0.0;
      });
    }
  }

  void _triggerNextPage() {
    if (_currentPage + 1 >= _pages.length) {
      widget.onNextChapter?.call();
      return;
    }
    if (widget.appearance.pageMode == ReaderPageMode.pageCurl) {
      _animateCurlTo(1.0, _currentPage + 1);
    } else {
      _goToPage(_currentPage + 1);
    }
  }

  void _triggerPrevPage() {
    if (_currentPage - 1 < 0) {
      widget.onPrevChapter?.call();
      return;
    }
    if (widget.appearance.pageMode == ReaderPageMode.pageCurl) {
      _animateCurlTo(-1.0, _currentPage - 1);
    } else {
      _goToPage(_currentPage - 1);
    }
  }

  String _normalizeWord(String raw) {
    return raw.toLowerCase().replaceAll(RegExp(r"[^\p{L}\p{N}'’-]", unicode: true), '');
  }

  /// Находит в парном тексте слово, наиболее близкое к переведённому кандидату
  String? _findBestMatchingWordInText(
    String targetParagraph,
    String candidateTranslation,
    double relativePosition,
  ) {
    final candidateWords = candidateTranslation
        .split(RegExp(r'\s+'))
        .map(_normalizeWord)
        .where((w) => w.length >= 2)
        .toList();

    final paragraphWords = RegExp(r"[\p{L}\p{N}'’-]+", unicode: true)
        .allMatches(targetParagraph)
        .map((m) => m.group(0)!)
        .toList();

    if (paragraphWords.isEmpty || candidateWords.isEmpty) return null;

    String? bestWord;
    double bestScore = -1.0;

    for (int i = 0; i < paragraphWords.length; i++) {
      final rawW = paragraphWords[i];
      final normW = _normalizeWord(rawW);
      if (normW.length < 2) continue;

      final posRatio = i / paragraphWords.length;
      final posPenalty = (posRatio - relativePosition).abs() * 0.35;

      for (final cand in candidateWords) {
        if (normW == cand) {
          final score = 10.0 - posPenalty;
          if (score > bestScore) {
            bestScore = score;
            bestWord = normW;
          }
        } else {
          // Сравнение по общей основе слова (учитывает окончания и падежи: тень/тени, shadow/shadows)
          final minLen = math.min(normW.length, cand.length);
          if (minLen >= 3) {
            int commonPrefix = 0;
            while (commonPrefix < minLen &&
                normW[commonPrefix] == cand[commonPrefix]) {
              commonPrefix++;
            }
            final ratio = commonPrefix / math.max(normW.length, cand.length);
            if (ratio >= 0.58) {
              final score = ratio * 6.0 - posPenalty;
              if (score > bestScore) {
                bestScore = score;
                bestWord = normW;
              }
            }
          }
        }
      }
    }

    return bestWord;
  }

  Future<void> _onBilingualWordTap({
    required ParagraphItem paragraph,
    required String tappedRawWord,
    required bool tappedInOriginal,
    required double relativePosition,
  }) async {
    final cleanWord = _normalizeWord(tappedRawWord);
    if (cleanWord.length < 2 || !paragraph.isTranslated) return;

    _wordTapHandled = true;

    // Если повторно нажали на уже подсвеченное слово — снимаем маркер
    if (_highlightedParagraphOrder == paragraph.orderIndex &&
        ((tappedInOriginal && _highlightedSourceWord == cleanWord) ||
            (!tappedInOriginal && _highlightedTranslatedWord == cleanWord))) {
      setState(() {
        _highlightedParagraphOrder = null;
        _highlightedSourceWord = null;
        _highlightedTranslatedWord = null;
      });
      return;
    }

    // Сначала сразу подсвечиваем нажатое слово
    setState(() {
      _highlightedParagraphOrder = paragraph.orderIndex;
      if (tappedInOriginal) {
        _highlightedSourceWord = cleanWord;
        _highlightedTranslatedWord = null;
      } else {
        _highlightedTranslatedWord = cleanWord;
        _highlightedSourceWord = null;
      }
    });

    try {
      final candidate = await widget.onLookupWord(cleanWord);
      if (!mounted) return;
      if (_highlightedParagraphOrder != paragraph.orderIndex) return;

      final counterpartText =
          tappedInOriginal ? paragraph.translatedText! : paragraph.sourceText;

      final matched = _findBestMatchingWordInText(
        counterpartText,
        candidate,
        relativePosition,
      );

      if (matched != null) {
        setState(() {
          if (tappedInOriginal) {
            _highlightedTranslatedWord = matched;
          } else {
            _highlightedSourceWord = matched;
          }
        });
      }
    } catch (_) {
      // Если сеть/переводчик недоступны — остаётся подсвеченным нажатое слово
    }
  }

  Widget _buildInteractiveBilingualText({
    required ParagraphItem paragraph,
    required String text,
    required TextStyle baseStyle,
    required bool isOriginalText,
  }) {
    final activeWord = _highlightedParagraphOrder == paragraph.orderIndex
        ? (isOriginalText
            ? _highlightedSourceWord
            : _highlightedTranslatedWord)
        : null;

    final markerColor = widget.palette.brightness == Brightness.dark
        ? const Color(0xFFD98A3C).withOpacity(0.38)
        : const Color(0xFFFFD54F).withOpacity(0.75);

    final tokens = RegExp(r"([\p{L}\p{N}'’-]+|[^\p{L}\p{N}'’-]+)", unicode: true)
        .allMatches(text)
        .map((m) => m.group(0)!)
        .toList();

    final spans = <InlineSpan>[];
    for (int i = 0; i < tokens.length; i++) {
      final token = tokens[i];
      final norm = _normalizeWord(token);
      final isWord = norm.isNotEmpty;
      final isHighlighted = isWord && activeWord != null && norm == activeWord;

      if (!isWord) {
        spans.add(TextSpan(text: token));
      } else {
        final relPos = tokens.isEmpty ? 0.5 : i / tokens.length;
        spans.add(
          TextSpan(
            text: token,
            style: isHighlighted
                ? baseStyle.copyWith(
                    backgroundColor: markerColor,
                    fontWeight: FontWeight.w600,
                  )
                : null,
            recognizer: TapGestureRecognizer()
              ..onTap = () {
                _onBilingualWordTap(
                  paragraph: paragraph,
                  tappedRawWord: token,
                  tappedInOriginal: isOriginalText,
                  relativePosition: relPos,
                );
              },
          ),
        );
      }
    }

    return Text.rich(
      TextSpan(style: baseStyle, children: spans),
    );
  }

  Widget _buildContextMenuWithSystemExtras(
    BuildContext context,
    SelectableRegionState selectableRegionState,
  ) {
    final cleanText = _selectedText.trim();
    // Ставим «Перевести» и «В словарь» самыми первыми, а все системные пункты (доп. меню ⋮) сохраняем следом
    final items = <ContextMenuButtonItem>[
      if (cleanText.isNotEmpty) ...[
        ContextMenuButtonItem(
          label: 'Перевести',
          onPressed: () {
            selectableRegionState.hideToolbar();
            widget.onTranslateSelection(cleanText);
          },
        ),
        ContextMenuButtonItem(
          label: 'В словарь',
          onPressed: () {
            selectableRegionState.hideToolbar();
            widget.onSaveSelectionToDictionary(cleanText);
          },
        ),
      ],
      ...selectableRegionState.contextMenuButtonItems,
    ];

    return AdaptiveTextSelectionToolbar.buttonItems(
      anchors: selectableRegionState.contextMenuAnchors,
      buttonItems: items,
    );
  }

  Widget _buildSinglePageContent(int pageIndex) {
    if (_pages.isEmpty) {
      return Container(
        color: widget.palette.background,
        alignment: Alignment.center,
        child: Text(
          'В главе нет текста',
          style: TextStyle(color: widget.palette.secondaryText),
        ),
      );
    }

    final safeIdx = pageIndex.clamp(0, _pages.length - 1);
    final slice = _pages[safeIdx];

    return Container(
      width: double.infinity,
      height: double.infinity,
      color: widget.palette.background,
      padding: const EdgeInsets.fromLTRB(20, 14, 20, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: SelectionArea(
              onSelectionChanged: (SelectedContent? content) {
                _selectedText = content?.plainText ?? '';
              },
              contextMenuBuilder: _buildContextMenuWithSystemExtras,
              child: SingleChildScrollView(
                physics: const ClampingScrollPhysics(),
                padding: const EdgeInsets.only(bottom: 12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (slice.chapterHeader != null)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 16),
                        child: Text(
                          slice.chapterHeader!,
                          style: TextStyle(
                            fontSize: widget.appearance.fontSize + 5,
                            fontWeight: FontWeight.bold,
                            height: 1.3,
                            color: widget.palette.text,
                          ),
                        ),
                      ),
                    for (final p in slice.items)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 12),
                        child: _buildParagraphBlock(p),
                      ),
                  ],
                ),
              ),
            ),
          ),
          Container(
            padding: const EdgeInsets.only(top: 6),
            decoration: BoxDecoration(
              color: widget.palette.background,
              border: Border(
                top: BorderSide(
                  color: widget.palette.secondaryText.withOpacity(0.12),
                ),
              ),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Expanded(
                  child: Text(
                    widget.chapterTitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 11,
                      color: widget.palette.secondaryText.withOpacity(0.8),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Text(
                  'Стр. ${safeIdx + 1} из ${_pages.length}',
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w500,
                    color: widget.palette.secondaryText,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildParagraphBlock(ParagraphItem p) {
    if (widget.appearance.isOriginalOnly) {
      return Text(
        p.sourceText,
        style: TextStyle(
          fontSize: widget.appearance.fontSize,
          height: widget.appearance.lineHeight,
          color: widget.palette.text,
        ),
      );
    }

    if (p.isTranslated) {
      final translatedStyle = TextStyle(
        fontSize: widget.appearance.fontSize,
        height: widget.appearance.lineHeight,
        color: widget.palette.text,
      );
      final originalStyle = TextStyle(
        fontSize: (widget.appearance.fontSize - 3.5).clamp(11.0, 24.0),
        height: 1.38,
        color: widget.palette.secondaryText,
        fontStyle: FontStyle.italic,
      );

      if (widget.appearance.showOriginal) {
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _buildInteractiveBilingualText(
              paragraph: p,
              text: p.translatedText!,
              baseStyle: translatedStyle,
              isOriginalText: false,
            ),
            const SizedBox(height: 5),
            _buildInteractiveBilingualText(
              paragraph: p,
              text: p.sourceText,
              baseStyle: originalStyle,
              isOriginalText: true,
            ),
          ],
        );
      }

      return Text(
        p.translatedText!,
        style: translatedStyle,
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          p.sourceText,
          style: TextStyle(
            fontSize: widget.appearance.fontSize - 1,
            height: widget.appearance.lineHeight,
            color: widget.palette.secondaryText,
          ),
        ),
        Align(
          alignment: Alignment.centerRight,
          child: InkWell(
            onTap: widget.onTranslateHere,
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 2, horizontal: 6),
              child: Text(
                'Перевести',
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: widget.palette.accent,
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildTurningSheet({
    required Widget pageWidget,
    required double progress,
    required double width,
  }) {
    final t = progress.clamp(0.0, 1.0);
    final angle = t * (math.pi * 0.58);
    final lift = math.sin(t * math.pi);
    final scale = 1.0 + 0.035 * lift;
    final slideX = -width * 0.18 * math.pow(t, 1.6);
    final isBackSide = angle > (math.pi / 2);

    final matrix = Matrix4.identity()
      ..setEntry(3, 2, 0.00065)
      ..translate(slideX, 0.0, 0.0)
      ..scale(scale, scale, 1.0)
      ..rotateY(angle);

    return Transform(
      alignment: Alignment.centerLeft,
      transform: matrix,
      child: Container(
        decoration: BoxDecoration(
          boxShadow: [
            if (t > 0.01)
              BoxShadow(
                color: Colors.black.withOpacity(0.28 * lift + 0.12 * t),
                blurRadius: 18 * lift + 6,
                offset: Offset(8 * (1 - t), 4 * lift),
              ),
          ],
        ),
        child: Stack(
          fit: StackFit.expand,
          children: [
            if (!isBackSide)
              pageWidget
            else
              Container(
                color: widget.palette.background,
                child: Opacity(
                  opacity: 0.14,
                  child: Transform(
                    alignment: Alignment.center,
                    transform: Matrix4.identity()..scale(-1.0, 1.0, 1.0),
                    child: pageWidget,
                  ),
                ),
              ),
            if (t > 0.01)
              IgnorePointer(
                child: Container(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.centerLeft,
                      end: Alignment.centerRight,
                      stops: const [0.0, 0.12, 0.78, 0.94, 1.0],
                      colors: [
                        Colors.black.withOpacity(0.22 * t),
                        Colors.white.withOpacity(0.10 * lift),
                        Colors.transparent,
                        Colors.white.withOpacity(0.16 * lift),
                        Colors.black.withOpacity(0.26 * t),
                      ],
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildCurlStage(double width) {
    if (_dragProgress >= 0) {
      final hasNext = _currentPage + 1 < _pages.length;
      final t = _dragProgress.clamp(0.0, 1.0);

      return Stack(
        fit: StackFit.expand,
        children: [
          if (hasNext)
            _buildSinglePageContent(_currentPage + 1)
          else
            _buildSinglePageContent(_currentPage),
          if (t > 0.01 && hasNext)
            IgnorePointer(
              child: Container(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.centerLeft,
                    end: Alignment.centerRight,
                    stops: [
                      0.0,
                      (1.0 - t * 0.85).clamp(0.05, 0.95),
                      1.0,
                    ],
                    colors: [
                      Colors.black.withOpacity(0.30 * (1.0 - t * 0.7)),
                      Colors.black.withOpacity(0.06 * (1.0 - t)),
                      Colors.transparent,
                    ],
                  ),
                ),
              ),
            ),
          _buildTurningSheet(
            pageWidget: _buildSinglePageContent(_currentPage),
            progress: t,
            width: width,
          ),
        ],
      );
    } else {
      final hasPrev = _currentPage - 1 >= 0;
      final t = (-_dragProgress).clamp(0.0, 1.0);

      return Stack(
        fit: StackFit.expand,
        children: [
          _buildSinglePageContent(_currentPage),
          if (t > 0.01 && hasPrev)
            IgnorePointer(
              child: Container(
                color: Colors.black.withOpacity(0.22 * (1.0 - t)),
              ),
            ),
          if (hasPrev)
            _buildTurningSheet(
              pageWidget: _buildSinglePageContent(_currentPage - 1),
              progress: 1.0 - t,
              width: width,
            ),
        ],
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final textScaler = MediaQuery.textScalerOf(context);

    return LayoutBuilder(
      builder: (context, constraints) {
        final size = Size(constraints.maxWidth, constraints.maxHeight);
        final signature = _buildSignature(size, textScaler);

        if (_lastLayoutSignature != signature || _lastSize != size) {
          _lastLayoutSignature = signature;
          _lastSize = size;
          _pages = _paginate(constraints, textScaler);
          if (_currentPage >= _pages.length) {
            _currentPage = (_pages.length - 1).clamp(0, _pages.length);
          }
        }

        final isCurl = widget.appearance.pageMode == ReaderPageMode.pageCurl;

        return Listener(
          behavior: HitTestBehavior.translucent,
          onPointerDown: (event) {
            _tapDownTime = DateTime.now();
            _tapDownPos = event.position;
            _wordTapHandled = false;
          },
          onPointerUp: (event) {
            final downTime = _tapDownTime;
            final downPos = _tapDownPos;
            _tapDownTime = null;
            _tapDownPos = null;

            if (downTime == null || downPos == null) return;
            final elapsed = DateTime.now().difference(downTime).inMilliseconds;
            final distance = (event.position - downPos).distance;
            if (elapsed > 240 || distance > 14.0) return;

            final localDx = event.localPosition.dx;
            final w = size.width;
            if (localDx < w * 0.25) {
              _triggerPrevPage();
            } else if (localDx > w * 0.75) {
              _triggerNextPage();
            } else {
              // В режиме «Билингва» даём 30 мс на срабатывание тапа по слову,
              // чтобы тап по слову подсвечивал пару, а не дёргал верхнюю панель
              Future.delayed(const Duration(milliseconds: 30), () {
                if (!mounted) return;
                if (!_wordTapHandled) {
                  widget.onCenterTap?.call();
                }
              });
            }
          },
          child: GestureDetector(
            behavior: HitTestBehavior.translucent,
            onHorizontalDragStart: (_) {
              _curlController.stop();
              _isDragging = true;
            },
            onHorizontalDragUpdate: (details) {
              if (!_isDragging) return;
              final delta = -(details.primaryDelta ?? 0) / size.width;
              setState(() {
                _dragProgress = (_dragProgress + delta * 1.25).clamp(-1.0, 1.0);
              });
            },
            onHorizontalDragEnd: (details) {
              if (!_isDragging) return;
              _isDragging = false;
              final velocity = details.primaryVelocity ?? 0;

              if (_dragProgress > 0.20 || velocity < -420) {
                if (_currentPage + 1 < _pages.length) {
                  if (isCurl) {
                    _animateCurlTo(1.0, _currentPage + 1);
                  } else {
                    _goToPage(_currentPage + 1);
                  }
                } else {
                  setState(() => _dragProgress = 0.0);
                  widget.onNextChapter?.call();
                }
              } else if (_dragProgress < -0.20 || velocity > 420) {
                if (_currentPage - 1 >= 0) {
                  if (isCurl) {
                    _animateCurlTo(-1.0, _currentPage - 1);
                  } else {
                    _goToPage(_currentPage - 1);
                  }
                } else {
                  setState(() => _dragProgress = 0.0);
                  widget.onPrevChapter?.call();
                }
              } else {
                if (isCurl) {
                  _animateCurlTo(0.0, null);
                } else {
                  setState(() => _dragProgress = 0.0);
                }
              }
            },
            child: ClipRect(
              child: isCurl
                  ? _buildCurlStage(size.width)
                  : AnimatedSwitcher(
                      duration: const Duration(milliseconds: 220),
                      transitionBuilder: (child, anim) {
                        return FadeTransition(opacity: anim, child: child);
                      },
                      child: KeyedSubtree(
                        key: ValueKey('slide_page_$_currentPage'),
                        child: _buildSinglePageContent(_currentPage),
                      ),
                    ),
            ),
          ),
        );
      },
    );
  }
}
