/// Shared time formatting utilities used across multiple screens.
String relativeTime(DateTime dt) {
  final diff = DateTime.now().difference(dt);
  // Guard against future timestamps (clock skew, bad server data).
  if (diff.isNegative) return 'just now';
  if (diff.inMinutes < 2) return 'just now';
  if (diff.inMinutes < 60) return '${diff.inMinutes}m ago';
  if (diff.inHours < 24) return '${diff.inHours}h ago';
  if (diff.inDays == 1) return 'yesterday';
  return '${diff.inDays} days ago';
}
