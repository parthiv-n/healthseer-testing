/// Cloud-side risk insights returned by the LifePulse Partner API.
/// Fetched after a successful sync and cached locally.
class RiskInsight {
  final int hriScore;           // 0-100
  final String hriLabel;        // low | moderate | high | critical
  final Map<String, int> anomalyBreakdown;  // mild/moderate/severe → count
  final List<Map<String, dynamic>> latestAnomalies; // up to 3 recent alerts
  final double? fraudRiskScore;  // 0.0-1.0 from most recent sync
  final DateTime fetchedAt;

  const RiskInsight({
    required this.hriScore,
    required this.hriLabel,
    required this.anomalyBreakdown,
    required this.latestAnomalies,
    this.fraudRiskScore,
    required this.fetchedAt,
  });

  String get fraudRiskLabel {
    if (fraudRiskScore == null) return 'Unknown';
    if (fraudRiskScore! < 0.3) return 'Low';
    if (fraudRiskScore! < 0.6) return 'Medium';
    return 'High';
  }

  bool get hasAlerts =>
      latestAnomalies.isNotEmpty ||
      (anomalyBreakdown['moderate'] ?? 0) > 0 ||
      (anomalyBreakdown['severe'] ?? 0) > 0;
}
