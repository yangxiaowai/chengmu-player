#!/usr/bin/env python3
"""Read-only catalog + bounded, short HLS decode samples. Saves JSON, never media files."""
import argparse
import concurrent.futures
import datetime
import hashlib
import json
import re
import shutil
import subprocess
import time
import urllib.parse
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
REPORT = ROOT / 'docs/validation/representative-decode.json'
MAX_BYTES = 4 * 1024 * 1024


def now():
    return datetime.datetime.now(datetime.timezone.utc).isoformat()


def sanitize(text):
    # FFmpeg errors often echo full media URLs. Keep only the host in diagnostics.
    return re.sub(r'https?://[^\s\]\[\"\']+', lambda m: 'https://' + (urllib.parse.urlsplit(m.group()).hostname or 'redacted') + '/[path-redacted]', text)[-4000:]


def run(command, timeout=40):
    began = time.monotonic()
    try:
        completed = subprocess.run(command, capture_output=True, text=True, timeout=timeout)
        return {'exit_code': completed.returncode, 'wall_seconds': round(time.monotonic() - began, 3),
                'stdout': completed.stdout, 'stderr': sanitize(completed.stderr), 'timed_out': False}
    except subprocess.TimeoutExpired as error:
        out = error.stdout or b''
        err = error.stderr or b''
        return {'exit_code': None, 'wall_seconds': round(time.monotonic() - began, 3),
                'stdout': out.decode(errors='replace') if isinstance(out, bytes) else out,
                'stderr': sanitize(err.decode(errors='replace') if isinstance(err, bytes) else err), 'timed_out': True}


def catalog_entries(season, endpoint):
    parts = urllib.parse.urlsplit(endpoint)
    query = dict(urllib.parse.parse_qsl(parts.query))
    query.update(ac='detail', ids=season['catalog_id'])
    url = urllib.parse.urlunsplit(parts._replace(query=urllib.parse.urlencode(query)))
    request = urllib.request.Request(url, headers={'User-Agent': 'Cinema/1.0 validation'})
    with urllib.request.urlopen(request, timeout=15) as response:
        data = response.read(MAX_BYTES + 1)
        if len(data) > MAX_BYTES:
            raise ValueError('Catalog response exceeds limit')
    body = json.loads(data)
    row = next(r for r in body['list'] if str(r['vod_id']) == season['catalog_id'])
    names = row['vod_play_from'].split('$$$')
    blocks = row['vod_play_url'].split('$$$')
    index = names.index(season['line'])
    episodes = []
    for entry in blocks[index].split('#'):
        name, sep, media_url = entry.partition('$')
        parsed = urllib.parse.urlsplit(media_url)
        if not sep or parsed.scheme not in ('https', 'http') or not parsed.hostname or parsed.username:
            continue
        number = re.search(r'(?:[Ee](?:[Pp])?\s*|第\s*)(\d+)', name) or re.search(r'(\d+)', name)
        episodes.append({'episode': name, 'episode_number': int(number.group(1)) if number else None, 'url': media_url})
    episodes.sort(key=lambda e: (e['episode_number'] if e['episode_number'] is not None else 100000, e['episode']))
    positions = [('first', 0), ('middle', (len(episodes) - 1) // 2), ('last', len(episodes) - 1)]
    return [dict(season, **episodes[i], sample_position=label) for label, i in positions]


def probe_sample(entry, ffmpeg, ffprobe):
    url = entry['url']
    result = {k: v for k, v in entry.items() if k != 'url'}
    result.update(media_host=urllib.parse.urlsplit(url).hostname,
                  media_url_sha256=hashlib.sha256(url.encode()).hexdigest(), checked_at=now(),
                  seek_seconds=60, requested_decode_seconds=2)
    # Disable nested parallel HTTP connections and segment retries. Both subprocesses have watchdogs.
    transport = ['-rw_timeout', '8000000', '-max_reload', '1', '-seg_max_retry', '0', '-http_multiple', '0']
    metadata = run([ffprobe, '-v', 'error'] + transport + ['-read_intervals', '60%+2', '-i', url,
                   '-show_entries', 'stream=index,codec_type,codec_name,width,height,pix_fmt,avg_frame_rate,r_frame_rate,sample_rate,channels:format=duration', '-of', 'json'])
    result['probe'] = {k: v for k, v in metadata.items() if k != 'stdout'}
    try:
        result['streams'] = json.loads(metadata['stdout']).get('streams', [])
    except (ValueError, TypeError):
        result['streams'] = []
    decoded = run([ffmpeg, '-hide_banner', '-nostdin', '-v', 'error', '-threads', '2'] + transport +
                  ['-ss', '60', '-i', url, '-t', '2', '-map', '0:v:0', '-map', '0:a:0?', '-threads', '2',
                   '-progress', 'pipe:1', '-nostats', '-f', 'null', '-'])
    progress = dict(re.findall(r'^([a-z_]+)=(.*)$', decoded['stdout'], flags=re.MULTILINE))
    result['decode'] = {k: v for k, v in decoded.items() if k != 'stdout'}
    result['decode']['frames'] = int(progress.get('frame', '0'))
    try:
        result['decode']['output_seconds'] = int(progress.get('out_time_us', '0')) / 1000000
    except ValueError:
        result['decode']['output_seconds'] = None
    result['decode']['progress_end'] = progress.get('progress') == 'end'
    def successful(attempt):
        return attempt['exit_code'] == 0 and attempt['frames'] > 0 and attempt['progress_end'] and (attempt['output_seconds'] or 0) >= 1.9 and not attempt['stderr']
    result['fast_seek_status'] = 'decoded_sample' if metadata['exit_code'] == 0 and successful(result['decode']) else 'failed'
    result['status'] = result['fast_seek_status']
    result['effective_decode_method'] = 'seek_before_input'
    # Some discontinuous HLS playlists yield zero frames with FFmpeg's fast seek.
    # Preserve that result and attempt accurate seek by decoding/discarding the preroll.
    if metadata['exit_code'] == 0 and decoded['exit_code'] == 0 and result['decode']['frames'] == 0:
        fallback = run([ffmpeg, '-hide_banner', '-nostdin', '-v', 'error', '-threads', '2'] + transport +
                       ['-i', url, '-ss', '60', '-t', '2', '-map', '0:v:0', '-map', '0:a:0?', '-threads', '2',
                        '-progress', 'pipe:1', '-nostats', '-f', 'null', '-'])
        progress = dict(re.findall(r'^([a-z_]+)=(.*)$', fallback['stdout'], flags=re.MULTILINE))
        attempt = {k: v for k, v in fallback.items() if k != 'stdout'}
        attempt['frames'] = int(progress.get('frame', '0'))
        try:
            attempt['output_seconds'] = int(progress.get('out_time_us', '0')) / 1000000
        except ValueError:
            attempt['output_seconds'] = None
        attempt['progress_end'] = progress.get('progress') == 'end'
        result['seek_after_input_fallback'] = attempt
        if successful(attempt):
            result['status'] = 'decoded_with_seek_fallback'
            result['effective_decode_method'] = 'seek_after_input'
    return result


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--limit', type=int, help='Diagnostic limit; omitted checks all 45 representatives')
    args = parser.parse_args()
    ffmpeg, ffprobe = shutil.which('ffmpeg'), shutil.which('ffprobe')
    if not ffmpeg or not ffprobe:
        raise SystemExit('Installed ffmpeg and ffprobe required; no dependencies installed')
    source = json.loads((ROOT / 'docs/validation/source-report.json').read_text())
    version = subprocess.check_output([ffmpeg, '-version'], text=True).splitlines()[0]
    report = {'began_at': now(), 'status': 'running', 'ffmpeg_version': version,
              'scope': 'First/middle/last episode per each of 15 catalog seasons; short decode near 60 seconds',
              'maximum_parallel_samples': 2, 'network_read_timeout_microseconds': 8000000,
              'subprocess_watchdog_seconds': 40, 'catalog_response_limit_bytes': MAX_BYTES,
              'requested_decode_seconds_per_sample': 2, 'full_episode_watch_verified': False,
              'content_identity_verified': False, 'in_app_playback_verified': False,
              'media_files_saved': False, 'metadata': 'Stream dimensions/codecs are FFprobe stream metadata, not master playlist declarations; FFmpeg separately performs actual 2-second decoding',
              'limitations': ['Short samples do not prove complete or correctly labelled episodes', 'Output is decoded to null and not visually reviewed', 'Seeking includes demux/decode preroll internally; requested sample position is 60s', 'Transport bytes are not recorded and remote availability can change'],
              'catalog_failures': [], 'samples': []}
    work = []
    for season in source['seasons']:
        try:
            work.extend(catalog_entries(season, source['endpoint']))
        except Exception as error:
            report['catalog_failures'].append({'catalog_id': season['catalog_id'], 'error': type(error).__name__})
    if args.limit:
        work = work[:args.limit]
    report['expected_samples'] = 45
    report['scheduled_samples'] = len(work)
    indexed = {}
    def save():
        report['samples'] = [indexed[i] for i in sorted(indexed)]
        report['samples_checked'] = len(report['samples'])
        report['fast_seek_samples_decoded'] = sum(e.get('fast_seek_status', e['status']) == 'decoded_sample' for e in report['samples'])
        report['seek_fallback_samples_decoded'] = sum(e['status'] == 'decoded_with_seek_fallback' for e in report['samples'])
        report['samples_decoded'] = sum(e['status'] in ('decoded_sample', 'decoded_with_seek_fallback') for e in report['samples'])
        temp = REPORT.with_suffix('.json.tmp')
        temp.write_text(json.dumps(report, ensure_ascii=False, indent=2) + '\n')
        temp.replace(REPORT)
    save()
    with concurrent.futures.ThreadPoolExecutor(max_workers=2) as executor:
        futures = {executor.submit(probe_sample, entry, ffmpeg, ffprobe): i for i, entry in enumerate(work)}
        for future in concurrent.futures.as_completed(futures):
            i = futures[future]
            try:
                indexed[i] = future.result()
            except Exception as error:
                indexed[i] = {k: v for k, v in work[i].items() if k != 'url'} | {'status': 'failed', 'error': type(error).__name__}
            save()
            entry = indexed[i]
            print(f"{len(indexed)}/{len(work)} {entry['series']} {entry['catalog_id']} {entry['episode']}: {entry['status']}", flush=True)
    report['ended_at'] = now()
    report['status'] = 'finished'
    save()
    print(f"Decoded {report['samples_decoded']}/{report['samples_checked']} samples; report {REPORT}", flush=True)


if __name__ == '__main__':
    main()
