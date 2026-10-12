import 'dart:ui' show PlatformDispatcher;

import 'package:flutter/widgets.dart';

/// Environment-derived defaults for the reserved identify trait keys
/// (whisperr-spec `SPEC.md` → "Reserved trait keys").
///
/// - `locale` — the platform locale as a BCP 47 tag (`de-DE`, `zh-Hans-CN`),
///   from the app's `PlatformDispatcher`. Omitted when the platform reports no
///   locale (`und`).
/// - `timezone_offset_minutes` — the device's current UTC offset in minutes,
///   east-positive (`120` for Berlin in summer). Flutter cannot obtain an IANA
///   zone name without a plugin (`DateTime.timeZoneName` is an abbreviation
///   such as `CET` or `+04`), so this documented fallback is sent instead of
///   `timezone`; pass `traits: {'timezone': 'Europe/Berlin'}` yourself when the
///   app knows the IANA name and the SDK will send that instead.
///
/// Only keys the platform can actually provide are returned — never a guess.
Map<String, Object> defaultDeviceTraits() {
  final out = <String, Object>{};
  final locale = _localeTag();
  if (locale != null) out['locale'] = locale;
  out['timezone_offset_minutes'] = DateTime.now().timeZoneOffset.inMinutes;
  return out;
}

String? _localeTag() {
  try {
    final locale = _dispatcher().locale;
    if (locale.languageCode.isEmpty || locale.languageCode == 'und') {
      return null;
    }
    final tag = locale.toLanguageTag();
    return tag.isEmpty ? null : tag;
  } catch (_) {
    return null;
  }
}

/// The binding's dispatcher honours test overrides (`localeTestValue`) and is
/// the engine's dispatcher in a running app; without a binding fall back to the
/// engine directly.
PlatformDispatcher _dispatcher() {
  try {
    return WidgetsBinding.instance.platformDispatcher;
  } catch (_) {
    return PlatformDispatcher.instance;
  }
}

final _languageTag = RegExp(r'^[A-Za-z]{2,8}(?:-[A-Za-z0-9]{1,8})*$');

/// Normalizes an app language tag to BCP 47 form: trims it and changes `_`
/// to `-` (Flutter's `Locale.toString()` gives `pt_BR`). Returns null when
/// the result is not a well-formed tag (`de`, `pt-BR`, `zh-Hant-TW`).
String? normalizeLanguageTag(String tag) {
  final normalized = tag.trim().replaceAll('_', '-');
  return _languageTag.hasMatch(normalized) ? normalized : null;
}
