import 'package:shared_preferences/shared_preferences.dart';

import '../services/health_service.dart';
import '../services/sync_telemetry.dart';

/// Cooldown + throttle for the auto-triggered historical-data backfill.
///
/// Both Trends and Today screens detect gaps between
/// "days in Apple Health" and "days analyzed by Vitametric" and offer
/// a one-tap "fill the gap" banner. To minimise hand-holding for users
/// with established gaps (e.g. they wore the watch for months before
/// installing Vitametric), the screens also call
/// [HistoricalGapFiller.maybeAutoFill] on load — this triggers the same
/// re-sync silently, but only when:
///
///   1. The gap is at least [minDaysGap] days (small gaps self-heal on
///      the next normal sync).
///   2. We haven't auto-triggered in the last [cooldown].
///
/// The cooldown survives app restarts via SharedPreferences so cold
/// starts don't burn cellular bandwidth on every launch.
class HistoricalGapFiller {
  static const String _kLastAutoFillKey = 'historical_gap_filler.last_auto_at_iso';
  static const Duration cooldown = Duration(hours: 12);
  static const int minDaysGap = 3;

  /// Returns the in-flight sync future when auto-fill was triggered
  /// this call, or `null` when not (gap below threshold, or cooldown
  /// active). Callers should:
  ///   * `null` — leave the manual tap-to-fill banner visible
  ///   * non-null — show the resyncing UI and `await` the future to
  ///     know when to clear it.
  ///
  /// Previously this returned `bool` and called `syncDirect` fire-and-
  /// forget. The Trends screen would set `_resyncing=true` and have no
  /// way to set it back, so the banner stayed in the resyncing state
  /// indefinitely after a single auto-fill — even after the underlying
  /// sync had long since completed. Returning the future lets the
  /// caller subscribe to completion.
  ///
  /// `gapDays` is the number of days Apple Health has but Vitametric
  /// hasn't analyzed.
  static Future<Future<SyncResult>?> maybeAutoFill(int gapDays) async {
    if (gapDays < minDaysGap) return null;

    final prefs = await SharedPreferences.getInstance();
    final lastIso = prefs.getString(_kLastAutoFillKey);
    if (lastIso != null) {
      final last = DateTime.tryParse(lastIso);
      if (last != null && DateTime.now().difference(last) < cooldown) {
        return null;
      }
    }

    // Optimistically mark "attempted" before kicking off the network
    // call so concurrent screens don't double-trigger. We update again
    // on success — failure leaves the timestamp in place which is fine,
    // it just means the next attempt waits the full cooldown.
    await prefs.setString(_kLastAutoFillKey, DateTime.now().toIso8601String());

    // Return the future so the caller can listen for completion. The
    // sync still runs concurrently with whatever the caller's UI does
    // — we just don't lose the completion signal anymore.
    return HealthService.syncDirect(
      forceFullResync: true,
      // Tag telemetry as gap-fill so the portal can split this from
      // foreground / background / historical failure rates.
      syncPath: SyncPath.gapFill,
    );
  }

  /// Reset the throttle. Useful when the user manually completes a
  /// re-sync (so a subsequent visit doesn't refire after 12h).
  static Future<void> markComplete() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kLastAutoFillKey, DateTime.now().toIso8601String());
  }
}
