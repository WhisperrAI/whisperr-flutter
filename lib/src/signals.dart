// Engagement signals v3 (whisperr-spec SPEC.md -> Engagement signals):
// pure helpers for sessions, launch attribution and error fingerprints.

import 'dart:convert';
import 'dart:math';

/// A session ends after this long without an event (the next event starts a
/// new one).
const Duration kWhisperrSessionIdle = Duration(minutes: 30);

/// At most this many `app_error` events per session.
const int kWhisperrMaxErrorsPerSession = 20;

/// The `error_kind` values of `app_error`.
const Set<String> kWhisperrErrorKinds = {
  'js',
  'dart',
  'native',
  'handled',
  'network',
  'screen',
};

/// `sess_` plus a random UUID v4.
String newSessionId(Random random) {
  final bytes = List<int>.generate(16, (_) => random.nextInt(256));
  bytes[6] = (bytes[6] & 0x0f) | 0x40;
  bytes[8] = (bytes[8] & 0x3f) | 0x80;
  final hex = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  return 'sess_${hex.substring(0, 8)}-${hex.substring(8, 12)}-'
      '${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20)}';
}

/// A launch signal: the `launch_source` and the properties that come with it
/// (only the winning signal supplies them).
class LaunchSignal {
  const LaunchSignal(this.source, [this.properties = const {}]);

  final String source;
  final Map<String, Object> properties;

  static const _rank = {
    'push': 7,
    'shortcut': 6,
    'widget': 5,
    'email': 4,
    'universal_link': 3,
    'deep_link': 2,
    'direct': 1,
  };

  /// The stronger of [a] and [b] (precedence: push > shortcut > widget >
  /// email > universal_link > deep_link > direct). [a] wins a tie.
  static LaunchSignal? stronger(LaunchSignal? a, LaunchSignal? b) {
    if (a == null) return b;
    if (b == null) return a;
    return (_rank[b.source] ?? 0) > (_rank[a.source] ?? 0) ? b : a;
  }
}

String _cap(String value, int max) =>
    value.length <= max ? value : value.substring(0, max);

final _digits = RegExp(r'^\d+$');
final _uuid = RegExp(
    r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$');

/// The path of a link with ids redacted: query and fragment dropped, and each
/// segment that is all digits, a UUID, or 16+ characters becomes `:id`.
String redactRoute(String path) {
  final segments = path.split('/').map((s) {
    if (s.isEmpty) return s;
    if (_digits.hasMatch(s) || _uuid.hasMatch(s) || s.length >= 16) {
      return ':id';
    }
    return s;
  }).toList();
  var route = segments.join('/');
  if (!route.startsWith('/')) route = '/$route';
  return _cap(route, 256);
}

/// The launch signal of a deep link, universal/app link, or a widget or
/// shortcut link (`wsrc`), or null for a URI without a scheme.
LaunchSignal? linkSignal(Uri uri) {
  final scheme = uri.scheme.toLowerCase();
  if (scheme.isEmpty) return null;
  final web = scheme == 'http' || scheme == 'https';
  final String rawPath;
  if (web) {
    rawPath = uri.path;
  } else {
    // A custom scheme: everything between `scheme://` and the query.
    final s = uri.toString();
    var rest = s.substring(s.indexOf(':') + 1);
    if (rest.startsWith('//')) rest = rest.substring(2);
    final cut = rest.indexOf(RegExp(r'[?#]'));
    rawPath = cut == -1 ? rest : rest.substring(0, cut);
  }
  final query = uri.queryParameters;
  final props = <String, Object>{'link_route': redactRoute(rawPath)};
  if (web && uri.host.isNotEmpty) props['link_host'] = uri.host;
  for (final key in const ['utm_source', 'utm_medium', 'utm_campaign']) {
    final v = query[key];
    if (v != null && v.isNotEmpty) props[key] = _cap(v, 128);
  }
  final wsrc = query['wsrc'];
  final wmid = query['wmid'];
  final String source;
  if (wsrc == 'shortcut' || wsrc == 'widget') {
    source = wsrc!;
  } else if (wmid != null && wmid.isNotEmpty) {
    source = 'email';
    props['whisperr_message_id'] = _cap(wmid, 128);
  } else {
    source = web ? 'universal_link' : 'deep_link';
  }
  return LaunchSignal(source, props);
}

/// The type name of [error] for `error_name` (never its message), at most
/// 64 characters.
String errorTypeName(Object error) {
  var name = error.runtimeType.toString();
  final generic = name.indexOf('<');
  if (generic > 0) name = name.substring(0, generic);
  return _cap(name.isEmpty ? 'Error' : name, 64);
}

final _vmFrame = RegExp(r'^#\d+\s+(.+?)\s+\(');
final _jsFrame = RegExp(r'^\s*at\s+(\S+)\s');
final _webFrame = RegExp(r'^\S+\s+\d+:\d+\s+(\S.*)$');

/// The function names of the top frames of [stack] (paths and line/column
/// numbers stripped).
List<String> stackFrameNames(StackTrace? stack, {int limit = 3}) {
  if (stack == null) return const [];
  final out = <String>[];
  for (final raw in const LineSplitter().convert(stack.toString())) {
    final line = raw.trimRight();
    if (line.isEmpty || line.contains('<asynchronous suspension>')) continue;
    final match = _vmFrame.firstMatch(line) ??
        _jsFrame.firstMatch(line) ??
        _webFrame.firstMatch(line);
    final name = match?.group(1)?.trim();
    if (name == null || name.isEmpty) continue;
    out.add(name);
    if (out.length >= limit) break;
  }
  return out;
}

/// The `app_error` fingerprint: the first 16 hex characters of SHA-256 over
/// [errorName] and the top 3 frame names, joined by `\n`.
String errorFingerprint(String errorName, List<String> frames) {
  final input = [errorName, ...frames.take(3)].join('\n');
  return sha256Hex(utf8.encode(input)).substring(0, 16);
}

const List<int> _k = [
  0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, //
  0x923f82a4, 0xab1c5ed5, 0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3,
  0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174, 0xe49b69c1, 0xefbe4786,
  0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
  0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147,
  0x06ca6351, 0x14292967, 0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13,
  0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85, 0xa2bfe8a1, 0xa81a664b,
  0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
  0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a,
  0x5b9cca4f, 0x682e6ff3, 0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208,
  0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
];

const int _mask = 0xffffffff;

int _rotr(int x, int n) => ((x >> n) | (x << (32 - n))) & _mask;

/// SHA-256 of [message] as lowercase hex. A small pure-Dart implementation,
/// so the SDK needs no `crypto` dependency for error fingerprints.
String sha256Hex(List<int> message) {
  final bitLength = message.length * 8;
  final data = <int>[...message, 0x80];
  while (data.length % 64 != 56) {
    data.add(0);
  }
  // 64-bit big-endian length, built without 64-bit shifts (web-safe).
  final high = (bitLength / 4294967296).floor();
  final low = bitLength & _mask;
  for (final word in [high, low]) {
    data
      ..add((word >> 24) & 0xff)
      ..add((word >> 16) & 0xff)
      ..add((word >> 8) & 0xff)
      ..add(word & 0xff);
  }
  final h = <int>[
    0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, //
    0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19,
  ];
  final w = List<int>.filled(64, 0);
  for (var chunk = 0; chunk < data.length; chunk += 64) {
    for (var i = 0; i < 16; i++) {
      final j = chunk + i * 4;
      w[i] = ((data[j] << 24) | (data[j + 1] << 16) | (data[j + 2] << 8) |
              data[j + 3]) &
          _mask;
    }
    for (var i = 16; i < 64; i++) {
      final s0 = _rotr(w[i - 15], 7) ^ _rotr(w[i - 15], 18) ^ (w[i - 15] >> 3);
      final s1 = _rotr(w[i - 2], 17) ^ _rotr(w[i - 2], 19) ^ (w[i - 2] >> 10);
      w[i] = (w[i - 16] + s0 + w[i - 7] + s1) & _mask;
    }
    var a = h[0], b = h[1], c = h[2], d = h[3];
    var e = h[4], f = h[5], g = h[6], hh = h[7];
    for (var i = 0; i < 64; i++) {
      final s1 = _rotr(e, 6) ^ _rotr(e, 11) ^ _rotr(e, 25);
      final ch = (e & f) ^ ((~e & _mask) & g);
      final t1 = (hh + s1 + ch + _k[i] + w[i]) & _mask;
      final s0 = _rotr(a, 2) ^ _rotr(a, 13) ^ _rotr(a, 22);
      final maj = (a & b) ^ (a & c) ^ (b & c);
      final t2 = (s0 + maj) & _mask;
      hh = g;
      g = f;
      f = e;
      e = (d + t1) & _mask;
      d = c;
      c = b;
      b = a;
      a = (t1 + t2) & _mask;
    }
    h[0] = (h[0] + a) & _mask;
    h[1] = (h[1] + b) & _mask;
    h[2] = (h[2] + c) & _mask;
    h[3] = (h[3] + d) & _mask;
    h[4] = (h[4] + e) & _mask;
    h[5] = (h[5] + f) & _mask;
    h[6] = (h[6] + g) & _mask;
    h[7] = (h[7] + hh) & _mask;
  }
  return h.map((v) => v.toRadixString(16).padLeft(8, '0')).join();
}
