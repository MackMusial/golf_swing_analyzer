/// Finds the moment the club strikes the ball from the video's soundtrack.
///
/// The strike is a sharp click, so it shows up as a short burst of
/// high-frequency energy far above the background. Native code turns the audio
/// into an [AudioEnvelope] (click energy per few milliseconds); this file
/// picks the strike out of it.
library;

/// Click energy over time: mean squared sample-to-sample change per hop.
/// That high-passes the audio, so clicks stand out over wind and voices.
class AudioEnvelope {
  final int startMs;
  final double hopMs;
  final List<double> values;

  const AudioEnvelope({
    required this.startMs,
    required this.hopMs,
    required this.values,
  });

  double timeOf(int i) => startMs + i * hopMs;
  int indexOf(num timeMs) => ((timeMs - startMs) / hopMs).floor();
}

/// How far above the background a click must be to count as a strike.
/// Real strikes measure in the thousands; wind gusts and voices stay well under.
const strikeMinRatio = 40.0;

/// Time (ms) the strike starts, or null if there's no clear strike between
/// [fromMs] and [toMs]. When several clicks qualify (say, the next bay at a
/// driving range), the one nearest [expectedMs] wins.
int? findStrikeMs(
  AudioEnvelope env, {
  required int fromMs,
  required int toMs,
  required int expectedMs,
}) {
  final v = env.values;
  if (v.length < 10) return null;

  final sorted = [...v]..sort();
  final peakAll = sorted.last;
  if (peakAll <= 0) return null; // silent track
  // Floor the background so digital silence doesn't make any blip a "strike".
  final background = sorted[sorted.length ~/ 2].clamp(peakAll * 1e-5, double.infinity);
  final threshold = background * strikeMinRatio;

  final lo = env.indexOf(fromMs).clamp(1, v.length - 2);
  final hi = env.indexOf(toMs).clamp(1, v.length - 2);
  final mergeHops = (60 / env.hopMs).ceil(); // one click rings for a few ms

  int? best;
  for (var i = lo; i <= hi; i++) {
    if (v[i] < threshold || v[i] < v[i - 1] || v[i] < v[i + 1]) continue;
    // Keep only the loudest point of each burst.
    var isBurstPeak = true;
    for (var j = i - mergeHops; j <= i + mergeHops; j++) {
      if (j >= 0 && j < v.length && v[j] > v[i]) {
        isBurstPeak = false;
        break;
      }
    }
    if (!isBurstPeak) continue;
    if (best == null ||
        (env.timeOf(i) - expectedMs).abs() < (env.timeOf(best) - expectedMs).abs()) {
      best = i;
    }
  }
  if (best == null) return null;

  // Report the start of the click, not its loudest point.
  var onset = best;
  while (onset > 0 && v[onset - 1] >= v[best] * 0.2) {
    onset--;
  }
  return env.timeOf(onset).round();
}
