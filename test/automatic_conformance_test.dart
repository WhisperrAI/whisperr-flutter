import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/widgets.dart' show AppLifecycleState;
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:whisperr/src/app_context.dart' show kWhisperrSdkName, osFamily;
import 'package:whisperr/whisperr.dart';

const _specUrl =
    'https://raw.githubusercontent.com/WhisperrAI/whisperr-spec/main/conformance/automatic.json';

Future<Map<String, dynamic>> _loadSpec() async {
  // automatic.json lives next to wire.json; derive it like the push suite.
  var local = Platform.environment['WHISPERR_AUTOMATIC_SPEC_PATH'];
  final wire = Platform.environment['WHISPERR_SPEC_PATH'];
  if ((local == null || local.isEmpty) && wire != null && wire.isNotEmpty) {
    local = File(wire).parent.uri.resolve('automatic.json').toFilePath();
  }
  if (local != null && local.isNotEmpty) {
    return jsonDecode(await File(local).readAsString()) as Map<String, dynamic>;
  }
  final res = await http.get(Uri.parse(_specUrl));
  if (res.statusCode != 200) {
    throw StateError('fetch automatic spec: ${res.statusCode}');
  }
  return jsonDecode(res.body) as Map<String, dynamic>;
}

/// The SDK's own values for the fixture placeholders.
final _placeholders = <String, Object?>{
  r'$platform': osFamily(),
  r'$sdk_name': kWhisperrSdkName,
  r'$sdk_version': kWhisperrSdkVersion,
};

Object? _bind(Object? expected) {
  if (expected is String && _placeholders.containsKey(expected)) {
    return _placeholders[expected];
  }
  if (expected is Map) {
    return {for (final e in expected.entries) e.key: _bind(e.value)};
  }
  return expected;
}

class _Case {
  _Case(this.spec) {
    final device = Map<String, dynamic>.from(spec['device'] as Map? ?? {});
    osVersion = device['osVersion'] as String?;
    deviceTraits = {
      if (device['locale'] != null) 'locale': device['locale'],
      if (device['timezone'] != null) 'timezone': device['timezone'],
      if (device['timezoneOffsetMinutes'] != null)
        'timezone_offset_minutes': device['timezoneOffsetMinutes'],
    };
  }

  final Map<String, dynamic> spec;
  late final String? osVersion;
  late final Map<String, Object?> deviceTraits;
  final persistence = InMemoryPersistence();
  final requests = <http.Request>[];
  final random = Random(7);
  DateTime now = DateTime.utc(2026, 10, 7, 12);

  String get name => spec['name'] as String;

  bool get automatic =>
      (spec['config'] as Map?)?['automaticEvents'] as bool? ?? true;

  late final MockClient mock = MockClient((req) async {
    requests.add(req);
    return http.Response('{"accepted":1,"rejected":0}', 202);
  });

  WhisperrClient client(String appVersion, String appBuild) {
    final os = osFamily();
    return WhisperrClient(
      apiClient: WhisperrApiClient(
        httpClient: mock,
        baseUrl: 'https://api.test',
        apiKey: 'wrk_test',
        sdkVersion: 'test',
      ),
      persistence: persistence,
      options: WhisperrOptions(
        flushInterval: const Duration(hours: 1),
        flushOnLifecyclePause: false,
        trackAutomaticEvents: automatic,
        retryBaseDelay: const Duration(milliseconds: 1),
        maxRetryDelay: const Duration(milliseconds: 5),
        maxRetries: 2,
      ),
      clock: () => now,
      random: random,
      deviceTraits: () => deviceTraits,
      appContext: () async => {
        'app_version': appVersion,
        'app_build': appBuild,
        if (os != null) 'platform': os,
        if (os != null) 'os_name': os,
        if (osVersion != null) 'os_version': osVersion,
      },
    );
  }

  /// Every event sent, in send order, without identity, time and context.
  List<Map<String, dynamic>> sentEvents() {
    final out = <Map<String, dynamic>>[];
    for (final r in requests) {
      final path = r.url.path;
      if (path != '/v1/events/batch' && path != '/v1/events/track') continue;
      final body = jsonDecode(r.body) as Map<String, dynamic>;
      final events = path == '/v1/events/batch'
          ? (body['events'] as List).cast<Map<String, dynamic>>()
          : [body];
      for (final e in events) {
        expect((e['context'] as Map)[r'$message_id'], isNotNull,
            reason: '$name: context.\$message_id');
        out.add({'event_type': e['event_type'], 'properties': e['properties']});
      }
    }
    return out;
  }
}

Future<void> _seed(String? storage, WhisperrPersistence persistence) async {
  switch (storage ?? 'empty') {
    case 'empty':
      return;
    case 'legacy_sdk_state':
      await persistence.save(
          WhisperrPersistence.identitySlot, jsonEncode({'user_id': 'user_1'}));
      return;
    default:
      fail('unknown storage $storage');
  }
}

Future<void> _run(_Case c) async {
  await _seed(c.spec['storage'] as String?, c.persistence);
  WhisperrClient? client;
  WhisperrClient live() {
    final current = client;
    if (current == null) fail('${c.name}: step before launch');
    return current;
  }

  for (final raw in c.spec['steps'] as List) {
    final step = Map<String, dynamic>.from(raw as Map);
    final kind = step.keys.single;
    final value = step[kind];
    switch (kind) {
      case 'launch':
        final launch = Map<String, dynamic>.from(value as Map);
        final next = c.client(
            launch['appVersion'] as String, launch['appBuild'] as String);
        client = next;
        // No binding in this suite: start() treats the process as in the
        // foreground and delivers the cold-start open itself.
        await next.start();
        await next.identify('user_1');
      case 'background':
        c.now =
            c.now.add(Duration(milliseconds: (value as Map)['afterMs'] as int));
        live().handleLifecycleState(AppLifecycleState.paused);
      case 'foreground':
        c.now =
            c.now.add(Duration(milliseconds: (value as Map)['afterMs'] as int));
        live().handleLifecycleState(AppLifecycleState.resumed);
      case 'terminate':
        await live().close();
        client = null;
      case 'screen':
        await live().screen(value as String);
      case 'pushOpened':
        await live().trackPushOpened(Map<String, dynamic>.from(value as Map));
      case 'pushPermission':
        final status = WhisperrPushPermission.fromWire(value);
        if (status == null) fail('${c.name}: unknown status $value');
        await live().setPushPermission(status);
      case 'reset':
        await live().reset();
      case 'optOut':
        await live().optOut();
      case 'optIn':
        await live().optIn();
      default:
        fail('${c.name}: unknown step $kind');
    }
    await pumpEventQueue();
    await client?.flush();
  }
  await client?.close();
}

void main() {
  test('automatic-events conformance (whisperr-spec)', () async {
    final spec = await _loadSpec();
    final common = Map<String, dynamic>.from(spec['commonProperties'] as Map);
    for (final key in ['platform', 'os_name', 'sdk_name']) {
      final allowed = (common[key] as Map)['enum'] as List;
      expect(allowed, contains(_bind(common[key]['placeholder'])),
          reason: 'commonProperties.$key');
    }

    final cases = (spec['cases'] as List).cast<Map<String, dynamic>>();
    expect(cases, isNotEmpty);
    for (final raw in cases) {
      final c = _Case(raw);
      await _run(c);
      final expected = [
        for (final e in raw['expectedEvents'] as List)
          {
            'event_type': (e as Map)['event_type'],
            'properties': _bind(e['properties']),
          }
      ];
      expect(c.sentEvents(), expected, reason: c.name);
    }
  });
}
