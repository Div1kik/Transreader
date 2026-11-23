import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import '../models/book_models.dart';
import '../services/settings_service.dart';

class _ProviderPreset {
  final String label;
  final String endpoint;
  final String defaultModel;

  const _ProviderPreset({
    required this.label,
    required this.endpoint,
    required this.defaultModel,
  });
}

class SettingsScreen extends StatefulWidget {
  final TranslatorSettings initialSettings;

  const SettingsScreen({super.key, required this.initialSettings});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  static const List<_ProviderPreset> _presets = [
    _ProviderPreset(
      label: 'Gemini (Free)',
      endpoint:
          'https://generativelanguage.googleapis.com/v1beta/openai/chat/completions',
      defaultModel: 'gemini-2.5-flash',
    ),
    _ProviderPreset(
      label: 'Groq (Free)',
      endpoint: 'https://api.groq.com/openai/v1/chat/completions',
      defaultModel: 'llama-3.3-70b-versatile',
    ),
    _ProviderPreset(
      label: 'OpenRouter',
      endpoint: 'https://openrouter.ai/api/v1/chat/completions',
      defaultModel: 'google/gemma-2-9b-it:free',
    ),
    _ProviderPreset(
      label: 'OpenAI',
      endpoint: 'https://api.openai.com/v1/chat/completions',
      defaultModel: 'gpt-4o-mini',
    ),
    _ProviderPreset(
      label: 'DeepSeek',
      endpoint: 'https://api.deepseek.com/chat/completions',
      defaultModel: 'deepseek-chat',
    ),
  ];

  late final TextEditingController _endpointCtrl;
  late final TextEditingController _apiKeyCtrl;
  late final TextEditingController _modelCtrl;
  late final TextEditingController _langCtrl;

  bool _obscureKey = true;
  bool _loadingModels = false;
  List<String> _availableModels = [];
  String? _modelsError;

  @override
  void initState() {
    super.initState();
    _endpointCtrl =
        TextEditingController(text: widget.initialSettings.endpointUrl);
    _apiKeyCtrl = TextEditingController(text: widget.initialSettings.apiKey);
    _modelCtrl = TextEditingController(text: widget.initialSettings.model);
    _langCtrl =
        TextEditingController(text: widget.initialSettings.targetLanguage);

    if (widget.initialSettings.model.trim().isNotEmpty) {
      _availableModels = [widget.initialSettings.model.trim()];
    }
  }

  @override
  void dispose() {
    _endpointCtrl.dispose();
    _apiKeyCtrl.dispose();
    _modelCtrl.dispose();
    _langCtrl.dispose();
    super.dispose();
  }

  void _applyPreset(_ProviderPreset preset) {
    setState(() {
      _endpointCtrl.text = preset.endpoint;
      _modelCtrl.text = preset.defaultModel;
      _availableModels = [preset.defaultModel];
      _modelsError = null;
    });
  }

  Uri _buildModelsUri(String rawEndpoint, String apiKey) {
    var clean = rawEndpoint.trim();
    if (clean.endsWith('/')) {
      clean = clean.substring(0, clean.length - 1);
    }
    if (clean.endsWith('/chat/completions')) {
      clean = clean.substring(0, clean.length - '/chat/completions'.length);
    } else if (clean.endsWith('/completions')) {
      clean = clean.substring(0, clean.length - '/completions'.length);
    }

    final baseUri = Uri.parse('$clean/models');
    if (baseUri.host.contains('googleapis.com') && apiKey.isNotEmpty) {
      return baseUri.replace(
        queryParameters: {...baseUri.queryParameters, 'key': apiKey},
      );
    }
    return baseUri;
  }

  Future<void> _fetchModels() async {
    final endpoint = _endpointCtrl.text.trim();
    final apiKey = _apiKeyCtrl.text.trim();

    if (endpoint.isEmpty) {
      setState(() => _modelsError = 'Сначала выбери сервис или укажи URL');
      return;
    }

    setState(() {
      _loadingModels = true;
      _modelsError = null;
    });

    try {
      final modelsUri = _buildModelsUri(endpoint, apiKey);
      final response = await http.get(
        modelsUri,
        headers: {
          if (apiKey.isNotEmpty) 'Authorization': 'Bearer $apiKey',
        },
      );

      if (response.statusCode < 200 || response.statusCode >= 300) {
        final bodyPreview = utf8.decode(response.bodyBytes);
        throw Exception('HTTP ${response.statusCode}: $bodyPreview');
      }

      final decoded =
          jsonDecode(utf8.decode(response.bodyBytes)) as Map<String, dynamic>;
      final data = (decoded['data'] ?? decoded['models']) as List<dynamic>? ?? [];
      final ids = data
          .map((item) {
            final map = item as Map<String, dynamic>;
            return (map['id'] ?? map['name'] ?? '').toString();
          })
          .where((id) => id.isNotEmpty)
          .map((id) => id.startsWith('models/') ? id.substring(7) : id)
          .toSet()
          .toList()
        ..sort();

      final currentModel = _modelCtrl.text.trim();
      if (currentModel.isNotEmpty && !ids.contains(currentModel)) {
        ids.insert(0, currentModel);
      }

      if (!mounted) return;
      setState(() {
        _availableModels = ids;
        if (ids.isEmpty) {
          _modelsError = 'Список моделей пуст — введи имя модели вручную';
        }
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _modelsError = 'Ошибка загрузки ($e)';
      });
    } finally {
      if (mounted) {
        setState(() => _loadingModels = false);
      }
    }
  }

  Future<void> _save() async {
    final updated = TranslatorSettings(
      endpointUrl: _endpointCtrl.text.trim().isEmpty
          ? 'https://generativelanguage.googleapis.com/v1beta/openai/chat/completions'
          : _endpointCtrl.text.trim(),
      apiKey: _apiKeyCtrl.text.trim(),
      model: _modelCtrl.text.trim().isEmpty
          ? 'gemini-2.5-flash'
          : _modelCtrl.text.trim(),
      targetLanguage: _langCtrl.text.trim().isEmpty
          ? 'русский'
          : _langCtrl.text.trim(),
    );
    await SettingsService().saveSettings(updated);
    if (!mounted) return;
    Navigator.of(context).pop(updated);
  }

  @override
  Widget build(BuildContext context) {
    final selectedModel = _modelCtrl.text.trim();

    return Scaffold(
      appBar: AppBar(title: const Text('Настройки переводчика')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const Text(
            'Быстрый выбор сервиса:',
            style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 6,
            children: _presets.map((preset) {
              final active = _endpointCtrl.text.trim() == preset.endpoint;
              return ChoiceChip(
                label: Text(preset.label),
                selected: active,
                onSelected: (_) => _applyPreset(preset),
              );
            }).toList(),
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _endpointCtrl,
            onChanged: (_) => setState(() {}),
            decoration: const InputDecoration(
              labelText: 'Endpoint URL',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _apiKeyCtrl,
            obscureText: _obscureKey,
            decoration: InputDecoration(
              labelText: 'API Key',
              border: const OutlineInputBorder(),
              suffixIcon: IconButton(
                icon: Icon(
                  _obscureKey ? Icons.visibility : Icons.visibility_off,
                ),
                onPressed: () => setState(() => _obscureKey = !_obscureKey),
              ),
            ),
          ),
          const SizedBox(height: 12),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: TextField(
                  controller: _modelCtrl,
                  onChanged: (_) => setState(() {}),
                  decoration: const InputDecoration(
                    labelText: 'Модель',
                    border: OutlineInputBorder(),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              SizedBox(
                height: 56,
                child: OutlinedButton.icon(
                  onPressed: _loadingModels ? null : _fetchModels,
                  icon: _loadingModels
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.download),
                  label: const Text('Список'),
                ),
              ),
            ],
          ),
          if (_modelsError != null) ...[
            const SizedBox(height: 6),
            Text(
              _modelsError!,
              style: const TextStyle(fontSize: 12, color: Colors.amber),
            ),
          ],
          if (_availableModels.isNotEmpty) ...[
            const SizedBox(height: 10),
            const Text(
              'Доступные модели:',
              style: TextStyle(fontSize: 12, color: Colors.grey),
            ),
            const SizedBox(height: 6),
            Wrap(
              spacing: 8,
              runSpacing: 6,
              children: _availableModels.map((modelName) {
                final isSelected = selectedModel == modelName;
                return ChoiceChip(
                  label: Text(modelName),
                  selected: isSelected,
                  onSelected: (_) {
                    setState(() {
                      _modelCtrl.text = modelName;
                    });
                  },
                );
              }).toList(),
            ),
          ],
          const SizedBox(height: 12),
          TextField(
            controller: _langCtrl,
            decoration: const InputDecoration(
              labelText: 'Язык перевода',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 20),
          FilledButton.icon(
            onPressed: _save,
            icon: const Icon(Icons.save),
            label: const Text('Сохранить'),
          ),
        ],
      ),
    );
  }
}
