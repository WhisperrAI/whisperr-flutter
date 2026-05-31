import 'package:shared_preferences/shared_preferences.dart';

/// Storage seam for the outbound queue. Injectable so the engine stays
/// testable without Flutter platform plugins.
abstract class WhisperrPersistence {
  Future<String?> load();
  Future<void> save(String data);
  Future<void> clear();
}

/// Default persistence backed by `shared_preferences` (works across mobile,
/// web, and desktop).
class SharedPreferencesPersistence implements WhisperrPersistence {
  static const String _key = 'whisperr.queue.v1';

  @override
  Future<String?> load() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_key);
  }

  @override
  Future<void> save(String data) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_key, data);
  }

  @override
  Future<void> clear() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_key);
  }
}

/// No-op persistence used when [WhisperrOptions.enablePersistence] is false and
/// in tests.
class InMemoryPersistence implements WhisperrPersistence {
  String? _data;

  @override
  Future<String?> load() async => _data;

  @override
  Future<void> save(String data) async => _data = data;

  @override
  Future<void> clear() async => _data = null;
}
