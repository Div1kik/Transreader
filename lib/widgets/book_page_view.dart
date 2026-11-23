import 'dart:math' as math;
import 'package:flutter/material.dart';
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

  // Для 3D-анимации перелистывания книги
  late final AnimationController _curlController;
  double _dragProgress = 0.0; // -1.0 (листаем назад) .. 0.0 .. +1.0 (листаем вперёд)
  bool _isDragging = false;

  @override
  void initState() {
    super.initState();
    _currentPage = widget.initialPage;
    _curlController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 360),
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

  String _buildSignature(Size size) {
    return '${size.width.toInt()}x${size.height.toInt()}_'
        '${widget.chapterTitle}_'
        '${widget.paragraphs.length}_'
        '${widget.paragraphs.where((p) => p.isTranslated).length}_'
        '${widget.appearance.fontSize}_'
        '${widget.appearance.lineHeight}_'
        '${widget.appearance.showOriginal}';
  }

  List<BookPageSlice> _paginate(BoxConstraints constraints) {
    const horizontalPadding = 20.0;
    const verticalPadding = 16.0;
    const footerHeight = 28.0;

    final availableWidth =
        (constraints.maxWidth - horizontalPadding * 2).clamp(120.0, 2000.0);
    final availableHeight =
        (constraints.maxHeight - verticalPadding * 2 - footerHeight)
            .clamp(160.0, 4000.0);

    final mainStyle = TextStyle(
      fontSize: widget.appearance.fontSize,
      height: widget.appearance.lineHeight,
    );
    final origStyle = TextStyle(
      fontSize: (widget.appearance.fontSize - 4).clamp(11.0, 24.0),
      height: 1.35,
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
      )..layout(maxWidth: availableWidth);
      return tp.height;
    }

    final result = <BookPageSlice>[];
    var currentItems = <ParagraphItem>[];
    String? pendingHeader = widget.chapterTitle;

    double usedHeight = measureTextHeight(widget.chapterTitle, headerStyle) + 18.0;

    for (final p in widget.paragraphs) {
      final textToShow = p.isTranslated ? p.translatedText! : p.sourceText;
      double itemHeight = measureTextHeight(textToShow, mainStyle) + 14.0;

      if (widget.appearance.showOriginal && p.isTranslated) {
        itemHeight += measureTextHeight(p.sourceText, origStyle) + 6.0;
      }
      if (!p.isTranslated) {
        itemHeight += 28.0; // место под компактную кнопку «Перевести»
      }

      if (usedHeight + itemHeight > availableHeight && currentItems.isNotEmpty) {
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
    });
    widget.onPageChanged?.call(_currentPage);
  }

  Future<void> _animateCurlTo(double endValue, int? nextPageIndex) async {
    _curlController.value = _dragProgress;
    await _curlController.animateTo(
      endValue,
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeOutCubic,
    );
    if (!mounted) return;
    if (nextPageIndex != null) {
      _goToPage(nextPageIndex);
    } else {
      setState(() => _dragProgress = 0.0);
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
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
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
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        if (p.isTranslated)
                          Text(
                            p.translatedText!,
                            style: TextStyle(
                              fontSize: widget.appearance.fontSize,
                              height: widget.appearance.lineHeight,
                              color: widget.palette.text,
                            ),
                          )
                        else
                          Column(
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
                                    padding: const EdgeInsets.symmetric(
                                      vertical: 2,
                                      horizontal: 6,
                                    ),
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
                          ),
                        if (widget.appearance.showOriginal && p.isTranslated) ...[
                          const SizedBox(height: 4),
                          Text(
                            p.sourceText,
                            style: TextStyle(
                              fontSize: (widget.appearance.fontSize - 4)
                                  .clamp(11.0, 24.0),
                              height: 1.35,
                              color: widget.palette.secondaryText,
                              fontStyle: FontStyle.italic,
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
              ],
            ),
          ),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Expanded(
                child: Text(
                  widget.chapterTitle,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 11,
                    color: widget.palette.secondaryText.withOpacity(0.75),
                  ),
                ),
              ),
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
        ],
      ),
    );
  }

  Widget _buildCurlStage(double width) {
    // _dragProgress > 0: листаем вперёд (текущая страница уходит влево, под ней следующая)
    // _dragProgress < 0: листаем назад (предыдущая страница накрывает текущую слева направо)
    if (_dragProgress >= 0) {
      final hasNext = _currentPage + 1 < _pages.length;
      final t = _dragProgress.clamp(0.0, 1.0);
      final angle = -t * (math.pi / 2.1);

      return Stack(
        fit: StackFit.expand,
        children: [
          if (hasNext)
            _buildSinglePageContent(_currentPage + 1)
          else
            _buildSinglePageContent(_currentPage),
          // Тень от перелистываемой страницы на нижней странице
          if (t > 0.01 && hasNext)
            IgnorePointer(
              child: Container(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.centerLeft,
                    end: Alignment.centerRight,
                    colors: [
                      Colors.black.withOpacity(0.32 * (1 - t)),
                      Colors.transparent,
                    ],
                  ),
                ),
              ),
            ),
          // Верхняя перелистываемая страница с 3D-перспективой
          Transform(
            alignment: Alignment.centerLeft,
            transform: Matrix4.identity()
              ..setEntry(3, 2, 0.0012)
              ..rotateY(angle),
            child: Stack(
              fit: StackFit.expand,
              children: [
                _buildSinglePageContent(_currentPage),
                // Блик и тень изгиба бумажного листа
                if (t > 0.01)
                  IgnorePointer(
                    child: Container(
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.centerLeft,
                          end: Alignment.centerRight,
                          stops: const [0.0, 0.82, 0.94, 1.0],
                          colors: [
                            Colors.black.withOpacity(0.18 * t),
                            Colors.transparent,
                            Colors.white.withOpacity(0.14 * t),
                            Colors.black.withOpacity(0.35 * t),
                          ],
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ],
      );
    } else {
      final hasPrev = _currentPage - 1 >= 0;
      final t = (-_dragProgress).clamp(0.0, 1.0);
      final angle = -(1.0 - t) * (math.pi / 2.1);

      return Stack(
        fit: StackFit.expand,
        children: [
          _buildSinglePageContent(_currentPage),
          if (t > 0.01 && hasPrev)
            IgnorePointer(
              child: Container(
                color: Colors.black.withOpacity(0.25 * t),
              ),
            ),
          if (hasPrev)
            Transform(
              alignment: Alignment.centerLeft,
              transform: Matrix4.identity()
                ..setEntry(3, 2, 0.0012)
                ..rotateY(angle),
              child: Stack(
                fit: StackFit.expand,
                children: [
                  _buildSinglePageContent(_currentPage - 1),
                  IgnorePointer(
                    child: Container(
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.centerLeft,
                          end: Alignment.centerRight,
                          stops: const [0.0, 0.85, 1.0],
                          colors: [
                            Colors.black.withOpacity(0.2 * (1 - t)),
                            Colors.transparent,
                            Colors.black.withOpacity(0.35 * (1 - t)),
                          ],
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
        ],
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final size = Size(constraints.maxWidth, constraints.maxHeight);
        final signature = _buildSignature(size);

        if (_lastLayoutSignature != signature || _lastSize != size) {
          _lastLayoutSignature = signature;
          _lastSize = size;
          _pages = _paginate(constraints);
          if (_currentPage >= _pages.length) {
            _currentPage = (_pages.length - 1).clamp(0, _pages.length);
          }
        }

        final isCurl = widget.appearance.pageMode == ReaderPageMode.pageCurl;

        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapUp: (details) {
            final dx = details.localPosition.dx;
            final w = size.width;
            if (dx < w * 0.28) {
              _triggerPrevPage();
            } else if (dx > w * 0.72) {
              _triggerNextPage();
            } else {
              widget.onCenterTap?.call();
            }
          },
          onHorizontalDragStart: (_) {
            _curlController.stop();
            _isDragging = true;
          },
          onHorizontalDragUpdate: (details) {
            if (!_isDragging) return;
            final delta = -(details.primaryDelta ?? 0) / size.width;
            setState(() {
              _dragProgress = (_dragProgress + delta * 1.35).clamp(-1.0, 1.0);
            });
          },
          onHorizontalDragEnd: (details) {
            if (!_isDragging) return;
            _isDragging = false;
            final velocity = details.primaryVelocity ?? 0;

            if (_dragProgress > 0.22 || velocity < -450) {
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
            } else if (_dragProgress < -0.22 || velocity > 450) {
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
        );
      },
    );
  }
}
