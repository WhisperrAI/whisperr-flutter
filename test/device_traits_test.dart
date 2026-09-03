import 'dart:convert';
import 'dart:math';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:whisperr/whisperr.dart';

const _fastOptions = WhisperrOptions(
  flushOnLifecyclePause: false,
  retryBaseDelay: Duration(milliseconds: 1),
  maxRetryDelay: Duration(milliseconds: 5),
  maxRetries: 2,
);

/// A client on the REAL device-trait resolver unless [deviceTraits] is given.
WhisperrClient buildClient(
  MockClient mock, {
  Map<String, Object?> Function()? deviceTraits,
}) {
  final api = WhisperrApiClient(
    httpClient: mock,
    baseUrl: 'https://api.test',
    apiKey: 'wrk_test',
    sdkVersion: 'test',
  );
  return WhisperrClient(
    apiClient: api,
    persistence: InMemoryPersistence(),
    options: _fastOptions,
    clock: () => DateTime.utc(2026, 5, 31, 12),
    random: Random(7),
    deviceTraits: deviceTraits,
  );
}

MockClient _recording(List<Map<String, dynamic>> identifies) =>
    MockClient((req) async {
      if (req.url.path == '/v1/identify') {
        identifies.add(jsonDecode(req.body) as Map<String, dynamic>);
      }
      return http.Response(
          '{"user":{"id":"u","external_id":"u","created":true}}', 200);
    });

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    binding.platformDispatcher.localeTestValue = const Locale('de', 'DE');
  });
  tearDown(() {
    binding.platformDispatcher.clearLocaleTestValue();
  });

  test('identify fills locale (BCP 47) and the UTC-offset fallback by default',
      () async {
    final identifies = <Map<String, dynamic>>[];
    final client = buildClient(_recording(identifies));
    addTearDown(client.close);
    await client.start();

    await client.identify('u1', traits: {'plan': 'pro'});
    await client.flush();

    expect(identifies, hasLength(1));
    expect(identifies.first['traits'], {
      'plan': 'pro',
      'locale': 'de-DE',
      'timezone_offset_minutes': DateTime.now().timeZoneOffset.inMinutes,
    });
    // Reserved keys ride inside traits — never top-level (the server 400s
    // unknown top-level fields).
    expect(
        identifies.first.keys, unorderedEquals(['external_user_id', 'traits']));
    // Flutter never guesses an IANA zone name.
    expect(identifies.first['traits'], isNot(contains('timezone')));
  });

  test('defaults apply to a bare identify() too', () async {
    final identifies = <Map<String, dynamic>>[];
    final client = buildClient(_recording(identifies));
    addTearDown(client.close);
    await client.start();

    await client.identify('u1');
    await client.flush();

    expect(identifies.first['traits'], {
      'locale': 'de-DE',
      'timezone_offset_minutes': DateTime.now().timeZoneOffset.inMinutes,
    });
  });

  test('locale is emitted with script + region when the platform has them',
      () async {
    binding.platformDispatcher.localeTestValue = const Locale.fromSubtags(
        languageCode: 'zh', scriptCode: 'Hans', countryCode: 'CN');
    final identifies = <Map<String, dynamic>>[];
    final client = buildClient(_recording(identifies));
    addTearDown(client.close);
    await client.start();

    await client.identify('u1');
    await client.flush();

    expect(identifies.first['traits']['locale'], 'zh-Hans-CN');
  });

  test('caller-supplied locale and timezone always win', () async {
    final identifies = <Map<String, dynamic>>[];
    final client = buildClient(_recording(identifies));
    addTearDown(client.close);
    await client.start();

    await client.identify('u1', traits: {
      'locale': 'fr-CA',
      'timezone': 'Europe/Berlin',
      'plan': 'pro',
    });
    await client.flush();

    // An IANA name from the caller supersedes the offset fallback entirely.
    expect(identifies.first['traits'],
        {'locale': 'fr-CA', 'timezone': 'Europe/Berlin', 'plan': 'pro'});
  });

  test('a legacy time_zone / tz alias counts as caller-supplied', () async {
    final identifies = <Map<String, dynamic>>[];
    final client = buildClient(_recording(identifies));
    addTearDown(client.close);
    await client.start();

    await client.identify('u1', traits: {'tz': 'Asia/Tokyo'});
    await client.flush();

    expect(
        identifies.first['traits'], {'tz': 'Asia/Tokyo', 'locale': 'de-DE'});
  });

  test('an injected resolver overrides the platform (and caller still wins)',
      () async {
    final identifies = <Map<String, dynamic>>[];
    final client = buildClient(
      _recording(identifies),
      deviceTraits: () => {'timezone': 'Europe/Berlin', 'locale': 'de-DE'},
    );
    addTearDown(client.close);
    await client.start();

    await client.identify('u1', traits: {'timezone': 'America/New_York'});
    await client.flush();

    expect(identifies.first['traits'],
        {'timezone': 'America/New_York', 'locale': 'de-DE'});
  });

  test('no locale is sent when the platform reports none (und)', () async {
    binding.platformDispatcher.localeTestValue = const Locale.fromSubtags();
    final identifies = <Map<String, dynamic>>[];
    final client = buildClient(_recording(identifies));
    addTearDown(client.close);
    await client.start();

    await client.identify('u1');
    await client.flush();

    expect(identifies.first['traits'], {
      'timezone_offset_minutes': DateTime.now().timeZoneOffset.inMinutes,
    });
  });

  test('no traits key at all when nothing resolves and the caller passes none',
      () async {
    final identifies = <Map<String, dynamic>>[];
    final client = buildClient(_recording(identifies),
        deviceTraits: () => const <String, Object?>{});
    addTearDown(client.close);
    await client.start();

    await client.identify('u1');
    await client.flush();

    expect(identifies, [
      {'external_user_id': 'u1'}
    ]);
  });

  test('a throwing resolver never breaks identify()', () async {
    final identifies = <Map<String, dynamic>>[];
    final client = buildClient(_recording(identifies),
        deviceTraits: () => throw StateError('no platform'));
    addTearDown(client.close);
    await client.start();

    await client.identify('u1', traits: {'plan': 'pro'});
    await client.flush();

    expect(identifies.first['traits'], {'plan': 'pro'});
  });

  test("setPushToken's partial identify stays traits-free", () async {
    final identifies = <Map<String, dynamic>>[];
    final client = buildClient(_recording(identifies));
    addTearDown(client.close);
    await client.start();

    await client.identify('u1');
    await client.flush();
    await client.setPushToken('fcm_tok_a');
    await client.flush();

    expect(identifies, hasLength(2));
    expect(identifies[0]['traits'], isNotNull);
    expect(identifies[1], {
      'external_user_id': 'u1',
      'channels': [
        {'channel': 'push', 'address': 'fcm_tok_a', 'opted_in': true}
      ],
    });
  });
}
