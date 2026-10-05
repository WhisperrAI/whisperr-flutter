import 'dart:async';

import 'package:flutter/foundation.dart'
    show TargetPlatform, defaultTargetPlatform, kIsWeb;
import 'package:package_info_plus/package_info_plus.dart';

import 'os_version_stub.dart' if (dart.library.io) 'os_version_io.dart';

/// The value of the `sdk_name` property on SDK-generated events.
const String kWhisperrSdkName = 'whisperr-flutter';

/// Static app and OS context attached to every SDK-generated event
/// (`app_installed`, `app_updated`, `app_opened`, `app_backgrounded`,
/// `screen_viewed`, `push_opened`).
///
/// - `app_version` / `app_build` — from the app bundle (`package_info_plus`).
/// - `platform` / `os_name` — the OS family, lowercase and equal: `ios`,
///   `android`, `web` (desktop: `macos`, `windows`, `linux`).
/// - `os_version` — the OS release (`17.4`) where Dart can read it without a
///   plugin: iOS, macOS and Windows. Android and Linux report only a kernel
///   version, so the key is omitted there.
///
/// The client adds `sdk_name` / `sdk_version`.
///
/// Only keys the platform can actually provide are returned — never a guess.
/// Locale and timezone change at runtime, so the client adds them per event.
Future<Map<String, Object?>> defaultAppContext() async {
  final out = <String, Object?>{};
  final os = osFamily();
  if (os != null) {
    out['platform'] = os;
    out['os_name'] = os;
  }
  final version = kIsWeb ? null : osVersion();
  if (version != null) out['os_version'] = version;
  try {
    final info =
        await PackageInfo.fromPlatform().timeout(const Duration(seconds: 3));
    if (info.version.trim().isNotEmpty) {
      out['app_version'] = info.version.trim();
    }
    if (info.buildNumber.trim().isNotEmpty) {
      out['app_build'] = info.buildNumber.trim();
    }
  } catch (_) {
    // No plugin / no binding (pure-Dart test, background isolate): omit.
  }
  return out;
}

/// The OS family: `web` in a browser, else the target OS, lowercase.
String? osFamily() {
  if (kIsWeb) return 'web';
  try {
    switch (defaultTargetPlatform) {
      case TargetPlatform.iOS:
        return 'ios';
      case TargetPlatform.android:
        return 'android';
      case TargetPlatform.macOS:
        return 'macos';
      case TargetPlatform.windows:
        return 'windows';
      case TargetPlatform.linux:
        return 'linux';
      case TargetPlatform.fuchsia:
        return 'fuchsia';
    }
  } catch (_) {
    return null;
  }
}

final _ianaZone = RegExp(r'^(?:UTC|[A-Za-z]+(?:/[A-Za-z0-9_+\-]+)+)$');

/// Whether [value] looks like an IANA tz database name (`Europe/Berlin`,
/// `America/Argentina/Buenos_Aires`, `UTC`), not an abbreviation (`CET`) or
/// an offset (`+04`).
bool isIanaTimezone(Object? value) =>
    value is String && _ianaZone.hasMatch(value.trim());
