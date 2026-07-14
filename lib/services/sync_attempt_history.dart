/// A small, bounded on-device log of the most recent sync attempts.
///
/// Each terminal sync (foreground, background, gap-fill, historical) appends
/// one [SyncAttemptRecord] here so the hidden Dev Tools screen can render a
/// "last N attempts" table — outcome, path, events sent, error class — without
/// needing a device console or a portal round-trip. It complements
/// [SyncStateStore], which only holds the single most-recent success/failure;
/// this keeps a rolling window of history so intermittent failures are visible.
///
/// The store is a ring buffer capped at [maxRecords]; the oldest record is
/// dropped once the cap is exceeded. Everything is best-effort: a corrupt
/// pref is treated as empty (reset), and callers append fire-and-forget so a
/// SharedPreferences failure can never break a real sync.
///
/// The serialization + cap logic is pure and directly unit-testable (see
/// test/sync_attempt_history_test.dart) via [SyncAttemptHistory.capRecords]
/// and the record's toJson/fromJson round-trip.
library;

import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// One recorded sync attempt.
@immutable
class SyncAttemptRecord {
  /// When the attempt terminated (UTC recommended).
  final DateTime at;

  /// Logical sync path, e.g. 'foreground' / 'background' / 'gap_fill'.
  final String path;

  /// Terminal outcome, e.g. 'success' / 'partial' / 'deviceLocked' / 'network'.
  final String outcome;

  /// Events sent to the server on this attempt.
  final int eventsSent;

  /// Error class name when the attempt failed, else null.
  final String? errorClass;

  const SyncAttemptRecord({
    required this.at,
    required this.path,
    required this.outcome,
    required this.eventsSent,
    this.errorClass,
  });

  Map<String, dynamic> toJson() => {
        'at': at.toIso8601String(),
        'path': path,
        'outcome': outcome,
        'events_sent': eventsSent,
        'error_class': errorClass,
      };

  /// Tolerant parse: missing / malformed fields fall back to safe defaults so
  /// a single bad record never throws the whole history load.
  factory SyncAttemptRecord.fromJson(Map<String, dynamic> j) => SyncAttemptRecord(
        at: DateTime.tryParse(j['at'] as String? ?? '') ??
            DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
        path: j['path'] as String? ?? 'other',
        outcome: j['outcome'] as String? ?? 'unknown',
        eventsSent: (j['events_sent'] as num?)?.toInt() ?? 0,
        errorClass: j['error_class'] as String?,
      );
}

/// Persistent, ring-buffered store of recent [SyncAttemptRecord]s.
class SyncAttemptHistory {
  SyncAttemptHistory._();

  /// SharedPreferences key. Versioned so a schema change can bump it.
  static const String prefsKey = 'sync_attempt_history_v1';

  /// Maximum records retained; older ones are evicted (FIFO / oldest-first).
  static const int maxRecords = 20;

  /// Pure cap: keep only the newest [maxRecords], preserving order (oldest
  /// first, newest last). Directly unit-testable without SharedPreferences.
  static List<SyncAttemptRecord> capRecords(List<SyncAttemptRecord> records) {
    if (records.length <= maxRecords) return records;
    return records.sublist(records.length - maxRecords);
  }

  /// Append a record and persist. Best-effort: swallows any error so history
  /// recording can never break a sync. Works from the background isolate too
  /// (SharedPreferences is process-local but functional there).
  static Future<void> append(SyncAttemptRecord record) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final existing = _decode(prefs.getString(prefsKey));
      final next = capRecords([...existing, record]);
      await prefs.setString(
        prefsKey,
        jsonEncode(next.map((r) => r.toJson()).toList()),
      );
    } catch (e) {
      debugPrint('[SyncAttemptHistory.append] failed (non-fatal): $e');
    }
  }

  /// Load the recorded attempts, oldest first. Returns an empty list on a
  /// missing or corrupt pref (self-heals by resetting on the next append).
  static Future<List<SyncAttemptRecord>> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return _decode(prefs.getString(prefsKey));
    } catch (e) {
      debugPrint('[SyncAttemptHistory.load] failed (non-fatal): $e');
      return const [];
    }
  }

  /// Clear all history (used by logout / clear-my-data flows and tests).
  static Future<void> clear() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(prefsKey);
    } catch (_) {/* best-effort */}
  }

  /// Decode the JSON array, tolerating corruption (returns empty on any error
  /// or non-array shape). Individual bad records are skipped.
  static List<SyncAttemptRecord> _decode(String? raw) {
    if (raw == null || raw.isEmpty) return const [];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return const [];
      final out = <SyncAttemptRecord>[];
      for (final e in decoded) {
        if (e is Map) {
          out.add(SyncAttemptRecord.fromJson(Map<String, dynamic>.from(e)));
        }
      }
      return capRecords(out);
    } catch (_) {
      // Corrupt JSON — reset to empty.
      return const [];
    }
  }
}
