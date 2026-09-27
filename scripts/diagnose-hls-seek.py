#!/usr/bin/env python3
"""Supplement failed representative seeks without changing their original results."""
import concurrent.futures
import importlib.util
import json
import re
import shutil
import urllib.parse
import urllib.request
from pathlib import Path

HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location('representative', HERE / 'representative-decode.py')
r = importlib.util.module_from_spec(spec)
spec.loader.exec_module(r)


def fetch_text(url):
    request = urllib.request.Request(url, headers={'User-Agent': 'Cinema/1.0 validation'})
    with urllib.request.urlopen(request, timeout=8) as response:
        data = response.read(2 * 1024 * 1024 + 1)
        if len(data) > 2 * 1024 * 1024:
            raise ValueError('Playlist size limit')
        return data.decode('utf-8-sig'), response.url


def media_playlist(url):
    seen = set()
    for _ in range(5):
        if url in seen:
            raise ValueError('Master loop')
        seen.add(url)
        text, final_url = fetch_text(url)
        lines = [s.strip() for s in text.splitlines() if s.strip()]
        if lines[0] != '#EXTM3U':
            raise ValueError('Invalid HLS header')
        variants = []
        for i, line in enumerate(lines[:-1]):
            if line.startswith('#EXT-X-STREAM-INF:'):
                dimensions = re.search(r'RESOLUTION=(\d+)x(\d+)', line)
                area = int(dimensions[1]) * int(dimensions[2]) if dimensions else 0
                variants.append((area, urllib.parse.urljoin(final_url, lines[i+1])))
        if variants:
            url = sorted(variants, reverse=True)[0][1]
            continue
        segments, duration, pending, discontinuities = [], 0.0, None, 0
        for line in lines[1:]:
            if line.startswith('#EXTINF:'):
                pending = float(line[8:].split(',')[0])
            elif line == '#EXT-X-DISCONTINUITY':
                discontinuities += 1
            elif not line.startswith('#') and pending is not None:
                segments.append({'url': urllib.parse.urljoin(final_url, line), 'start_seconds': duration,
                                 'duration_seconds': pending, 'preceding_discontinuities': discontinuities})
                duration += pending
                pending = None
        return segments, {'declared_duration_seconds': duration, 'segment_count': len(segments),
                          'discontinuity_count': discontinuities, 'endlist': '#EXT-X-ENDLIST' in lines}
    raise ValueError('Master depth')


def progress_result(value):
    values = dict(re.findall(r'^([a-z_]+)=(.*)$', value.pop('stdout'), flags=re.MULTILINE))
    value['frames'] = int(values.get('frame', '0'))
    try:
        value['output_seconds'] = int(values.get('out_time_us', '0')) / 1000000
    except ValueError:
        value['output_seconds'] = None
    value['progress_end'] = values.get('progress') == 'end'
    return value


def diagnose(entry):
    url = entry['url']
    result = {k: v for k, v in entry.items() if k != 'url'}
    result['checked_at'] = r.now()
    segments, metadata = media_playlist(url)
    target = next(s for s in segments if s['start_seconds'] <= 60 < s['start_seconds'] + s['duration_seconds'])
    result['playlist'] = metadata
    result['selected_segment'] = {k: v for k, v in target.items() if k != 'url'}
    result['selected_segment']['media_host'] = urllib.parse.urlsplit(target['url']).hostname
    transport = ['-rw_timeout', '8000000']
    common = [shutil.which('ffmpeg'), '-hide_banner', '-nostdin', '-v', 'error', '-threads', '2']
    output = ['-t', '2', '-map', '0:v:0', '-map', '0:a:0?', '-threads', '2', '-progress', 'pipe:1', '-nostats', '-f', 'null', '-']
    for label, segment_url in [('first_segment', segments[0]['url']), ('segment_covering_60s', target['url'])]:
        probe = r.run([shutil.which('ffprobe'), '-v', 'error'] + transport + ['-read_intervals', '%+2', '-i', segment_url,
                     '-show_entries', 'stream=codec_type,codec_name,width,height,avg_frame_rate,start_time,sample_rate,channels:format=start_time,duration', '-of', 'json'])
        data = json.loads(probe.pop('stdout') or '{}')
        result[label] = {'probe': probe, 'metadata': data,
                        'decode': progress_result(r.run(common + transport + ['-i', segment_url] + output))}
    hls_transport = transport + ['-max_reload', '1', '-seg_max_retry', '0', '-http_multiple', '0']
    result['hls_seek_after_input'] = progress_result(r.run(common + hls_transport + ['-i', url, '-ss', '60'] + output))
    result['hls_start_sample'] = progress_result(r.run(common + hls_transport + ['-i', url] + output))
    print(f"Diagnosed {entry['episode']}", flush=True)
    return result


def main():
    source = json.loads((r.ROOT / 'docs/validation/source-report.json').read_text())
    season = next(s for s in source['seasons'] if s['catalog_id'] == '72633')
    entries = [e for e in r.catalog_entries(season, source['endpoint']) if e['sample_position'] in ('first', 'last')]
    output = {'began_at': r.now(), 'scope': 'Stranger Things S5 first and last representative failed-seek diagnosis',
              'network_read_timeout_seconds': 8, 'subprocess_watchdog_seconds': 40, 'maximum_parallel_samples': 2,
              'media_files_saved': False, 'identity_visually_verified': False, 'results': []}
    with concurrent.futures.ThreadPoolExecutor(max_workers=2) as executor:
        for result in executor.map(diagnose, entries):
            output['results'].append(result)
    output['ended_at'] = r.now()
    output['limits'] = ['Direct segment sample covers a declared HLS timeline near 60s but does not establish exact content position', 'Full episodes not watched', 'Original representative failures remain unchanged']
    path = r.ROOT / 'docs/validation/representative-decode.json'
    report = json.loads(path.read_text())
    report['failed_seek_diagnosis'] = output
    path.write_text(json.dumps(report, ensure_ascii=False, indent=2) + '\n')
    print('Supplemental diagnosis saved', flush=True)


if __name__ == '__main__':
    main()
