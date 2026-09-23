import 'dart:async';

import 'package:flutter/services.dart';

import '../core/util/async.dart';

/// The app's haptic vocabulary.
///
/// The brief's own words: an audio-first user must be able to tell whether the
/// app is listening, sending, delivered, played or failed, *without* reading
/// text or interpreting a colour. Text and colour are both useless to someone
/// holding the phone at their side in the dark, which is exactly how this gets
/// used. So every outcome gets a distinct pattern rather than "a buzz", and the
/// patterns are ordered by how much they need to interrupt:
///
/// | Pattern | Feels like | Means |
/// |---|---|---|
/// | [press] | one firm tap | the floor is yours, start talking |
/// | [release] | one soft tap | speech ended, working on it |
/// | [sent] | a small tick | it left this phone |
/// | [delivered] | two quick ticks | the other phone stored it |
/// | [warning] | one hard knock | a warning arrived |
/// | [alert] | three hard knocks | a distress message arrived |
/// | [failure] | three fast knocks | something went wrong; act |
///
/// Three hard knocks for a distress alert is not a stylistic choice: it is the
/// pattern people already recognise from public-warning systems, and inventing
/// a novel one would mean it has to be learned.
enum Haptic {
  press,
  release,
  sent,
  delivered,
  warning,
  alert,
  failure,
}

/// Fires the patterns, and lets the user turn them off.
///
/// The switch matters more here than in most apps. This phone may be carried
/// somewhere that being noticed is dangerous, and a walkie-talkie that buzzes
/// on every received message is one people disable by muting the phone - which
/// also silences the alert they were relying on.
class Haptics {
  const Haptics._();

  static bool enabled = true;

  static Future<void> fire(Haptic pattern) async {
    if (!enabled) return;
    try {
      switch (pattern) {
        case Haptic.press:
          await HapticFeedback.mediumImpact();
        case Haptic.release:
          await HapticFeedback.lightImpact();
        case Haptic.sent:
          await HapticFeedback.selectionClick();
        case Haptic.delivered:
          // Two ticks, deliberately not one: a single tick is what "sent" uses,
          // and telling them apart is the entire point of the vocabulary.
          await HapticFeedback.lightImpact();
          await _pause();
          await HapticFeedback.selectionClick();
        case Haptic.warning:
          await HapticFeedback.heavyImpact();
        case Haptic.alert:
          await _knocks(3, const Duration(milliseconds: 170));
        case Haptic.failure:
          await _knocks(3, const Duration(milliseconds: 90));
      }
    } on PlatformException {
      // No vibrator, or the OS refused while another app holds it. A missing
      // haptic must never take down the message that triggered it.
    }
  }

  static Future<void> _knocks(int count, Duration gap) async {
    for (int i = 0; i < count; i++) {
      await HapticFeedback.heavyImpact();
      if (i < count - 1) await Future<void>.delayed(gap);
    }
  }

  static Future<void> _pause() =>
      Future<void>.delayed(const Duration(milliseconds: 110));

  /// Fire and forget, for the call sites that are already in a callback that
  /// cannot be made asynchronous.
  static void fireAndForget(Haptic pattern) => unawaited(fire(pattern));
}
