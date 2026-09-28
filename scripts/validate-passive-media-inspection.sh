#!/bin/bash
# Guards the passive-inspection contract: the application must never use AVFoundation's deprecated
# synchronous accessors, which perform blocking loads on a network asset and can break the very
# playback they describe. Network sources (非凡, 魔都, 无尽) failed to start while these were used.
set -euo pipefail
cd "$(dirname "$0")/.."

patterns=(
  '\.asset\.tracks'
  '\.asset\.duration'
  '\.asset\.isPlayable'
  '\.asset\.preferredTransform'
  '\.asset\.track\(withTrackID'
  '\.asset\.mediaSelectionGroup'
)
violations=0
for pattern in "${patterns[@]}"; do
  while IFS= read -r hit; do
    [[ -z "$hit" ]] && continue
    echo "FORBIDDEN synchronous asset access: $hit" >&2
    violations=$((violations + 1))
  done < <(grep -rn --include='*.swift' -E "$pattern" Sources/CinemaApp | grep -v 'loadTracks' || true)
done

# The awaited forms are the supported API and must be what the app uses instead.
for required in 'loadTracks(withMediaType' 'loadMediaSelectionGroup'; do
  if ! grep -rq --include='*.swift' -- "$required" Sources/CinemaApp; then
    echo "MISSING expected asynchronous accessor: $required" >&2
    violations=$((violations + 1))
  fi
done

if [[ "$violations" -gt 0 ]]; then
  echo "FAILED: $violations blocking-accessor violation(s)" >&2
  exit 1
fi
echo "PASS: application code uses only asynchronous AVFoundation accessors"
