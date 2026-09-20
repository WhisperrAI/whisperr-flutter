import 'dart:async';
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:whisperr/whisperr.dart';

const product =
    WhisperrMessageAction(kind: 'product', id: '901', locationId: '42');
const push =
    WhisperrPushMessage(messageId: 'msg_1', userId: '123', action: product);

void main() {
  test('strict versioned discovery action preserves native catalog identity',
      () {
    final parsed = WhisperrMessageAction.tryParse(product.toJson())!;
    expect(parsed.kind, 'product');
    expect(parsed.id, '901');
    expect(parsed.locationId, '42');
    expect(WhisperrMessageAction.tryParse({...product.toJson(), 'version': 2}),
        isNull);
    expect(
        WhisperrMessageAction.tryParse({...product.toJson(), 'type': 'redeem'}),
        isNull);
    expect(
        WhisperrMessageAction.tryParse({
          'version': 1,
          'type': 'view_item',
          'target': {'kind': 'product', 'id': '901'}
        }),
        isNotNull);
    expect(
        WhisperrMessageAction.tryParse({
          'version': 1,
          'type': 'view_item',
          'target': {'kind': 'location', 'id': 42}
        }),
        isNull);
  });

  test('shared IDs and opaque cursor follow contract limits', () {
    final id = 'x' * 512;
    expect(
        WhisperrMessageAction.tryParse(
            WhisperrMessageAction(kind: 'product', id: id).toJson()),
        isNotNull);
    expect(
        WhisperrMessageAction.tryParse(
            WhisperrMessageAction(kind: 'product', id: '${id}x').toJson()),
        isNull);
    expect(
        WhisperrInboxPage.fromJson({
          'messages': [],
          'next_cursor': 'c' * 4096,
        }).nextCursor!.length,
        4096);
    expect(
        () => WhisperrInboxPage.fromJson({
              'messages': [],
              'next_cursor': 'c' * 4097,
            }),
        throwsFormatException);
  });

  test('explicit inbox taps can reopen the same message', () async {
    var opened = 0;
    final coordinator = WhisperrActionCoordinator(
      resolve: (_) async => product,
      open: (_, __) async {
        opened++;
      },
      unavailable: () async => fail('available'),
    );
    await coordinator.updateSession(userId: '123', ready: true);
    await coordinator.receive(push);
    await coordinator.receive(push, deduplicate: false);
    expect(opened, 2);
  });

  test('latest tap cancels earlier out-of-order responses', () async {
    final first = Completer<WhisperrMessageAction?>();
    final opened = <String>[];
    final coordinator = WhisperrActionCoordinator(
      resolve: (id) => id == 'msg_1' ? first.future : Future.value(product),
      open: (_, id) async {
        opened.add(id);
      },
      unavailable: () async => fail('available'),
    );
    await coordinator.updateSession(userId: '123', ready: true);
    final pending = coordinator.receive(push);
    await coordinator
        .receive(const WhisperrPushMessage(messageId: 'msg_2', userId: '123'));
    first.complete(product);
    await pending;
    expect(opened, ['msg_2']);
  });

  test('cancelled login discards pending action', () async {
    final coordinator = WhisperrActionCoordinator(
      resolve: (_) async => fail('cancelled'),
      open: (_, __) async => fail('cancelled'),
      unavailable: () async => fail('cancelled'),
    );
    await coordinator.receive(push);
    coordinator.cancelPending();
    await coordinator.updateSession(userId: '123', ready: true);
  });

  test('leaving ready navigation invalidates an in-flight action', () async {
    final response = Completer<WhisperrMessageAction?>();
    final coordinator = WhisperrActionCoordinator(
      resolve: (_) => response.future,
      open: (_, __) async => fail('cancelled navigation'),
      unavailable: () async => fail('cancelled navigation'),
    );
    await coordinator.updateSession(userId: '123', ready: true);
    final receipt = coordinator.receive(push);
    await coordinator.updateSession(userId: '123', ready: false);
    await coordinator.updateSession(userId: '123', ready: true);
    response.complete(product);
    await receipt;
  });

  test('push parser ignores host notifications and requires recipient', () {
    expect(
        WhisperrPushMessage.isWhisperr({'id': '1', 'action': 'open'}), isFalse);
    expect(
        WhisperrPushMessage.tryParse({'whisperr_message_id': 'msg_1'}), isNull);
    final parsed = WhisperrPushMessage.tryParse({
      'whisperr_message_id': 'msg_1',
      'whisperr_user_id': '123',
      'whisperr_action': jsonEncode(product.toJson()),
    })!;
    expect(parsed.action!.id, '901');
    expect(parsed.userId, '123');
  });

  test('history fails explicitly on malformed page and accepts null actions',
      () {
    final page = WhisperrInboxPage.fromJson({
      'messages': [
        {
          'id': 'msg_1',
          'title': 'Venue',
          'body': 'Discover it',
          'created_at': '2026-09-21T10:00:00Z',
          'action': null,
        }
      ],
      'next_cursor': null
    });
    expect(page.messages.single.action, isNull);
    expect(() => WhisperrInboxPage.fromJson({}), throwsFormatException);
  });

  test('cold start waits for ready and same-account login before resolving',
      () async {
    final resolved = <String>[];
    final opened = <String>[];
    final coordinator = WhisperrActionCoordinator(
      resolve: (id) async {
        resolved.add(id);
        return product;
      },
      open: (action, id) async {
        opened.add('${action.locationId}/${action.id}');
      },
      unavailable: () async => fail('available action'),
    );
    await coordinator.receive(push);
    await coordinator.updateSession(userId: '123', ready: false);
    expect(resolved, isEmpty);
    await coordinator.updateSession(userId: '123', ready: true);
    expect(opened, ['42/901']);
    await coordinator.receive(push);
    expect(resolved, ['msg_1']);
  });

  test('login as different user discards pending recipient action', () async {
    var calls = 0;
    final coordinator = WhisperrActionCoordinator(
      resolve: (_) async {
        calls++;
        return product;
      },
      open: (_, __) async => fail('wrong account'),
      unavailable: () async => fail('wrong account'),
    );
    await coordinator.receive(push);
    await coordinator.updateSession(userId: '456', ready: true);
    await coordinator.receive(push);
    await coordinator.updateSession(userId: '123', ready: true);
    expect(calls, 0);
  });

  test('account switch discards in-flight action response', () async {
    final response = Completer<WhisperrMessageAction?>();
    final coordinator = WhisperrActionCoordinator(
      resolve: (_) => response.future,
      open: (_, __) async => fail('stale account result'),
      unavailable: () async => fail('stale account result'),
    );
    await coordinator.updateSession(userId: '123', ready: true);
    final receipt = coordinator.receive(push);
    await coordinator.updateSession(userId: '456', ready: true);
    response.complete(product);
    await receipt;
  });

  test('unavailable or offline destination falls back and never trusts push',
      () async {
    var unavailable = 0;
    var calls = 0;
    final coordinator = WhisperrActionCoordinator(
      resolve: (_) async {
        calls++;
        throw const FormatException('offline');
      },
      open: (_, __) async => fail('must not trust push action'),
      unavailable: () async {
        unavailable++;
      },
    );
    await coordinator.updateSession(userId: '123', ready: true);
    await coordinator.receive(push);
    await coordinator.receive(push);
    expect(unavailable, 2);
    expect(calls, 2);
  });
}
