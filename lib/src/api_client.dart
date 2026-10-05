import 'dart:convert';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:http/http.dart' as http;

/// Longest `Retry-After` the SDK honors (whisperr-spec SPEC.md → Delivery).
const Duration kWhisperrMaxRetryAfter = Duration(seconds: 60);

const _months = {
  'jan': 1, 'feb': 2, 'mar': 3, 'apr': 4, 'may': 5, 'jun': 6, //
  'jul': 7, 'aug': 8, 'sep': 9, 'oct': 10, 'nov': 11, 'dec': 12,
};

/// Parses a `Retry-After` value — delay-seconds or an HTTP-date (RFC 9110
/// §10.2.3: IMF-fixdate, RFC 850 or asctime) — into a wait from [now],
/// capped at [kWhisperrMaxRetryAfter]. Returns null when absent or
/// unparseable, so the caller falls back to its backoff.
@visibleForTesting
Duration? parseRetryAfter(String? value, {DateTime? now}) {
  if (value == null) return null;
  final v = value.trim();
  if (v.isEmpty) return null;
  Duration wait;
  if (RegExp(r'^\d+$').hasMatch(v)) {
    final seconds = int.tryParse(v);
    if (seconds == null) return null;
    wait = Duration(seconds: seconds);
  } else {
    final at = _parseHttpDate(v);
    if (at == null) return null;
    wait = at.difference((now ?? DateTime.now()).toUtc());
    if (wait.isNegative) wait = Duration.zero;
  }
  return wait > kWhisperrMaxRetryAfter ? kWhisperrMaxRetryAfter : wait;
}

DateTime? _parseHttpDate(String v) {
  // IMF-fixdate: Sun, 06 Nov 1994 08:49:37 GMT
  // RFC 850:     Sunday, 06-Nov-94 08:49:37 GMT
  // asctime:     Sun Nov  6 08:49:37 1994
  final fix = RegExp(
          r'^[A-Za-z]+,\s*(\d{1,2})[ -]([A-Za-z]{3})[ -](\d{2,4})\s+(\d{2}):(\d{2}):(\d{2})\s+GMT$')
      .firstMatch(v);
  if (fix != null) {
    var year = int.parse(fix.group(3)!);
    if (year < 100) year += year < 70 ? 2000 : 1900;
    return _utc(year, fix.group(2)!, fix.group(1)!, fix.group(4)!,
        fix.group(5)!, fix.group(6)!);
  }
  final asc = RegExp(
          r'^[A-Za-z]{3}\s+([A-Za-z]{3})\s+(\d{1,2})\s+(\d{2}):(\d{2}):(\d{2})\s+(\d{4})$')
      .firstMatch(v);
  if (asc != null) {
    return _utc(int.parse(asc.group(6)!), asc.group(1)!, asc.group(2)!,
        asc.group(3)!, asc.group(4)!, asc.group(5)!);
  }
  return null;
}

DateTime? _utc(int year, String month, String day, String h, String m, String s) {
  final mon = _months[month.toLowerCase()];
  if (mon == null) return null;
  return DateTime.utc(year, mon, int.parse(day), int.parse(h), int.parse(m),
      int.parse(s));
}

/// Result of a `/v1/events/batch` call.
class WhisperrBatchResult {
  const WhisperrBatchResult({required this.accepted, required this.rejected});

  final int accepted;
  final int rejected;
}

/// Raised when the backend returns a non-2xx response or the request fails.
class WhisperrApiException implements Exception {
  WhisperrApiException(this.message,
      {this.statusCode, this.code, this.retryAfter});

  final String message;
  final int? statusCode;
  final String? code;

  /// The server-requested wait from a `429`/`503` `Retry-After` header,
  /// already capped at [kWhisperrMaxRetryAfter]. Null when absent or
  /// unparseable; the client then uses its own backoff.
  final Duration? retryAfter;

  /// Transient failures worth retrying: network errors (null status), 429, 5xx.
  bool get isRetryable => statusCode == null || statusCode == 429 || (statusCode! >= 500 && statusCode! < 600);

  /// Auth/configuration failures: a bad or revoked API key. Not worth retrying
  /// blindly — surface and pause.
  bool get isAuthError => statusCode == 401 || statusCode == 403;

  /// Permanent request errors (malformed payload) that won't succeed on retry.
  bool get isClientError =>
      statusCode != null && statusCode! >= 400 && statusCode! < 500 && !isAuthError && statusCode != 429;

  @override
  String toString() => 'WhisperrApiException($statusCode${code != null ? ' $code' : ''}): $message';
}

/// Thin transport over the Whisperr runtime API.
class WhisperrApiClient {
  WhisperrApiClient({
    required http.Client httpClient,
    required String baseUrl,
    required String apiKey,
    required String sdkVersion,
    Duration timeout = const Duration(seconds: 30),
  })  : _http = httpClient,
        _base = _normalizeBase(baseUrl),
        _apiKey = apiKey,
        _sdkVersion = sdkVersion,
        _timeout = timeout;

  final http.Client _http;
  final Uri _base;
  final String _apiKey;
  final String _sdkVersion;
  final Duration _timeout;

  static Uri _normalizeBase(String raw) {
    final trimmed = raw.trim().replaceAll(RegExp(r'/+$'), '');
    final uri = Uri.tryParse(trimmed);
    if (uri == null || !uri.hasScheme || uri.host.isEmpty) {
      throw ArgumentError.value(raw, 'baseUrl', 'must be an absolute URL, e.g. https://api.yourhost.com');
    }
    return uri;
  }

  Map<String, String> get _headers => {
        'Content-Type': 'application/json',
        'Authorization': 'Bearer $_apiKey',
        'X-Whisperr-Sdk': 'flutter/$_sdkVersion',
      };

  Uri _endpoint(String path) => _base.replace(path: '${_base.path}$path');

  /// `POST /v1/identify`
  Future<void> identify(Map<String, dynamic> body) async {
    await _post(_endpoint('/v1/identify'), body);
  }

  /// `POST /v1/events/batch`
  Future<WhisperrBatchResult> trackBatch(List<Map<String, dynamic>> events) async {
    final decoded = await _post(_endpoint('/v1/events/batch'), {'events': events});
    return WhisperrBatchResult(
      accepted: (decoded['accepted'] as num?)?.toInt() ?? events.length,
      rejected: (decoded['rejected'] as num?)?.toInt() ?? 0,
    );
  }

  Future<Map<String, dynamic>> _post(Uri url, Map<String, dynamic> body) async {
    http.Response response;
    try {
      response = await _http.post(url, headers: _headers, body: jsonEncode(body)).timeout(_timeout);
    } catch (error) {
      // Network failure / timeout — retryable (null status).
      throw WhisperrApiException('request failed: $error');
    }

    final status = response.statusCode;
    if (status >= 200 && status < 300) {
      if (response.body.isEmpty) return const {};
      try {
        final decoded = jsonDecode(response.body);
        return decoded is Map<String, dynamic> ? decoded : const {};
      } catch (_) {
        return const {};
      }
    }

    String? code;
    String message = 'request failed with status $status';
    try {
      final decoded = jsonDecode(response.body);
      if (decoded is Map && decoded['error'] is Map) {
        final err = decoded['error'] as Map;
        code = err['code'] as String?;
        message = (err['message'] as String?)?.trim().isNotEmpty == true ? err['message'] as String : message;
      }
    } catch (_) {
      // non-JSON error body — keep default message
    }

    final retryAfter = status == 429 || status == 503
        ? parseRetryAfter(response.headers['retry-after'])
        : null;
    throw WhisperrApiException(message,
        statusCode: status, code: code, retryAfter: retryAfter);
  }
}
