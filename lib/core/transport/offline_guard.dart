import 'dart:io';

/// Enforces the "fully offline" requirement at the socket layer.
///
/// A code review can promise there is no cloud call; this makes it structural.
/// Every socket the app opens goes through [requireLinkLocal] first, so a
/// future contributor who adds an analytics SDK or a model-download URL gets
/// an exception on a bench instead of a disqualification at evaluation.
///
/// Permitted destinations are the address ranges a phone-to-phone or
/// phone-to-ESP32 link can actually use:
///   127.0.0.0/8     loopback (self-test only)
///   169.254.0.0/16  link-local, what Wi-Fi Direct hands out
///   10.0.0.0/8      private
///   172.16.0.0/12   private (Wi-Fi Direct groups often land here)
///   192.168.0.0/16  private, soft AP and most home routers
class OfflineViolation implements Exception {
  OfflineViolation(this.message);
  final String message;
  @override
  String toString() => 'OfflineViolation: $message';
}

class OfflineGuard {
  const OfflineGuard({this.allowLoopback = true});

  /// Loopback is allowed in debug and test builds for the in-process
  /// self-test, and can be switched off for a hardened build.
  final bool allowLoopback;

  /// Throws unless [address] is a literal IPv4 address in a local range.
  ///
  /// Hostnames are rejected outright rather than resolved: a DNS lookup is
  /// itself network activity, and any hostname in this app would be a bug.
  void requireLinkLocal(String address) {
    final InternetAddress? parsed = InternetAddress.tryParse(address);
    if (parsed == null) {
      throw OfflineViolation(
        'refusing to resolve "$address": only literal local IPv4 addresses '
        'are allowed, and a hostname would require DNS',
      );
    }
    if (parsed.type != InternetAddressType.IPv4) {
      throw OfflineViolation(
        'refusing non-IPv4 address "$address"; local links are IPv4 here',
      );
    }
    if (!isPermitted(parsed)) {
      throw OfflineViolation(
        '"$address" is outside the local ranges this app may contact',
      );
    }
  }

  bool isPermitted(InternetAddress address) {
    if (address.type != InternetAddressType.IPv4) return false;
    final List<int> b = address.rawAddress;
    if (b.length != 4) return false;

    if (b[0] == 127) return allowLoopback;
    if (b[0] == 169 && b[1] == 254) return true;
    if (b[0] == 10) return true;
    if (b[0] == 172 && b[1] >= 16 && b[1] <= 31) return true;
    if (b[0] == 192 && b[1] == 168) return true;
    return false;
  }

  /// Convenience for the diagnostics screen.
  bool isPermittedString(String address) {
    final InternetAddress? parsed = InternetAddress.tryParse(address);
    return parsed != null && isPermitted(parsed);
  }
}
