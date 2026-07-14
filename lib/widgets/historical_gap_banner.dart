import 'package:flutter/material.dart';

import '../services/health_service.dart';

/// Tappable banner shown when Apple Health has more days of data than
/// Vitametric has analyzed. Tapping triggers a chunked historical
/// re-sync via the parent's `onTap` callback; while the sync is in
/// flight `resyncing` is true and the banner switches to a progress
/// state in place — including the live "Week N of M" label from
/// [HealthService.historicalSyncProgress].
///
/// Used by both Trends and Today screens so the affordance looks the
/// same wherever a gap is detected.
class HistoricalGapBanner extends StatelessWidget {
  final int gapDays;
  final bool resyncing;
  final VoidCallback? onTap;

  const HistoricalGapBanner({
    super.key,
    required this.gapDays,
    this.resyncing = false,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: const Color(0xFFEFF6FF),
      borderRadius: BorderRadius.circular(10),
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: (resyncing || onTap == null) ? null : onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: const Color(0xFFBFDBFE)),
          ),
          child: Row(
            children: [
              Icon(
                resyncing ? Icons.sync : Icons.cloud_download_outlined,
                size: 16,
                color: const Color(0xFF3B82F6),
              ),
              const SizedBox(width: 10),
              // When idle, show the gap count + tap affordance. When
              // resyncing, show the live "Week N of M" progress label so
              // the user has a concrete sense of remaining work — the old
              // copy "this can take a minute" was a lie for big gaps and
              // gave the user nothing to look at while waiting.
              Expanded(
                child: resyncing
                    ? ValueListenableBuilder<String?>(
                        valueListenable: HealthService.historicalSyncProgress,
                        builder: (context, progress, _) {
                          final body = progress != null
                              ? 'Backfilling $gapDays day${gapDays == 1 ? '' : 's'} from Apple Health · $progress'
                              : 'Backfilling $gapDays day${gapDays == 1 ? '' : 's'} from Apple Health…';
                          return Text(
                            body,
                            style: const TextStyle(fontSize: 12, color: Color(0xFF1E40AF), height: 1.4),
                          );
                        },
                      )
                    : Text(
                        "$gapDays day${gapDays == 1 ? '' : 's'} in Apple Health haven't been analyzed yet. Tap to fill the gap.",
                        style: const TextStyle(fontSize: 12, color: Color(0xFF1E40AF), height: 1.4),
                      ),
              ),
              if (!resyncing)
                const Icon(Icons.chevron_right, size: 18, color: Color(0xFF3B82F6)),
              if (resyncing)
                const SizedBox(
                  width: 14, height: 14,
                  child: CircularProgressIndicator(strokeWidth: 2, color: Color(0xFF3B82F6)),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
