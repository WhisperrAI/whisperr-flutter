import 'dart:io' show Platform;

/// The OS release, from `Platform.operatingSystemVersion`, where it names one.
String? osVersion() {
  try {
    return parseOsVersion(
        Platform.operatingSystem, Platform.operatingSystemVersion);
  } catch (_) {
    return null;
  }
}

/// Extracts the release from a `Platform.operatingSystemVersion` string.
///
/// - iOS / macOS: `Version 17.4 (Build 21E213)` → `17.4`.
/// - Windows: `"Windows 10 Pro" 10.0 (Build 19045)` → `10.0.19045`.
/// - Android / Linux: the string is the kernel (`uname`), not the OS release,
///   so this returns null rather than a misleading value.
String? parseOsVersion(String os, String raw) {
  switch (os) {
    case 'ios':
    case 'macos':
      final m = RegExp(r'Version\s+(\d+(?:\.\d+)*)').firstMatch(raw);
      return m?.group(1);
    case 'windows':
      final m = RegExp(r'(\d+\.\d+)\s*\(Build\s+(\d+)\)').firstMatch(raw);
      return m == null ? null : '${m.group(1)}.${m.group(2)}';
    default:
      return null;
  }
}
