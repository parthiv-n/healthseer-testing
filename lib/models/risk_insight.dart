/// Cloud-side risk insights returned by the Vitametric Partner API.
/// Fetched after a successful sync and cached locally.
class RiskInsight {
  final int hriScore;           // 0-100 (primary tier — see [abiTier])
  final String hriLabel;        // excellent | good | moderate | elevated | critical
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

  // ── ABI tier system (v4.4) ────────────────────────────────────────────
  // `abiTier` is the displayed tier: 'accumulating' | 'base' | 'comprehensive'.
  // `dataAdequacyStage` reflects baseline maturity for the tier gate:
  //   'accumulating' (< 14 days) | 'early' (14–29) | 'stable' (≥ 30).
  final String abiTier;
  final String dataAdequacyStage;
  final double? abiBaseScore;
  final String? abiBaseLabel;
  final double? abiComprehensiveScore;
  final String? abiComprehensiveLabel;
  final List<String> abiActiveMetrics;
  final List<String> abiMissingForUpgrade;

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
    this.abiTier = 'accumulating',
    this.dataAdequacyStage = 'accumulating',
    this.abiBaseScore,
    this.abiBaseLabel,
    this.abiComprehensiveScore,
    this.abiComprehensiveLabel,
    this.abiActiveMetrics = const [],
    this.abiMissingForUpgrade = const [],
  });

  bool get hasAlerts =>
      latestAnomalies.isNotEmpty ||
      (anomalyBreakdown['moderate'] ?? 0) > 0 ||
      (anomalyBreakdown['severe'] ?? 0) > 0;

  /// Value equality covering the fields that drive UI rebuilds.
  /// Mutable fields (latestAnomalies/anomalyBreakdown maps) compare by
  /// reference — sufficient because cache + live-fetch always create new
  /// maps; we never mutate in place.
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is RiskInsight &&
          runtimeType == other.runtimeType &&
          hriScore == other.hriScore &&
          hriLabel == other.hriLabel &&
          fraudRiskScore == other.fraudRiskScore &&
          fetchedAt == other.fetchedAt &&
          baselineMaturity == other.baselineMaturity &&
          daysWithData == other.daysWithData &&
          estimatedEstablishedDate == other.estimatedEstablishedDate &&
          abiTier == other.abiTier &&
          dataAdequacyStage == other.dataAdequacyStage &&
          abiBaseScore == other.abiBaseScore &&
          abiBaseLabel == other.abiBaseLabel &&
          abiComprehensiveScore == other.abiComprehensiveScore &&
          abiComprehensiveLabel == other.abiComprehensiveLabel &&
          identical(anomalyBreakdown, other.anomalyBreakdown) &&
          identical(latestAnomalies, other.latestAnomalies) &&
          identical(abiActiveMetrics, other.abiActiveMetrics) &&
          identical(abiMissingForUpgrade, other.abiMissingForUpgrade);

  @override
  int get hashCode => Object.hash(
        hriScore,
        hriLabel,
        fraudRiskScore,
        fetchedAt,
        baselineMaturity,
        daysWithData,
        estimatedEstablishedDate,
        abiTier,
        dataAdequacyStage,
        abiBaseScore,
        abiBaseLabel,
        abiComprehensiveScore,
        abiComprehensiveLabel,
      );
}
