import 'dart:convert';

/// A catalog destination. This is a discovery request, never authorization to
/// purchase, redeem, or claim an offer. Resolve it through the signed-in user's
/// backend before navigating.
class WhisperrMessageAction {
  const WhisperrMessageAction({
    required this.kind,
    required this.id,
    this.locationId,
  });

  final String kind;
  final String id;
  final String? locationId;

  static const _kinds = {'location', 'product', 'offer', 'plan', 'content'};

  static WhisperrMessageAction? tryParse(Object? value) {
    if (value is! Map ||
        value['version'] != 1 ||
        value['type'] != 'view_item') {
      return null;
    }
    final target = value['target'];
    if (target is! Map) return null;
    final kind = target['kind'];
    final id = target['id'];
    final locationId = target['location_id'];
    if (kind is! String || !_kinds.contains(kind) || !_validId(id)) return null;
    if (locationId != null && !_validId(locationId)) return null;
    return WhisperrMessageAction(
      kind: kind,
      id: id as String,
      locationId: locationId as String?,
    );
  }

  Map<String, Object> toJson() => {
        'version': 1,
        'type': 'view_item',
        'target': {
          'kind': kind,
          'id': id,
          if (locationId != null) 'location_id': locationId!,
        },
      };
}

bool _validId(Object? value, {int maxLength = 512}) =>
    value is String &&
    value.isNotEmpty &&
    value.length <= maxLength &&
    value.trim() == value &&
    !RegExp(r'[\x00-\x1f\x7f]').hasMatch(value);

/// Decodes only Whisperr's namespaced FCM data. Ordinary host notifications are
/// untouched. A recipient is mandatory so a delayed push cannot cross accounts.
class WhisperrPushMessage {
  const WhisperrPushMessage({
    required this.messageId,
    required this.userId,
    this.action,
  });

  final String messageId;
  final String userId;
  final WhisperrMessageAction? action;

  static bool isWhisperr(Map<String, dynamic> data) =>
      data.keys.any((key) => key.startsWith('whisperr_'));

  static WhisperrPushMessage? tryParse(Map<String, dynamic> data) {
    if (!_validId(data['whisperr_message_id']) ||
        !_validId(data['whisperr_user_id'])) {
      return null;
    }
    Object? rawAction;
    final encoded = data['whisperr_action'];
    if (encoded is String && encoded.length <= 16384) {
      try {
        rawAction = jsonDecode(encoded);
      } on FormatException {/* Unsupported payload. */}
    }
    return WhisperrPushMessage(
      messageId: data['whisperr_message_id'] as String,
      userId: data['whisperr_user_id'] as String,
      action: WhisperrMessageAction.tryParse(rawAction),
    );
  }
}

class WhisperrInboxMessage {
  const WhisperrInboxMessage({
    required this.id,
    required this.title,
    required this.body,
    required this.createdAt,
    this.action,
  });

  final String id;
  final String title;
  final String body;
  final DateTime createdAt;
  final WhisperrMessageAction? action;

  factory WhisperrInboxMessage.fromJson(Map<String, dynamic> json) {
    final date = DateTime.tryParse(json['created_at']?.toString() ?? '');
    if (!_validId(json['id']) ||
        json['title'] is! String ||
        json['body'] is! String ||
        date == null) {
      throw const FormatException('Invalid Whisperr inbox message');
    }
    return WhisperrInboxMessage(
      id: json['id'] as String,
      title: json['title'] as String,
      body: json['body'] as String,
      createdAt: date,
      action: WhisperrMessageAction.tryParse(json['action']),
    );
  }
}

class WhisperrInboxPage {
  const WhisperrInboxPage({required this.messages, this.nextCursor});

  final List<WhisperrInboxMessage> messages;
  final String? nextCursor;

  factory WhisperrInboxPage.fromJson(Map<String, dynamic> json) {
    final raw = json['messages'];
    final cursor = json['next_cursor'];
    if (raw is! List ||
        (cursor != null && !_validId(cursor, maxLength: 4096))) {
      throw const FormatException('Invalid Whisperr inbox page');
    }
    return WhisperrInboxPage(
      messages: List.unmodifiable(raw.map((item) {
        if (item is! Map) throw const FormatException('Invalid inbox entry');
        return WhisperrInboxMessage.fromJson(Map<String, dynamic>.from(item));
      })),
      nextCursor: cursor as String?,
    );
  }
}

/// Coordinates push taps with the host's login and startup routing. The host
/// supplies an authenticated resolver; the untrusted push action is never used
/// directly. An in-flight result is discarded if the account changes.
class WhisperrActionCoordinator {
  WhisperrActionCoordinator(
      {required this.resolve, required this.open, required this.unavailable});

  final Future<WhisperrMessageAction?> Function(String messageId) resolve;
  final Future<void> Function(WhisperrMessageAction action, String messageId)
      open;
  final Future<void> Function() unavailable;
  String? _userId;
  bool _ready = false;
  int _generation = 0;
  int _request = 0;
  WhisperrPushMessage? _pending;
  final Set<String> _opened = {};

  Future<void> updateSession(
      {required String? userId, required bool ready}) async {
    if (_userId != userId) {
      _generation++;
      _opened.clear();
      // Preserve a signed-out cold-start tap only for its intended next user.
      if (_pending != null && userId != null && _pending!.userId != userId) {
        _pending = null;
      }
      if (_userId != null && userId == null) _pending = null;
      _userId = userId;
    }
    if (_ready && !ready) _request++;
    _ready = ready;
    await _drain();
  }

  /// Explicit inbox taps may reopen a message; duplicate push deliveries cannot.
  Future<void> receive(WhisperrPushMessage message,
      {bool deduplicate = true}) async {
    if (_userId != null && message.userId != _userId) return;
    if (deduplicate && _opened.contains(message.messageId)) return;
    _request++;
    _pending = message; // bounded: the latest explicit tap wins
    await _drain();
  }

  /// Call when the user dismisses the pending destination or cancels login.
  void cancelPending() {
    _request++;
    _pending = null;
  }

  Future<void> _drain() async {
    final message = _pending;
    if (!_ready || _userId == null || message == null) return;
    if (message.userId != _userId) {
      _pending = null;
      return;
    }
    _pending = null;
    final generation = _generation;
    final request = _request;
    _opened.add(message.messageId);
    if (_opened.length > 100) _opened.remove(_opened.first);
    try {
      final action = await resolve(message.messageId);
      if (generation != _generation ||
          request != _request ||
          message.userId != _userId ||
          !_ready) {
        return;
      }
      if (action == null) {
        await unavailable();
      } else {
        await open(action, message.messageId);
      }
    } catch (_) {
      if (generation == _generation && request == _request) {
        _opened.remove(message.messageId); // a later user tap may retry
      }
      if (generation == _generation &&
          request == _request &&
          message.userId == _userId &&
          _ready) {
        await unavailable();
      }
    }
  }
}
