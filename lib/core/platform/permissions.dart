import 'package:permission_handler/permission_handler.dart';

import '../util/log.dart';

/// Outcome of asking for one capability.
enum PermissionOutcome {
  granted,

  /// Refused this time; asking again is reasonable.
  denied,

  /// Refused permanently. The only way forward is the system settings screen,
  /// and nagging with a dialog is exactly what a user who has already said no
  /// does not need.
  permanentlyDenied,

  /// The device has no such hardware, or the platform does not use this
  /// permission at all.
  notApplicable,
}

/// A capability the app might need, described once.
enum AppPermission {
  microphone(
    label: 'Microphone',
    rationale:
        'Speech is recognised on this phone and never uploaded. Without the '
        'microphone you can still receive and read messages, and send typed '
        'ones.',
  ),
  notifications(
    label: 'Notifications',
    rationale:
        'Shows a single persistent notice while a session is running, so it is '
        'obvious when the microphone is live.',
  ),
  nearbyDevices(
    label: 'Nearby devices',
    rationale:
        'Used to find and pair the other phone over Wi-Fi or Bluetooth. This '
      'app never contacts anything outside the local network.',
  ),
  camera(
    label: 'Camera',
    rationale: 'Used only to scan a pairing code. The camera image is never '
        'stored or uploaded.',
  );

  const AppPermission({required this.label, required this.rationale});

  final String label;
  final String rationale;
}

/// Asks for permissions, one at a time and only when a feature is used.
///
/// The rule this class enforces is that a permission is never requested at
/// launch. A user who has not yet decided to start a session has no context for
/// why the app wants their microphone, and asking early is how apps teach
/// people to refuse.
class Permissions {
  const Permissions._();

  /// The permission object for each capability, or null where the platform has
  /// no equivalent. iOS has no nearby-devices permission: local network access
  /// is granted per-app by the OS the first time a local socket is opened, and
  /// the only thing the app declares is the usage string in Info.plist.
  static Permission? _native(AppPermission permission) {
    switch (permission) {
      case AppPermission.microphone:
        return Permission.microphone;
      case AppPermission.notifications:
        return Permission.notification;
      case AppPermission.nearbyDevices:
        return Permission.nearbyWifiDevices;
      case AppPermission.camera:
        return Permission.camera;
    }
  }

  static Future<PermissionOutcome> status(AppPermission permission) async {
    final Permission? native = _native(permission);
    if (native == null) return PermissionOutcome.notApplicable;
    try {
      return _map(await native.status);
    } on Object catch (error) {
      // A permission that does not exist on this platform throws rather than
      // returning a status. Treated as "not applicable" rather than an error,
      // because nothing the user can do would change it.
      ItLog.w('permissions', '${permission.name} unavailable: $error');
      return PermissionOutcome.notApplicable;
    }
  }

  static Future<PermissionOutcome> request(AppPermission permission) async {
    final Permission? native = _native(permission);
    if (native == null) return PermissionOutcome.notApplicable;
    try {
      return _map(await native.request());
    } on Object catch (error) {
      ItLog.w('permissions', '${permission.name} request failed: $error');
      return PermissionOutcome.notApplicable;
    }
  }

  /// Opens the system settings page for this app, for a permission the user
  /// has already refused permanently.
  static Future<bool> openSettings() => openAppSettings();

  static PermissionOutcome _map(PermissionStatus status) {
    if (status.isGranted || status.isLimited || status.isProvisional) {
      return PermissionOutcome.granted;
    }
    if (status.isPermanentlyDenied || status.isRestricted) {
      return PermissionOutcome.permanentlyDenied;
    }
    return PermissionOutcome.denied;
  }
}
