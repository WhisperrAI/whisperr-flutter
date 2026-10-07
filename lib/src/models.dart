/// A contact channel for a user, used by [Whisperr.identify].
///
/// Maps to the backend `channels[]` entries on `POST /v1/identify`.
enum WhisperrChannelType {
  email,
  sms,
  push;

  String get wireValue => name;
}

/// The type of a push token. It tells the server which provider can send to
/// the token (SPEC.md → Token kind).
enum WhisperrPushTokenKind {
  /// A Firebase Cloud Messaging registration token.
  fcm('fcm'),

  /// A raw APNs device token (hex).
  apns('apns'),

  /// An Expo push token (`ExponentPushToken[…]`).
  expo('expo'),

  /// A OneSignal subscription id.
  oneSignalSubscription('onesignal_sub');

  const WhisperrPushTokenKind(this.wireValue);

  /// The value sent as `kind`.
  final String wireValue;
}

/// The APNs environment of an `apns` token. Development-signed builds get
/// `sandbox` tokens; TestFlight and App Store builds get `production` tokens.
enum WhisperrPushEnvironment {
  production,
  sandbox;

  /// The value sent as `push_env`.
  String get wireValue => name;
}

/// The notification permission the OS reports for this app.
enum WhisperrPushPermission {
  /// Notifications show. Sent as `authorized`.
  granted('authorized'),

  /// iOS quiet delivery: notifications go to Notification Center only.
  provisional('provisional'),

  /// The user turned notifications off.
  denied('denied'),

  /// The app has not asked yet. Sent as `not_determined`.
  undetermined('not_determined');

  const WhisperrPushPermission(this.wireValue);

  /// The `status` value of the `push_permission_changed` event.
  final String wireValue;

  /// Whether the OS shows (or quietly delivers) notifications.
  bool get allowsPush => this == granted || this == provisional;

  /// Parses a [wireValue]; null for anything else.
  static WhisperrPushPermission? fromWire(Object? value) {
    for (final p in values) {
      if (p.wireValue == value) return p;
    }
    return null;
  }
}

/// The notification permission state this device keeps, persisted next to
/// the queue.
class WhisperrPermissionRecord {
  const WhisperrPermissionRecord({this.current, this.sent});

  /// Reads a stored record. A 0.5.x record (`{status, sent_for}`) carried the
  /// trait and never sent the event: its status stays the device's current
  /// permission, and nothing counts as sent.
  factory WhisperrPermissionRecord.fromJson(Map<dynamic, dynamic> json) {
    if (!json.containsKey('current') && !json.containsKey('sent')) {
      return WhisperrPermissionRecord(
          current: WhisperrPushPermission.values.asNameMap()[json['status']]);
    }
    return WhisperrPermissionRecord(
      current: WhisperrPushPermission.fromWire(json['current']),
      sent: WhisperrPushPermission.fromWire(json['sent']),
    );
  }

  /// The status the app last reported. While it is denied, this device's
  /// push token is held back.
  final WhisperrPushPermission? current;

  /// The status last sent as `push_permission_changed` from this device.
  /// Null when none was sent since install or the last reset().
  final WhisperrPushPermission? sent;

  bool get isEmpty => current == null && sent == null;

  Map<String, dynamic> toJson() => {
        if (current != null) 'current': current!.wireValue,
        if (sent != null) 'sent': sent!.wireValue,
      };
}

/// A tap on a Whisperr push: the message id and the deep link, if any.
class WhisperrPushOpen {
  const WhisperrPushOpen({required this.messageId, this.deepLink});

  /// Reads `whisperr_message_id` and the deep link (`whisperr_deep_link`, or
  /// `deep_link`) from a push data payload. Null for a push that did not come
  /// from Whisperr.
  static WhisperrPushOpen? fromData(Map<String, dynamic> data) {
    final id = _text(data['whisperr_message_id']);
    if (id == null) return null;
    return WhisperrPushOpen(
      messageId: id,
      deepLink: _text(data['whisperr_deep_link']) ?? _text(data['deep_link']),
    );
  }

  /// The `whisperr_message_id` from the push data.
  final String messageId;

  /// The deep link from the push data, or null.
  final String? deepLink;

  static String? _text(Object? value) {
    if (value is! String && value is! num) return null;
    final text = value.toString().trim();
    return text.isEmpty ? null : text;
  }

  @override
  bool operator ==(Object other) =>
      other is WhisperrPushOpen &&
      other.messageId == messageId &&
      other.deepLink == deepLink;

  @override
  int get hashCode => Object.hash(messageId, deepLink);

  @override
  String toString() =>
      'WhisperrPushOpen(messageId: $messageId, deepLink: $deepLink)';
}

/// A reachable contact address for a user on a given channel.
class WhisperrChannel {
  const WhisperrChannel({
    required this.type,
    required this.address,
    this.verified,
    this.optedIn,
    this.kind,
    this.platform,
    this.pushEnv,
  });

  /// Convenience constructor for an email channel.
  factory WhisperrChannel.email(String address,
          {bool? verified, bool? optedIn}) =>
      WhisperrChannel(
          type: WhisperrChannelType.email,
          address: address,
          verified: verified,
          optedIn: optedIn);

  /// Convenience constructor for an SMS channel.
  factory WhisperrChannel.sms(String address,
          {bool? verified, bool? optedIn}) =>
      WhisperrChannel(
          type: WhisperrChannelType.sms,
          address: address,
          verified: verified,
          optedIn: optedIn);

  /// Convenience constructor for a push token channel. [kind], [platform]
  /// and [pushEnv] are optional token metadata; send only what you know.
  factory WhisperrChannel.push(String address,
          {bool? verified,
          bool? optedIn,
          WhisperrPushTokenKind? kind,
          String? platform,
          WhisperrPushEnvironment? pushEnv}) =>
      WhisperrChannel(
          type: WhisperrChannelType.push,
          address: address,
          verified: verified,
          optedIn: optedIn,
          kind: kind,
          platform: platform,
          pushEnv: pushEnv);

  final WhisperrChannelType type;
  final String address;
  final bool? verified;
  final bool? optedIn;

  /// Push only: the token type, sent as `kind`.
  final WhisperrPushTokenKind? kind;

  /// Push only: the OS family (`ios`, `android`, …), sent as `platform`.
  final String? platform;

  /// Push only: the APNs environment, sent as `push_env`.
  final WhisperrPushEnvironment? pushEnv;

  Map<String, dynamic> toJson() {
    // Token metadata goes only on an opted-in push entry; an opt-out is
    // matched by address alone.
    final meta = type == WhisperrChannelType.push && optedIn != false;
    final os = platform?.trim();
    return {
      'channel': type.wireValue,
      'address': address,
      if (verified != null) 'verified': verified,
      if (optedIn != null) 'opted_in': optedIn,
      if (meta && kind != null) 'kind': kind!.wireValue,
      if (meta && os != null && os.isNotEmpty) 'platform': os,
      if (meta && pushEnv != null) 'push_env': pushEnv!.wireValue,
    };
  }
}

/// Delivery problem surfaced by the SDK after it classifies a backend/network
/// response. Use this for logging or diagnostics; the queue behavior is handled
/// by the client.
class WhisperrError {
  const WhisperrError({
    required this.type,
    required this.message,
    this.status,
  });

  final String type;
  final String message;
  final int? status;
}

/// The kind of queued operation.
enum WhisperrOpKind { identify, track }

/// An internal, persistable unit of work in the outbound queue.
///
/// [body] is the exact JSON payload sent to the backend — it must contain only
/// fields the API accepts, because the runtime rejects unknown fields.
class WhisperrQueueOp {
  WhisperrQueueOp({
    required this.id,
    required this.kind,
    required this.body,
    this.optOut = false,
  });

  factory WhisperrQueueOp.fromJson(Map<String, dynamic> json) =>
      WhisperrQueueOp(
        id: json['id'] as String,
        kind: WhisperrOpKind.values.byName(json['kind'] as String),
        body: Map<String, dynamic>.from(json['body'] as Map),
        optOut: json['opt_out'] == true,
      );

  final String id;
  final WhisperrOpKind kind;
  final Map<String, dynamic> body;

  /// A push opt-out kept or queued by `optOut()`. The only kind of op
  /// delivered while the device is opted out.
  final bool optOut;

  Map<String, dynamic> toJson() => {
        'id': id,
        'kind': kind.name,
        'body': body,
        if (optOut) 'opt_out': true,
      };
}
