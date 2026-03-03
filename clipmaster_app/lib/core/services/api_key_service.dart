import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:logger/logger.dart';

final _log = Logger(printer: PrettyPrinter(methodCount: 0));

/// Supported API key providers.
enum LlmProvider { gemini, claude, openai, github }

/// Metadata for a single API key.
class ApiKeyEntry {
  final String key;
  final LlmProvider provider;
  final DateTime addedAt;
  int usageCount;
  DateTime? lastUsed;
  bool isHealthy;

  ApiKeyEntry({
    required this.key,
    required this.provider,
    DateTime? addedAt,
    this.usageCount = 0,
    this.lastUsed,
    this.isHealthy = true,
  }) : addedAt = addedAt ?? DateTime.now();

  /// Mask the key for display: "sk-abc...xyz".
  String get masked {
    if (key.length <= 8) return '***';
    return '${key.substring(0, 4)}...${key.substring(key.length - 4)}';
  }

  Map<String, dynamic> toJson() => {
        'key': key,
        'provider': provider.name,
        'addedAt': addedAt.toIso8601String(),
        'usageCount': usageCount,
        'lastUsed': lastUsed?.toIso8601String(),
        'isHealthy': isHealthy,
      };

  factory ApiKeyEntry.fromJson(Map<String, dynamic> j) => ApiKeyEntry(
        key: j['key'] as String,
        provider: LlmProvider.values.byName(j['provider'] as String),
        addedAt: DateTime.parse(j['addedAt'] as String),
        usageCount: j['usageCount'] as int? ?? 0,
        lastUsed: j['lastUsed'] != null
            ? DateTime.parse(j['lastUsed'] as String)
            : null,
        isHealthy: j['isHealthy'] as bool? ?? true,
      );
}

/// Manages BYOK (Bring Your Own Key) API keys with:
///   - Secure storage via Windows Credential Manager (flutter_secure_storage).
///   - Round-robin load balancing across multiple keys per provider.
///   - Health tracking: keys that return 429/401 are marked unhealthy and skipped.
class ApiKeyService {
  static const String _storageKey = 'clipmaster_api_keys';

  final FlutterSecureStorage _storage;
  final Map<LlmProvider, List<ApiKeyEntry>> _keys = {};
  final Map<LlmProvider, int> _roundRobinIndex = {};

  ApiKeyService({FlutterSecureStorage? storage})
      : _storage = storage ?? const FlutterSecureStorage();

  /// Load all keys from secure storage into memory.
  Future<void> init() async {
    final raw = await _storage.read(key: _storageKey);
    if (raw == null) return;

    try {
      final List<dynamic> list = jsonDecode(raw) as List<dynamic>;
      for (final item in list) {
        final entry = ApiKeyEntry.fromJson(item as Map<String, dynamic>);
        _keys.putIfAbsent(entry.provider, () => []).add(entry);
      }
      _log.i('Loaded ${list.length} API keys from secure storage.');
    } catch (e) {
      _log.e('Failed to parse stored API keys: $e');
    }
  }

  /// Persist the current key set back to secure storage.
  Future<void> _persist() async {
    final allEntries = _keys.values.expand((list) => list).toList();
    final raw = jsonEncode(allEntries.map((e) => e.toJson()).toList());
    await _storage.write(key: _storageKey, value: raw);
  }

  /// Add a new API key for a provider.
  Future<void> addKey(LlmProvider provider, String key) async {
    final entry = ApiKeyEntry(key: key, provider: provider);
    _keys.putIfAbsent(provider, () => []).add(entry);
    await _persist();
    _log.i('Added ${provider.name} key: ${entry.masked}');
  }

  /// Remove a key by its masked value (for UI safety).
  Future<void> removeKey(LlmProvider provider, String maskedKey) async {
    _keys[provider]?.removeWhere((e) => e.masked == maskedKey);
    await _persist();
  }

  /// Get all keys for a provider (for the settings UI).
  List<ApiKeyEntry> getKeysForProvider(LlmProvider provider) =>
      List.unmodifiable(_keys[provider] ?? []);

  /// **Round-Robin Key Selection** with health awareness.
  ///
  /// Cycles through keys for the given provider. Skips keys marked unhealthy.
  /// Returns `null` if no healthy keys are available.
  String? getNextKey(LlmProvider provider) {
    final keys = _keys[provider];
    if (keys == null || keys.isEmpty) return null;

    final healthyKeys = keys.where((k) => k.isHealthy).toList();
    if (healthyKeys.isEmpty) {
      _log.w('All ${provider.name} keys are unhealthy. Resetting health.');
      // Reset health so the user can retry (could be a transient rate-limit).
      for (final k in keys) {
        k.isHealthy = true;
      }
      return getNextKey(provider);
    }

    final idx = _roundRobinIndex[provider] ?? 0;
    final selected = healthyKeys[idx % healthyKeys.length];
    _roundRobinIndex[provider] = (idx + 1) % healthyKeys.length;

    selected.usageCount++;
    selected.lastUsed = DateTime.now();
    _persist(); // fire-and-forget, non-critical

    _log.d('Round-robin selected ${provider.name} key: ${selected.masked}');
    return selected.key;
  }

  /// Mark a key as unhealthy (e.g., after receiving a 429 or 401 response).
  Future<void> markUnhealthy(LlmProvider provider, String key) async {
    final entry = _keys[provider]?.where((k) => k.key == key).firstOrNull;
    if (entry != null) {
      entry.isHealthy = false;
      _log.w('Marked ${provider.name} key ${entry.masked} as unhealthy.');
      await _persist();
    }
  }

  /// Mark a key as healthy again.
  Future<void> markHealthy(LlmProvider provider, String key) async {
    final entry = _keys[provider]?.where((k) => k.key == key).firstOrNull;
    if (entry != null) {
      entry.isHealthy = true;
      await _persist();
    }
  }
}

/// Riverpod provider for the API Key Service.
final apiKeyServiceProvider = Provider<ApiKeyService>((ref) {
  return ApiKeyService();
});
