import 'package:shared_preferences/shared_preferences.dart';

/// Storage seam for the SDK's durable state. Injectable so the engine stays
/// testable without Flutter platform plugins.
///
/// State lives in named slots ([queueSlot], [identitySlot], [pushSlot]), each
/// holding a single string blob. Implementations decide how slots map to
/// underlying storage keys.
abstract class WhisperrPersistence {
  /// The outbound op queue.
  static const String queueSlot = 'queue';

  /// The identified user, restored on start so a relaunched app keeps its
  /// attribution (and push-token dedupe) without re-identifying.
  static const String identitySlot = 'identity';

  /// The last-sent (user, push token) pair. Persisted so every-launch
  /// `getToken()` wiring stays a no-op across restarts and a post-restart
  /// rotation can still opt the stale token out.
  static const String pushSlot = 'push';

  Future<String?> load(String slot);
  Future<void> save(String slot, String data);
  Future<void> clear(String slot);
}

/// Default persistence backed by `shared_preferences` (works across mobile,
/// web, and desktop).
class SharedPreferencesPersistence implements WhisperrPersistence {
  // The queue slot keeps its historical key ('whisperr.queue.v1') so queues
  // persisted by older SDK versions survive an upgrade.
  static String _key(String slot) => 'whisperr.$slot.v1';

  @override
  Future<String?> load(String slot) async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_key(slot));
  }

  @override
  Future<void> save(String slot, String data) async {
    final prefs = await SharedPreferences.getInstance();
    if (!await prefs.setString(_key(slot), data)) {
      throw StateError('Whisperr persistence write failed');
    }
  }

  @override
  Future<void> clear(String slot) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_key(slot));
  }
}

/// No-op persistence used when [WhisperrOptions.enablePersistence] is false and
/// in tests.
class InMemoryPersistence implements WhisperrPersistence {
  final Map<String, String> _slots = {};

  @override
  Future<String?> load(String slot) async => _slots[slot];

  @override
  Future<void> save(String slot, String data) async => _slots[slot] = data;

  @override
  Future<void> clear(String slot) async => _slots.remove(slot);
}
