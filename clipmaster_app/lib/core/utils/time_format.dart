/// Format seconds as MM:SS for timeline display.
String formatTimeMMSS(double seconds) {
  final m = (seconds ~/ 60).toString().padLeft(2, '0');
  final s = (seconds.toInt() % 60).toString().padLeft(2, '0');
  return '$m:$s';
}
