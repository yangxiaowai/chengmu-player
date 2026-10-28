#!/bin/bash
# Local AVPlayer exercise of the production relay; invoke under searchformoney.
set -euo pipefail
cd "$(dirname "$0")/.."
report="${1:-.build/hls-relay-validation.json}"
study_dir=$(mktemp -d "${TMPDIR:-/tmp/}chengmu-hls-study.XXXXXX")
study_server_pid=""
cleanup() {
  if [[ -n "$study_server_pid" ]]; then kill "$study_server_pid" 2>/dev/null || true; wait "$study_server_pid" 2>/dev/null || true; fi
  rm -rf "$study_dir"
}
trap cleanup EXIT
mkdir -p "$study_dir/fixture" "$(dirname "$report")"
ffmpeg -hide_banner -loglevel error -f lavfi -i 'testsrc2=size=320x180:rate=24:duration=8' -f lavfi -i 'sine=frequency=440:duration=8' \
  -c:v libx264 -preset ultrafast -pix_fmt yuv420p -g 24 -c:a aac -hls_time 1 -hls_list_size 0 \
  -hls_segment_filename "$study_dir/fixture/video-%03d.ts" "$study_dir/fixture/video.m3u8"
openssl rand -out "$study_dir/fixture/crypto.key" 16
printf 'crypto.key\n%s\n' "$study_dir/fixture/crypto.key" > "$study_dir/keyinfo.txt"
ffmpeg -hide_banner -loglevel error -f lavfi -i 'testsrc2=size=320x180:rate=24:duration=8' -f lavfi -i 'sine=frequency=440:duration=8' \
  -c:v libx264 -preset ultrafast -pix_fmt yuv420p -g 24 -c:a aac -hls_time 1 -hls_list_size 0 \
  -hls_key_info_file "$study_dir/keyinfo.txt" -hls_segment_filename "$study_dir/fixture/crypto-%03d.ts" "$study_dir/fixture/crypto.m3u8"
ffmpeg -hide_banner -loglevel error -f lavfi -i 'testsrc2=size=320x180:rate=24:duration=8' -f lavfi -i 'sine=frequency=440:duration=8' \
  -c:v libx264 -preset ultrafast -pix_fmt yuv420p -g 24 -c:a aac -hls_time 1 -hls_flags single_file -hls_list_size 0 \
  -hls_segment_filename "$study_dir/fixture/range.ts" "$study_dir/fixture/range.m3u8"
ffmpeg -hide_banner -loglevel error -f lavfi -i 'testsrc2=size=320x180:rate=24:duration=8' -f lavfi -i 'sine=frequency=440:duration=8' \
  -c:v libx264 -preset ultrafast -pix_fmt yuv420p -g 24 -c:a aac -hls_time 1 -hls_segment_type fmp4 -hls_fmp4_init_filename init.mp4 -hls_list_size 0 \
  -hls_segment_filename "$study_dir/fixture/fmp4-%03d.m4s" "$study_dir/fixture/fmp4.m3u8"
cat > "$study_dir/fixture/subs.m3u8" <<'SUBS'
#EXTM3U
#EXT-X-VERSION:3
#EXT-X-TARGETDURATION:8
#EXT-X-MEDIA-SEQUENCE:0
#EXT-X-PLAYLIST-TYPE:VOD
#EXTINF:8.000,
sub.vtt
#EXT-X-ENDLIST
SUBS
cat > "$study_dir/fixture/sub.vtt" <<'VTT'
WEBVTT
X-TIMESTAMP-MAP=LOCAL:00:00:00.000,MPEGTS:126000

00:00:00.000 --> 00:00:07.500
Subtitle retention test
VTT
for item in 'master video 3' 'aes-master crypto 3' 'range-master range 4' 'fmp4-master fmp4 7'; do
  read -r name media version <<< "$item"
  cat > "$study_dir/fixture/$name.m3u8" <<MASTER
#EXTM3U
#EXT-X-VERSION:$version
#EXT-X-MEDIA:TYPE=SUBTITLES,GROUP-ID="s",NAME="English",LANGUAGE="en",DEFAULT=YES,AUTOSELECT=YES,URI="subs.m3u8"
#EXT-X-STREAM-INF:BANDWIDTH=1500000,RESOLUTION=320x180,SUBTITLES="s"
$media.m3u8
MASTER
done
sed 's/range\.ts/bad-range.ts/g' "$study_dir/fixture/range.m3u8" > "$study_dir/fixture/bad-range.m3u8"
sed 's/range\.m3u8/bad-range.m3u8/g' "$study_dir/fixture/range-master.m3u8" > "$study_dir/fixture/bad-range-master.m3u8"
swiftc -parse-as-library -swift-version 5 -target "$(uname -m)-apple-macos15.0" \
  Sources/CinemaApp/DirectHLSRelay.swift Tests/AppModelSmoke/HLSRelayPlayerSmoke.swift -o "$study_dir/player-check"
swiftc -parse-as-library -swift-version 5 -target "$(uname -m)-apple-macos15.0" \
  Sources/CinemaApp/DirectHLSRelay.swift Tests/AppModelSmoke/HLSRelayPolicySmoke.swift -o "$study_dir/policy-check"
swiftc -parse-as-library -swift-version 5 -target "$(uname -m)-apple-macos15.0" \
  Sources/CinemaApp/DirectHLSRelay.swift Tests/AppModelSmoke/HLSRelayCancellationSmoke.swift -o "$study_dir/cancel-check"
"$study_dir/policy-check"
python3 scripts/validation/hls-direct/fixture_server.py "$study_dir" > "$study_dir/server.log" 2>&1 &
study_server_pid=$!
for attempt in {1..100}; do
  [[ -s "$study_dir/origin_url" && -s "$study_dir/origin_range_url" ]] && break
  sleep 0.05
done
[[ -s "$study_dir/origin_url" && -s "$study_dir/origin_range_url" ]]
"$study_dir/cancel-check" "$study_dir/origin_url"
"$study_dir/player-check" "$study_dir/origin_url" > "$study_dir/plain.txt"
"$study_dir/player-check" "$study_dir/origin_range_url" > "$study_dir/range.txt"
"$study_dir/player-check" "$study_dir/origin_fmp4_url" > "$study_dir/fmp4.txt"
"$study_dir/player-check" "$study_dir/origin_bad_range_url" --expect-failure > "$study_dir/bad-range.txt"
python3 - "$study_dir" "$report" <<'PY'
import json,sys
from pathlib import Path
root=Path(sys.argv[1]); out=Path(sys.argv[2])
cases={}
for name in ('plain','range','fmp4'):
    result=(root/f'{name}.txt').read_text().strip()
    required=('avplayer_ready=true','subtitle_received=true','video_frame_decoded=true','seek_succeeded=true','seek_frame_decoded=true')
    if not all(part in result for part in required): raise SystemExit('fixture failed: '+name)
    cases[name]=result
ranges=(root/'range-requests.log').read_text().splitlines() if (root/'range-requests.log').exists() else []
if not ranges: raise SystemExit('no Range requests observed')
bad_range=(root/'bad-range.txt').read_text().strip()
if 'PASS invalid_content_range_triggers_failure' not in bad_range: raise SystemExit('bad Range was not rejected')
report={'passed':True,'cases':cases,'bad_range':bad_range,'range_requests':len(ranges),
        'scope':'Production relay with local generated unsigned HLS fixtures; no real proxy routing, authentication, DRM, long playback or actual external media.'}
out.write_text(json.dumps(report,ensure_ascii=False,indent=2)+'\n')
print(json.dumps(report,ensure_ascii=False,indent=2))
PY
