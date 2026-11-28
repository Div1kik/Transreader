import 'package:flutter/material.dart';
import '../db/book_database.dart';
import '../models/book_models.dart';

class DictionaryScreen extends StatefulWidget {
  const DictionaryScreen({super.key});

  @override
  State<DictionaryScreen> createState() => _DictionaryScreenState();
}

class _DictionaryScreenState extends State<DictionaryScreen> {
  final TextEditingController _searchController = TextEditingController();
  List<DictionaryEntry> _entries = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _loadEntries();
  }

  Future<void> _loadEntries() async {
    final list = await BookDatabase.instance.getDictionaryEntries(
      query: _searchController.text,
    );
    if (!mounted) return;
    setState(() {
      _entries = list;
      _loading = false;
    });
  }

  Future<void> _deleteEntry(DictionaryEntry entry) async {
    if (entry.id == null) return;
    await BookDatabase.instance.deleteDictionaryEntry(entry.id!);
    await _loadEntries();
  }

  void _openFlashcardsTrainer() {
    if (_entries.isEmpty) return;
    final deck = List<DictionaryEntry>.from(_entries)..shuffle();
    int idx = 0;
    bool flipped = false;

    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx, setModalState) {
            final card = deck[idx];
            final accent = Theme.of(ctx).colorScheme.primary;

            return Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 32),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 38,
                    height: 4,
                    decoration: BoxDecoration(
                      color: Colors.white24,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                  const SizedBox(height: 14),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Text(
                        'Тренировка слов',
                        style: TextStyle(
                          fontSize: 17,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      Text(
                        'Карточка ${idx + 1} из ${deck.length}',
                        style: const TextStyle(color: Color(0xFFA89E93)),
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  InkWell(
                    borderRadius: BorderRadius.circular(20),
                    onTap: () => setModalState(() => flipped = !flipped),
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 220),
                      width: double.infinity,
                      constraints: const BoxConstraints(minHeight: 190),
                      padding: const EdgeInsets.all(24),
                      decoration: BoxDecoration(
                        color: flipped
                            ? accent.withOpacity(0.18)
                            : const Color(0xFF191613),
                        borderRadius: BorderRadius.circular(20),
                        border: Border.all(
                          color: flipped ? accent : Colors.white12,
                          width: 1.6,
                        ),
                      ),
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Text(
                            flipped ? 'ПЕРЕВОД' : 'ОРИГИНАЛ (нажмите, чтобы открыть)',
                            style: TextStyle(
                              fontSize: 11,
                              letterSpacing: 1.0,
                              color: flipped ? accent : const Color(0xFFA89E93),
                            ),
                          ),
                          const SizedBox(height: 14),
                          Text(
                            flipped ? card.translatedText : card.sourceText,
                            textAlign: TextAlign.center,
                            style: const TextStyle(
                              fontSize: 22,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          if (card.bookTitle.isNotEmpty) ...[
                            const SizedBox(height: 14),
                            Text(
                              'Книга: ${card.bookTitle}',
                              style: const TextStyle(
                                fontSize: 11,
                                color: Color(0xFFA89E93),
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 18),
                  Row(
                    children: [
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: () {
                            setModalState(() {
                              flipped = false;
                              idx = (idx - 1 + deck.length) % deck.length;
                            });
                          },
                          icon: const Icon(Icons.arrow_back),
                          label: const Text('Назад'),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: FilledButton.icon(
                          onPressed: () {
                            setModalState(() {
                              flipped = false;
                              idx = (idx + 1) % deck.length;
                            });
                          },
                          icon: const Icon(Icons.arrow_forward),
                          label: const Text('Дальше'),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final accent = Theme.of(context).colorScheme.primary;

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 12, 12, 6),
          child: Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _searchController,
                  onChanged: (_) => _loadEntries(),
                  decoration: InputDecoration(
                    hintText: 'Поиск по словам...',
                    prefixIcon: const Icon(Icons.search),
                    suffixIcon: _searchController.text.isNotEmpty
                        ? IconButton(
                            icon: const Icon(Icons.clear),
                            onPressed: () {
                              _searchController.clear();
                              _loadEntries();
                            },
                          )
                        : null,
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                ),
              ),
              if (_entries.isNotEmpty) ...[
                const SizedBox(width: 8),
                FilledButton.tonalIcon(
                  onPressed: _openFlashcardsTrainer,
                  icon: const Icon(Icons.school_outlined, size: 19),
                  label: const Text('Карточки'),
                  style: FilledButton.styleFrom(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 15,
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
        Expanded(
          child: _loading
              ? Center(child: CircularProgressIndicator(color: accent))
              : _entries.isEmpty
                  ? Center(
                      child: Padding(
                        padding: const EdgeInsets.all(24),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              Icons.bookmarks_outlined,
                              size: 56,
                              color: accent.withOpacity(0.7),
                            ),
                            const SizedBox(height: 12),
                            const Text(
                              'Словарь пока пуст',
                              style: TextStyle(
                                fontSize: 18,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                            const SizedBox(height: 6),
                            const Text(
                              'Выделите любое слово или фразу в книге и нажмите «В словарь».',
                              textAlign: TextAlign.center,
                              style: TextStyle(color: Color(0xFFA89E93)),
                            ),
                          ],
                        ),
                      ),
                    )
                  : ListView.builder(
                      padding: const EdgeInsets.fromLTRB(12, 4, 12, 24),
                      itemCount: _entries.length,
                      itemBuilder: (context, index) {
                        final entry = _entries[index];
                        return Card(
                          margin: const EdgeInsets.only(bottom: 8),
                          child: ListTile(
                            title: Text(
                              entry.sourceText,
                              style: const TextStyle(
                                fontWeight: FontWeight.bold,
                                fontSize: 15,
                              ),
                            ),
                            subtitle: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                const SizedBox(height: 4),
                                Text(
                                  entry.translatedText,
                                  style: TextStyle(
                                    fontSize: 14,
                                    color: accent,
                                  ),
                                ),
                                if (entry.bookTitle.isNotEmpty) ...[
                                  const SizedBox(height: 4),
                                  Text(
                                    'Книга: ${entry.bookTitle}',
                                    style: const TextStyle(
                                      fontSize: 11,
                                      color: Color(0xFFA89E93),
                                    ),
                                  ),
                                ],
                              ],
                            ),
                            trailing: IconButton(
                              icon: const Icon(
                                Icons.delete_outline,
                                color: Colors.redAccent,
                              ),
                              onPressed: () => _deleteEntry(entry),
                            ),
                          ),
                        );
                      },
                    ),
        ),
      ],
    );
  }
}
