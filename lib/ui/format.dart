/// Shared formatting, so the same number is never rendered two different ways
/// on two different screens.
library;

/// Whole-second time for a transcript row: "14:32".
String clockTime(int epochMs) {
  final DateTime at = DateTime.fromMillisecondsSinceEpoch(epochMs);
  return '${at.hour.toString().padLeft(2, '0')}:'
      '${at.minute.toString().padLeft(2, '0')}';
}

/// Day and time, for anything older than today: "12 Sep · 14:32".
String dayAndTime(int epochMs) {
  const List<String> months = <String>[
    'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
    'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
  ];
  final DateTime at = DateTime.fromMillisecondsSinceEpoch(epochMs);
  return '${at.day} ${months[at.month - 1]} · ${clockTime(epochMs)}';
}

/// True when two timestamps fall on different calendar days.
bool isDifferentDay(int aMs, int bMs) {
  final DateTime a = DateTime.fromMillisecondsSinceEpoch(aMs);
  final DateTime b = DateTime.fromMillisecondsSinceEpoch(bMs);
  return a.year != b.year || a.month != b.month || a.day != b.day;
}

/// A compact human age: "just now", "4 min", "2 h", "3 d".
String relativeAge(int epochMs, {int? nowMs}) {
  final int now = nowMs ?? DateTime.now().millisecondsSinceEpoch;
  final int seconds = ((now - epochMs) / 1000).round();
  if (seconds < 45) return 'just now';
  if (seconds < 3600) return '${(seconds / 60).round()} min';
  if (seconds < 86400) return '${(seconds / 3600).round()} h';
  return '${(seconds / 86400).round()} d';
}

/// Byte sizes for model packs. Decimal MB would flatter a 420 MB pack into
/// "400 MB"; binary is what the storage settings screen shows, so binary it is.
String bytes(int count) {
  if (count >= 1024 * 1024 * 1024) {
    return '${(count / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
  }
  if (count >= 1024 * 1024) {
    return '${(count / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
  if (count >= 1024) return '${(count / 1024).toStringAsFixed(0)} KB';
  return '$count B';
}

/// A latency, with the precision that actually matters at each scale.
///
/// Sub-10 ms values get two decimals because that is where a regression is
/// visible; above 1 s a decimal place is noise nobody can act on.
String millis(double value) {
  if (value >= 1000) return '${(value / 1000).toStringAsFixed(2)} s';
  if (value >= 10) return '${value.toStringAsFixed(0)} ms';
  return '${value.toStringAsFixed(1)} ms';
}

/// A bare number for a table cell, without a unit.
String compactNumber(double value) {
  if (value >= 1000) return (value / 1000).toStringAsFixed(1);
  if (value >= 10) return value.toStringAsFixed(0);
  return value.toStringAsFixed(2);
}

/// Real-time factor, displayed as "0.42×". Below 1.0 is faster than real time.
String realTimeFactor(double value) => '${value.toStringAsFixed(2)}×';

/// Percentage from a 0..1 fraction.
String percent(double fraction, {int decimals = 0}) =>
    '${(fraction * 100).toStringAsFixed(decimals)}%';
