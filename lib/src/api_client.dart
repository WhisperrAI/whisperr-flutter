import 'dart:convert';

import 'package:http/http.dart' as http;

/// Result of a `/v1/events/batch` call.
class WhisperrBatchResult {
  const WhisperrBatchResult({required this.accepted, required this.rejected});

  final int accepted;
  final int rejected;
}

/// Raised when the backend returns a non-2xx response or the request fails.
class WhisperrApiException implements Exception {
  WhisperrApiException(this.message, {this.statusCode, this.code});

  final String message;
  final int? statusCode;
  final String? code;

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

    throw WhisperrApiException(message, statusCode: status, code: code);
  }
}
