import 'log.dart';

/// Fire-and-forget, with the failure visible in the log.
///
/// `dart:async`'s own `unawaited` states the intent but swallows nothing: an
/// error still escapes to the zone handler. Here it is deliberate that a
/// background task's failure is logged and not thrown, because these are all
/// cases - haptics, a window-size notification, tearing down a subscription
/// that is already gone - where failing loudly would be worse than the failure.
///
/// The one rule: never use this for something whose result is needed. If the
/// caller needs the value, it must await.
void unawaited(Future<void>? future) {
  if (future == null) return;
  future.then<void>((_) {}, onError: (Object error, StackTrace stack) {
    ItLog.w('async', 'background task failed: $error');
  });
}

/// No-op for a synchronous callback slot that expects a `void`.
void noop() {}
