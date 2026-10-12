import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:whisperr/whisperr.dart';
import 'package:whisperr_firebase_messaging/whisperr_firebase_messaging.dart';

class _Settings extends Fake implements NotificationSettings {
  _Settings(this.authorizationStatus);

  @override
  final AuthorizationStatus authorizationStatus;
}

class _App extends Fake implements FirebaseApp {
  _App(this.projectId);

  final String projectId;

  @override
  FirebaseOptions get options => FirebaseOptions(
        apiKey: 'key',
        appId: '1:1:android:1',
        messagingSenderId: '1',
        projectId: projectId,
      );
}

/// A FirebaseMessaging fake. Dispatches by member name, so it does not depend
/// on the exact method signatures of one firebase_messaging version.
class _FakeMessaging extends Fake implements FirebaseMessaging {
  AuthorizationStatus status = AuthorizationStatus.notDetermined;
  AuthorizationStatus afterRequest = AuthorizationStatus.authorized;
  String? fcmToken = 'fcm_tok_1';
  String? apnsToken =
      'a1b2c3d4e5f60718293a4b5c6d7e8f90a1b2c3d4e5f60718293a4b5c6d7e8f90';
  RemoteMessage? initialMessage;
  String? projectId;
  final refresh = StreamController<String>.broadcast();
  final requests = <Map<Symbol, dynamic>>[];

  @override
  dynamic noSuchMethod(Invocation invocation) {
    switch (invocation.memberName) {
      case #requestPermission:
        requests.add(invocation.namedArguments);
        status = afterRequest;
        return Future<NotificationSettings>.value(_Settings(status));
      case #getNotificationSettings:
        return Future<NotificationSettings>.value(_Settings(status));
      case #getToken:
        return Future<String?>.value(fcmToken);
      case #getAPNSToken:
        return Future<String?>.value(apnsToken);
      case #onTokenRefresh:
        return refresh.stream;
      case #getInitialMessage:
        return Future<RemoteMessage?>.value(initialMessage);
      case #app:
        final id = projectId;
        if (id != null) return _App(id);
    }
    return super.noSuchMethod(invocation);
  }
}

class _Harness {
  _Harness({this.appContext = const {}});

  final Map<String, Object?> appContext;
  final identifies = <Map<String, dynamic>>[];
  final events = <Map<String, dynamic>>[];

  Future<WhisperrClient> start() async {
    final mock = MockClient((req) async {
      final body = jsonDecode(req.body) as Map<String, dynamic>;
      if (req.url.path == '/v1/identify') identifies.add(body);
      if (req.url.path == '/v1/events/batch') {
        events.addAll((body['events'] as List).cast<Map<String, dynamic>>());
      }
      return http.Response('{}', 200);
    });
    final client = WhisperrClient(
      apiClient: WhisperrApiClient(
        httpClient: mock,
        baseUrl: 'https://api.test',
        apiKey: 'wrk_test',
        sdkVersion: 'test',
      ),
      persistence: InMemoryPersistence(),
      options: const WhisperrOptions(
        flushOnLifecyclePause: false,
        // On: push_received is an automatic event.
        trackAutomaticEvents: true,
        maxRetries: 0,
      ),
      random: Random(7),
      deviceTraits: () => const <String, Object?>{},
      appContext: () async => appContext,
    );
    addTearDown(client.close);
    await client.start();
    await client.identify('user_1');
    await client.flush();
    identifies.clear();
    return client;
  }

  List<Map<String, dynamic>> get pushOpens =>
      events.where((e) => e['event_type'] == 'push_opened').toList();

  List<Map<String, dynamic>> get receipts =>
      events.where((e) => e['event_type'] == 'push_received').toList();

  /// The `status` / `previous_status` of each `push_permission_changed`.
  List<Map<String, dynamic>> get permissionReports => [
        for (final e in events)
          if (e['event_type'] == 'push_permission_changed')
            {
              for (final key in ['status', 'previous_status'])
                if ((e['properties'] as Map)[key] != null)
                  key: (e['properties'] as Map)[key],
            },
      ];
}

RemoteMessage _message(String id, Map<String, dynamic> data) =>
    RemoteMessage(messageId: id, data: data);

Future<void> _pump() async {
  for (var i = 0; i < 5; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(resetRoutedMessagesForTest);

  test('maps every Firebase authorization status', () {
    expect(whisperrPermissionFrom(AuthorizationStatus.authorized),
        WhisperrPushPermission.granted);
    expect(whisperrPermissionFrom(AuthorizationStatus.provisional),
        WhisperrPushPermission.provisional);
    expect(whisperrPermissionFrom(AuthorizationStatus.denied),
        WhisperrPushPermission.denied);
    expect(whisperrPermissionFrom(AuthorizationStatus.notDetermined),
        WhisperrPushPermission.undetermined);
  });

  group('registerFirebaseMessaging', () {
    test('asks, reports the permission, and registers the FCM token', () async {
      final h = _Harness();
      final client = await h.start();
      final messaging = _FakeMessaging();
      final reg = await client.registerFirebaseMessaging(messaging);
      addTearDown(reg.cancel);
      await client.flush();

      expect(reg.permission, WhisperrPushPermission.granted);
      expect(reg.token, 'fcm_tok_1');
      expect(messaging.requests.single[#provisional], false);
      expect(h.permissionReports, [
        {'status': 'authorized'}
      ]);
      expect(h.identifies, [
        {
          'external_user_id': 'user_1',
          'channels': [
            {
              'channel': 'push',
              'address': 'fcm_tok_1',
              'opted_in': true,
              'kind': 'fcm',
              'platform': 'android',
            }
          ],
        },
      ]);
    });

    test('sends the Firebase project id, platform and client_app_id', () async {
      final h = _Harness(appContext: const {
        'platform': 'android',
        'client_app_id': 'com.example.app',
      });
      final client = await h.start();
      final messaging = _FakeMessaging()..projectId = 'example-project';
      final reg = await client.registerFirebaseMessaging(messaging);
      messaging.refresh.add('fcm_tok_2');
      await _pump();
      await client.flush();
      await reg.cancel();
      const fields = {
        'kind': 'fcm',
        'platform': 'android',
        'client_app_id': 'com.example.app',
        'provider_project': 'example-project',
      };
      expect(h.identifies.first['channels'], [
        {'channel': 'push', 'address': 'fcm_tok_1', 'opted_in': true, ...fields}
      ]);
      expect((h.identifies.last['channels'] as List).last, {
        'channel': 'push',
        'address': 'fcm_tok_2',
        'opted_in': true,
        ...fields
      });
    });

    test('APNs mode never sends provider_project', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      final h = _Harness();
      final client = await h.start();
      final messaging = _FakeMessaging()..projectId = 'example-project';
      final reg = await client.registerFirebaseMessaging(messaging,
          useApnsToken: true,
          apnsEnvironment: WhisperrPushEnvironment.production);
      await reg.cancel();
      await client.flush();
      final entry = (h.identifies.last['channels'] as List).single as Map;
      expect(entry['kind'], 'apns');
      expect(entry['push_env'], 'production');
      expect(entry.containsKey('provider_project'), isFalse);
      debugDefaultTargetPlatformOverride = null;
    });

    test('reports foreground Whisperr pushes as push_received, once each',
        () async {
      final h = _Harness();
      final client = await h.start();
      final foreground = StreamController<RemoteMessage>();
      final reg = await client.registerFirebaseMessaging(_FakeMessaging(),
          onMessage: foreground.stream);
      foreground.add(_message('m1', {'whisperr_message_id': 'msg_1'}));
      foreground.add(_message('m1', {'whisperr_message_id': 'msg_1'}));
      foreground.add(_message('m2', {'campaign': 'other'}));
      await _pump();
      await client.flush();
      await reg.cancel();
      foreground.add(_message('m3', {'whisperr_message_id': 'msg_3'}));
      await _pump();
      await client.flush();
      expect(h.receipts.map((e) => e['properties']['whisperr_message_id']),
          ['msg_1']);
      expect(h.receipts.single['properties'],
          containsPair('source', 'foreground'));
    });

    test('trackForegroundReceipts: false reports none', () async {
      final h = _Harness();
      final client = await h.start();
      final foreground = StreamController<RemoteMessage>.broadcast();
      final reg = await client.registerFirebaseMessaging(_FakeMessaging(),
          onMessage: foreground.stream, trackForegroundReceipts: false);
      foreground.add(_message('m1', {'whisperr_message_id': 'msg_1'}));
      await _pump();
      await client.flush();
      await reg.cancel();
      expect(h.receipts, isEmpty);
    });

    test('forwards token refreshes with kind fcm', () async {
      final h = _Harness();
      final client = await h.start();
      final messaging = _FakeMessaging();
      final reg = await client.registerFirebaseMessaging(messaging);
      addTearDown(reg.cancel);
      messaging.refresh.add('fcm_tok_2');
      await _pump();
      await client.flush();
      expect(h.identifies.last['channels'], [
        {'channel': 'push', 'address': 'fcm_tok_1', 'opted_in': false},
        {
          'channel': 'push',
          'address': 'fcm_tok_2',
          'opted_in': true,
          'kind': 'fcm',
          'platform': 'android',
        },
      ]);
    });

    test('denied: reports it and registers no token', () async {
      final h = _Harness();
      final client = await h.start();
      final messaging = _FakeMessaging()
        ..afterRequest = AuthorizationStatus.denied;
      final reg = await client.registerFirebaseMessaging(messaging);
      addTearDown(reg.cancel);
      messaging.refresh.add('fcm_tok_2');
      await _pump();
      await client.flush();
      expect(reg.permission, WhisperrPushPermission.denied);
      expect(reg.token, isNull);
      expect(h.permissionReports, [
        {'status': 'denied'}
      ]);
      expect(h.identifies, isEmpty);
    });

    test('requestPermission: false only reads the permission', () async {
      final h = _Harness();
      final client = await h.start();
      final messaging = _FakeMessaging();
      final reg = await client.registerFirebaseMessaging(messaging,
          requestPermission: false);
      addTearDown(reg.cancel);
      expect(messaging.requests, isEmpty);
      expect(reg.permission, WhisperrPushPermission.undetermined);
      expect(reg.token, isNull);
    });

    test('on resume: off in Settings opts out, on again re-registers',
        () async {
      final h = _Harness();
      final client = await h.start();
      final messaging = _FakeMessaging();
      final reg = await client.registerFirebaseMessaging(messaging);
      addTearDown(reg.cancel);
      await client.flush();
      h.identifies.clear();

      final binding = TestWidgetsFlutterBinding.instance;
      Future<void> resume() async {
        binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
        binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
        await _pump();
        await client.flush();
      }

      messaging.status = AuthorizationStatus.denied;
      await resume();
      expect(h.identifies, [
        {
          'external_user_id': 'user_1',
          'channels': [
            {'channel': 'push', 'address': 'fcm_tok_1', 'opted_in': false}
          ],
        }
      ]);

      h.identifies.clear();
      messaging.status = AuthorizationStatus.authorized;
      await resume();
      expect((h.identifies.single['channels'] as List).single,
          containsPair('opted_in', true));
      expect(h.permissionReports, [
        {'status': 'authorized'},
        {'status': 'denied', 'previous_status': 'authorized'},
        {'status': 'authorized', 'previous_status': 'denied'},
      ]);
    });

    test('iOS with useApnsToken registers the APNs token with push_env',
        () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      final h = _Harness();
      final client = await h.start();
      final messaging = _FakeMessaging();
      final reg = await client.registerFirebaseMessaging(messaging,
          useApnsToken: true, apnsEnvironment: WhisperrPushEnvironment.sandbox);
      await reg.cancel();
      await client.flush();
      expect(h.identifies.last['channels'], [
        {
          'channel': 'push',
          'address': messaging.apnsToken,
          'opted_in': true,
          'kind': 'apns',
          'platform': 'ios',
          'push_env': 'sandbox',
        }
      ]);
      debugDefaultTargetPlatformOverride = null;
    });
  });

  group('notification opens', () {
    test('handleRemoteMessage tracks push_opened and returns the deep link',
        () async {
      final h = _Harness();
      final client = await h.start();
      final open = await client.handleRemoteMessage(_message('m1', {
        'whisperr_message_id': 'msg_1',
        'whisperr_deep_link': 'myapp://offers/annual',
      }));
      await client.flush();
      expect(
          open,
          const WhisperrPushOpen(
              messageId: 'msg_1', deepLink: 'myapp://offers/annual'));
      expect(h.pushOpens.single['properties'],
          containsPair('deep_link', 'myapp://offers/annual'));
      expect(
          await client.handleRemoteMessage(_message('m2', {'x': 'y'})), isNull);
    });

    test('handleNotificationOpens: cold start, then taps, once each', () async {
      final h = _Harness();
      final client = await h.start();
      final messaging = _FakeMessaging()
        ..initialMessage = _message('m1', {'whisperr_message_id': 'msg_1'});
      final opened = StreamController<RemoteMessage>();
      final routed = <String>[];
      final sub = await client.handleNotificationOpens(
        messaging,
        onOpen: (open, _) => routed.add(open.messageId),
        onMessageOpenedApp: opened.stream,
      );
      opened.add(_message('m2', {'whisperr_message_id': 'msg_2'}));
      opened.add(_message('m2', {'whisperr_message_id': 'msg_2'}));
      opened.add(_message('m3', {'campaign': 'other'}));
      await _pump();
      await client.flush();
      await sub.cancel();

      expect(routed, ['msg_1', 'msg_2']);
      expect(h.pushOpens.map((e) => e['properties']['whisperr_message_id']),
          ['msg_1', 'msg_2']);
      // The launch message is a cold start; later taps are not.
      expect(
          h.pushOpens.map((e) => e['properties']['cold_start']), [true, false]);
      expect(h.pushOpens.map((e) => e['properties']['action_id']),
          ['default', 'default']);

      // A second subscription (hot restart) does not route the same launch
      // message again.
      final again = <String>[];
      final sub2 = await client.handleNotificationOpens(messaging,
          onOpen: (open, _) => again.add(open.messageId),
          onMessageOpenedApp: const Stream.empty());
      await sub2.cancel();
      expect(again, isEmpty);
    });
  });
}
