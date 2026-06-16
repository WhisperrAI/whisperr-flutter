/// A contact channel for a user, used by [Whisperr.identify].
///
/// Maps to the backend `channels[]` entries on `POST /v1/identify`.
enum WhisperrChannelType {
  email,
  sms,
  push;

  String get wireValue => name;
}

/// A reachable contact address for a user on a given channel.
class WhisperrChannel {
  const WhisperrChannel({
    required this.type,
    required this.address,
    this.verified,
    this.optedIn,
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

  /// Convenience constructor for a push token channel.
  factory WhisperrChannel.push(String address,
          {bool? verified, bool? optedIn}) =>
      WhisperrChannel(
          type: WhisperrChannelType.push,
          address: address,
          verified: verified,
          optedIn: optedIn);

  final WhisperrChannelType type;
  final String address;
  final bool? verified;
  final bool? optedIn;

  Map<String, dynamic> toJson() => {
        'channel': type.wireValue,
        'address': address,
        if (verified != null) 'verified': verified,
        if (optedIn != null) 'opted_in': optedIn,
      };
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
  });

  factory WhisperrQueueOp.fromJson(Map<String, dynamic> json) =>
      WhisperrQueueOp(
        id: json['id'] as String,
        kind: WhisperrOpKind.values.byName(json['kind'] as String),
        body: Map<String, dynamic>.from(json['body'] as Map),
      );

  final String id;
  final WhisperrOpKind kind;
  final Map<String, dynamic> body;

  Map<String, dynamic> toJson() => {
        'id': id,
        'kind': kind.name,
        'body': body,
      };
}
