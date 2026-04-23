/// Cloud-side risk insights returned by the LifePulse Partner API.
/// Fetched after a successful sync and cached locally.
class RiskInsight {
  final int hriScore;           // 0-100
  final String hriLabel;        // low | moderate | high | critical
  final Map<String, int> anomalyBreakdown;  // mild/moderate/severe → count
  final List<Map<String, dynamic>> latestAnomalies; // up to 3 recent alerts
  // fraudRiskScore is an insurer-side actuarial signal — NEVER display this
  // to the member. It is retained here only for schema compatibility with the
  // backend response; it must not be surfaced in any member-facing UI widget.
  final double? fraudRiskScore;
  final DateTime fetchedAt;

  // Baseline maturity — drives cold-start UX messaging
  final String baselineMaturity;        // cold_start | developing | established
  final int daysWithData;               // distinct calendar days synced so far
  final String? estimatedEstablishedDate; // ISO-8601 date when HRI will fully activate

  const RiskInsight({
    required this.hriScore,
    required this.hriLabel,
    required this.anomalyBreakdown,
    required this.latestAnomalies,
    this.fraudRiskScore,
    required this.fetchedAt,
    this.baselineMaturity = 'cold_start',
    this.daysWithData = 0,
    this.estimatedEstablishedDate,
  });

  bool get hasAlerts =>
      latestAnomalies.isNotEmpty ||
      (anomalyBreakdown['moderate'] ?? 0) > 0 ||
      (anomalyBreakdown['severe'] ?? 0) > 0;
}
