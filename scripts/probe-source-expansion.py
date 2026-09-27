#!/usr/bin/env python3
"""Bounded public CMS/HLS checks. Only JSON evidence is saved; media stays in memory.

Run after the web-access skill preflight. Requires installed curl 8.4+, FFmpeg,
and FFprobe. No cookies, login, keys, DRM, referer spoofing, or access bypass.
"""
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
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
LIMIT = 2 * 1024 * 1024
SOURCES = {
    'ruyi': ('如意目录', 'https://cj.rycjapi.com/api.php/provide/vod'),
    'mdzy': ('魔都目录', 'https://www.mdzyapi.com/api.php/provide/vod'),
    'guangsu': ('光速目录', 'https://api.guangsuapi.com/api.php/provide/vod'),
    'hongniu': ('红牛目录', 'https://www.hongniuzy2.com/api.php/provide/vod'),
    'haohua': ('豪华目录', 'https://hhzyapi.com/api.php/provide/vod'),
    'wujin': ('无尽目录', 'https://api.wujinapi.com/api.php/provide/vod'),
    'baofeng': ('暴风目录', 'https://bfzyapi.com/api.php/provide/vod'),
    'maoyan': ('猫眼目录', 'https://api.maoyanapi.top/api.php/provide/vod'),
}
SAMPLES = [
    ('movie', '流浪地球', ['科幻片']),
    ('chinese_series', '琅琊榜', ['国产剧', '大陆剧', '内地剧']),
    ('overseas_series', '怪奇物语第一季', ['欧美剧', '美国剧']),
    ('animation', '火影忍者', ['日韩动漫', '日本动漫']),
]


def now():
    return datetime.datetime.now(datetime.timezone.utc).isoformat()


def digest(data):
    return hashlib.sha256(data).hexdigest()


def valid_url(value):
    p = urllib.parse.urlsplit(value)
    if p.scheme not in ('http', 'https') or not p.hostname or p.username or p.password:
        raise ValueError('Invalid public HTTP(S) URL')
    return value


def fetch(url, byte_range=False):
    valid_url(url)
    marker = b'\n__CINEMA_HTTP_METADATA__'
    command = ['curl', '--silent', '--show-error', '--location', '--fail',
               '--proto', '=http,https', '--proto-redir', '=http,https',
               '--connect-timeout', '5', '--max-time', '12', '--max-redirs', '4',
               '--max-filesize', str(LIMIT), '--user-agent', 'Cinema/1.0',
               '--write-out', marker.decode() + '%{json}']
    if byte_range:
        command += ['--range', f'0-{LIMIT - 1}']
    began = time.monotonic()
    p = subprocess.run(command + [url], capture_output=True, timeout=15)
    body, found, raw_metadata = p.stdout.rpartition(marker)
    if not found:
        raise ValueError(f'curl did not return metadata, exit {p.returncode}')
    meta = json.loads(raw_metadata)
    if p.returncode:
        raise ValueError(f'HTTP {meta.get("http_code")} curl exit {p.returncode}')
    if len(body) > LIMIT:
        raise ValueError('Response exceeded byte limit')
    valid_url(meta['url_effective'])
    return body, {'url': url, 'final_url': meta['url_effective'],
                  'http_status': meta['http_code'], 'content_type': meta.get('content_type'),
                  'bytes_read': len(body), 'sha256': digest(body),
                  'wall_seconds': round(time.monotonic() - began, 3)}


def api(endpoint, **params):
    url = endpoint + '?' + urllib.parse.urlencode(params)
    body, evidence = fetch(url)
    data = json.loads(body)
    if not isinstance(data.get('list'), list) or str(data.get('code', 1)) not in ('1', '200'):
        raise ValueError('Invalid CMS response')
    evidence.update(page=data.get('page'), pagecount=data.get('pagecount'),
                    total=data.get('total'), limit=data.get('limit'),
                    item_count=len(data['list']),
                    items=[{k: x.get(k) for k in ['vod_id', 'vod_name', 'type_id', 'type_name', 'vod_year']}
                           for x in data['list']])
    return data, evidence


def normalize_title(value):
    return re.sub(r'\s+', '', value)


def media_entry(row):
    names = str(row.get('vod_play_from', '')).split('$$$')
    blocks = str(row.get('vod_play_url', '')).split('$$$')
    for index, block in enumerate(blocks):
        entries = []
        for item in block.split('#'):
            name, separator, url = item.partition('$')
            try:
                valid_url(url)
            except ValueError:
                continue
            if separator and urllib.parse.urlsplit(url).path.lower().endswith('.m3u8'):
                entries.append((name, url))
        if entries:
            return {'line': names[index] if index < len(names) else str(index),
                    'episode_count': len(entries), 'episode': entries[0][0], 'hls_url': entries[0][1]}
    raise ValueError('No direct HLS entry')


def inspect_and_decode(url, ffmpeg, ffprobe):
    manifests, seen = [], set()
    for depth in range(4):
        if url in seen:
            raise ValueError('Playlist loop')
        seen.add(url)
        body, evidence = fetch(url)
        text = body.decode('utf-8-sig')
        lines = [x.strip() for x in text.splitlines() if x.strip()]
        if not lines or lines[0] != '#EXTM3U':
            raise ValueError('Invalid HLS')
        manifests.append(evidence)
        # Skip encrypted/init/range media. No key or license requests are made.
        if any(x.startswith(('#EXT-X-SESSION-KEY:', '#EXT-X-MAP:', '#EXT-X-BYTERANGE:')) for x in lines):
            raise ValueError('Unsupported encrypted/init/byte-range playlist; skipped')
        if any(x.startswith('#EXT-X-KEY:') and 'METHOD=NONE' not in x for x in lines):
            raise ValueError('Encrypted playlist; skipped without requesting key')
        refs = [(i, x) for i, x in enumerate(lines) if not x.startswith('#')]
        if not refs:
            raise ValueError('No HLS references')
        if any(x.startswith('#EXT-X-STREAM-INF:') for x in lines):
            evidence['declared_streams'] = [x for x in lines if x.startswith('#EXT-X-STREAM-INF:')]
            url = urllib.parse.urljoin(evidence['final_url'], refs[0][1])
            continue
        segments, duration = [], 0.0
        for i, value in refs:
            preceding = lines[i - 1] if i else ''
            d = float(preceding.partition(':')[2].partition(',')[0]) if preceding.startswith('#EXTINF:') else 0.0
            segments.append((urllib.parse.urljoin(evidence['final_url'], value), d))
        evidence['segment_count'] = len(segments)
        evidence['endlist'] = '#EXT-X-ENDLIST' in lines
        evidence['declared_duration_seconds'] = sum(x[1] for x in segments)
        chunks, segment_evidence = [], []
        for segment_url, seconds in segments[:4]:
            chunk, ev = fetch(segment_url, byte_range=True)
            chunks.append(chunk)
            ev['declared_duration_seconds'] = seconds
            segment_evidence.append(ev)
            duration += seconds
            if duration >= 3:
                break
        media = b''.join(chunks)
        probe_cmd = [ffprobe, '-v', 'error', '-protocol_whitelist', 'pipe', '-i', 'pipe:0',
                     '-show_entries', 'stream=codec_type,codec_name,width,height,pix_fmt,sample_rate,channels', '-of', 'json']
        probe = subprocess.run(probe_cmd, input=media, capture_output=True, timeout=15)
        streams = json.loads(probe.stdout).get('streams', []) if probe.returncode == 0 else []
        decode_cmd = [ffmpeg, '-hide_banner', '-nostdin', '-v', 'error', '-threads', '2',
                      '-protocol_whitelist', 'pipe', '-i', 'pipe:0', '-t', '2', '-map', '0:v:0',
                      '-map', '0:a:0?', '-threads', '2', '-progress', 'pipe:1', '-nostats', '-f', 'null', '-']
        decoded = subprocess.run(decode_cmd, input=media, capture_output=True, timeout=20)
        progress = dict(re.findall(r'^([a-z_]+)=(.*)$', decoded.stdout.decode(errors='replace'), re.M))
        frames = int(progress.get('frame', '0'))
        try:
            seconds = int(progress.get('out_time_us', '0')) / 1_000_000
        except ValueError:
            seconds = 0
        success = probe.returncode == 0 and decoded.returncode == 0 and frames > 0 and seconds >= 1.9 and progress.get('progress') == 'end'
        return {'status': 'short_decode_pass' if success else 'short_decode_failed',
                'manifests': manifests, 'segments': segment_evidence,
                'media_bytes_read': len(media), 'streams': streams,
                'ffprobe_exit': probe.returncode,
                'decode': {'exit_code': decoded.returncode, 'frames': frames,
                           'output_seconds': seconds, 'output_time_raw': progress.get('out_time_us'),
                           'progress_end': progress.get('progress') == 'end',
                           'stderr': decoded.stderr.decode(errors='replace')[-2000:]}}
    raise ValueError('Playlist depth limit')


def probe_source(source_id, ffmpeg, ffprobe):
    name, endpoint = SOURCES[source_id]
    result = {'id': source_id, 'name': name, 'endpoint': endpoint, 'checked_at': now(),
              'api_checks': [], 'samples': []}
    try:
        catalog, evidence = api(endpoint, ac='list', pg=1)
        categories = catalog.get('class', [])
        result['categories'] = categories
        result['api_checks'].append(dict(evidence, purpose='categories_and_health'))
        pages = []
        for page in (1, 2):
            response, ev = api(endpoint, ac='detail', wd='爱情', pg=page)
            result['api_checks'].append(dict(ev, purpose='search_pagination'))
            pages.append({str(r['vod_id']) for r in response['list']})
        result['search_pages_have_distinct_ids'] = bool(pages[0] and pages[1] and pages[0] != pages[1])
        result['search_page_overlap_count'] = len(pages[0] & pages[1])
        for group, query, category_names in SAMPLES:
            sample = {'category_group': group, 'query': query}
            result['samples'].append(sample)
            try:
                category = next(c for c in categories if c.get('type_name') in category_names)
                _, ev = api(endpoint, ac='detail', t=str(category['type_id']), pg=1)
                sample['category'] = category
                result['api_checks'].append(dict(ev, purpose=f'browse_{group}'))
                response, ev = api(endpoint, ac='detail', wd=query, pg=1)
                sample['search'] = ev
                rows = response['list']
                row = next((r for r in rows if normalize_title(r['vod_name']) == normalize_title(query)), None)
                if row is None:
                    row = next(r for r in rows if r.get('type_name') in category_names)
                details, ev = api(endpoint, ac='detail', ids=str(row['vod_id']))
                row = next(r for r in details['list'] if str(r['vod_id']) == str(row['vod_id']))
                sample.update(catalog_id=str(row['vod_id']), catalog_title=row['vod_name'],
                              year=row.get('vod_year'), type_name=row.get('type_name'), detail=ev)
                sample.update(media_entry(row))
                sample['media'] = inspect_and_decode(sample['hls_url'], ffmpeg, ffprobe)
                sample['status'] = sample['media']['status']
            except Exception as error:
                sample.update(status='failed_or_skipped', error=f'{type(error).__name__}: {error}')
            print(f'{source_id} {group}: {sample["status"]}', flush=True)
        result['short_decode_passes'] = sum(s.get('status') == 'short_decode_pass' for s in result['samples'])
        result['eligible_default_candidate'] = result['short_decode_passes'] > 0 and result['search_pages_have_distinct_ids']
    except Exception as error:
        result['error'] = f'{type(error).__name__}: {error}'
        result['eligible_default_candidate'] = False
    return result


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--sources', default='ruyi,mdzy,wujin')
    parser.add_argument('--output', default='docs/validation/v0.2/source-expansion.json')
    args = parser.parse_args()
    ids = args.sources.split(',')
    if not ids or any(x not in SOURCES for x in ids):
        parser.error('Unknown source ID')
    ffmpeg, ffprobe = shutil.which('ffmpeg'), shutil.which('ffprobe')
    if not ffmpeg or not ffprobe or not shutil.which('curl'):
        parser.error('Installed curl/ffmpeg/ffprobe required')
    report = {'began_at': now(), 'status': 'running',
              'maximum_parallel_network_requests': 3,
              'request_timeout_seconds': 12, 'request_byte_limit': LIMIT,
              'maximum_media_bytes_per_sample': LIMIT * 4,
              'requested_decode_seconds': 2, 'media_files_saved': False,
              'in_app_playback_verified': False, 'content_identity_verified': False,
              'full_episode_verified': False, 'licensing_verified': False,
              'resolution_basis': 'FFprobe stream metadata, with separate FFmpeg decoding; playlist declarations retained only as declarations',
              'discovery_references': ['docs/validation/higher-quality-source-research.md',
                                       'https://github.com/zlinoliver/moontv/blob/main/config.json',
                                       'https://github.com/hafrey1/LunaTV-config/blob/main/jin18.json',
                                       'https://github.com/LibreSpark/LibreTV/discussions/652'],
              'ffmpeg_version': subprocess.check_output([ffmpeg, '-version'], text=True).splitlines()[0],
              'sources': []}
    path = ROOT / args.output
    path.parent.mkdir(parents=True, exist_ok=True)
    with concurrent.futures.ThreadPoolExecutor(max_workers=3) as executor:
        for source in executor.map(lambda x: probe_source(x, ffmpeg, ffprobe), ids):
            report['sources'].append(source)
            path.write_text(json.dumps(report, ensure_ascii=False, indent=2) + '\n')
    report.update(status='finished', ended_at=now())
    path.write_text(json.dumps(report, ensure_ascii=False, indent=2) + '\n')
    print(path)


if __name__ == '__main__':
    main()
