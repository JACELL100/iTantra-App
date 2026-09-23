/// Version strings, in one place.
///
/// The app version is quoted in the pairing handshake and shown on the About
/// row, so a mismatched pair of builds is diagnosable from either phone. The
/// two phones must agree on [protocolVersion] or the handshake refuses the
/// link - a silent version skew between two handsets would otherwise show up
/// as garbled speech rather than as a clear failure.
library;

/// Kept in step with `version:` in pubspec.yaml.
const String appVersion = '1.0.0';

/// Wire format version. Bump only for an incompatible envelope change.
const int protocolVersion = 1;
