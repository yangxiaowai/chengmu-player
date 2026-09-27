#!/usr/bin/env python3
"""Bounded CMS/HLS reachability evidence with curl's HTTP proxy disabled.

Run after the web-access skill preflight. This does not disable or bypass an
operating-system VPN/tunnel and can never certify mainland-China availability.
No media files, public IP, network interface details, credentials, or keys are
saved. The probe reads at most two 256 KiB segment prefixes per sample.
"""
import argparse
import concurrent.futures
import datetime
import hashlib
import ipaddress
import json
import os
import re
import subprocess
import threading
import time
import urllib.parse
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
CATALOG_LIMIT = 4 * 1024 * 1024
SEGMENT_LIMIT = 256 * 1024
PHYSICAL_TRANSPORT = None
DOH_ENDPOINT = "https://dns.alidns.com/resolve"
DOH_BOOTSTRAP_IPV4 = "223.5.5.5"
SOURCES = {
    "dytt": ("电影天堂目录", "https://caiji.dyttzyapi.com/api.php/provide/vod", None,
             "怪奇物语第一季", "7942", "美剧"),
    "ffzy": ("非凡目录", "https://ffzy5.tv/api.php/provide/vod", "detail",
             "怪奇物语第一季", "24151", "美剧"),
    "ruyi": ("如意目录", "https://cj.rycjapi.com/api.php/provide/vod", "detail",
             "琅琊榜", "11751", "国产剧"),
    "mdzy": ("魔都目录", "https://www.mdzyapi.com/api.php/provide/vod", "detail",
             "怪奇物语第一季", "10734", "美剧"),
    "wujin": ("无尽目录", "https://api.wujinapi.com/api.php/provide/vod", "detail",
              "流浪地球", "25734", "电影"),
}


def utc_now():
    return datetime.datetime.now(datetime.timezone.utc).isoformat()


def valid_url(url):
    parsed = urllib.parse.urlsplit(url)
    if parsed.scheme not in ("http", "https") or not parsed.hostname or parsed.username or parsed.password:
        raise ValueError("Expected public HTTP(S) URL without credentials")
    return url


class ProbeError(Exception):
    def __init__(self, reason, evidence=None):
        super().__init__(reason)
        self.evidence = evidence or {}


def curl_fetch(url, segment=False, extra_options=None, follow_redirects=True):
    """Return bytes, final URL, sanitized metadata; segment prefixes may truncate.

    curl is invoked without a shell. -q is the first option (ignores curlrc),
    proxy environment variables are removed, and both explicit proxy controls
    are set. stdout is capped even when a server ignores the Range header.
    """
    valid_url(url)
    cap = SEGMENT_LIMIT if segment else CATALOG_LIMIT
    marker = "__YINGCHUAN_METADATA__"
    command = ["curl", "-q", "--noproxy", "*", "--proxy", "", "--silent", "--show-error",
               "--fail", "--proto", "=http,https", "--proto-redir", "=http,https",
               "--connect-timeout", "5", "--max-time", "12", "--max-redirs", "4",
               "--user-agent", "YingChuan/0.2.2 source-connectivity-probe",
               "--write-out", "%{stderr}" + marker + "%{json}"]
    if follow_redirects:
        command.append("--location")
    command += extra_options or []
    if segment:
        command += ["--range", f"0-{cap - 1}"]
    else:
        command += ["--max-filesize", str(cap)]
    command += [url]
    env = {k: v for k, v in os.environ.items() if not k.lower().endswith("_proxy")}
    began = time.monotonic()
    process = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=env)
    chunks, count = [], 0
    while count < cap:
        chunk = process.stdout.read(min(65536, cap - count))
        if not chunk:
            break
        chunks.append(chunk)
        count += len(chunk)
    limit_reached = count == cap
    process.stdout.close()
    process.stdout = None
    try:
        _, error_data = process.communicate(timeout=15)
    except subprocess.TimeoutExpired:
        process.kill()
        _, error_data = process.communicate()
    body = b"".join(chunks)
    diagnostics = error_data.decode("utf-8", errors="replace")
    raw_metadata = diagnostics.rpartition(marker)[2]
    try:
        metadata = json.loads(raw_metadata)
    except (ValueError, TypeError):
        metadata = {}
    final_url = metadata.get("url_effective", url)
    valid_url(final_url)
    # Deliberately do not retain curl's local_ip / remote_ip, error text, or URLs
    # containing transient tokens. Request/final hosts suffice for network scope.
    evidence = {
        "requested_host": urllib.parse.urlsplit(url).hostname,
        "final_host": urllib.parse.urlsplit(final_url).hostname,
        "requested_url_sha256": hashlib.sha256(url.encode()).hexdigest(),
        "http_status": int(metadata.get("http_code", 0)),
        "curl_exit": process.returncode,
        "bytes_read": len(body),
        "byte_limit": cap,
        "read_limit_reached": limit_reached,
        "content_type": metadata.get("content_type"),
        "wall_seconds": round(time.monotonic() - began, 3),
        "redirect_count": metadata.get("num_redirects"),
        "payload_sha256": hashlib.sha256(body).hexdigest(),
        "range_requested": segment,
    }
    if extra_options and "--interface" in extra_options:
        interface = extra_options[extra_options.index("--interface") + 1]
        evidence["physical_interface"] = interface
        evidence["socket_bound_to_interface_verified"] = any(
            "socket successfully bound to interface" in line and interface in line
            for line in diagnostics.splitlines()
        )
    # Closing stdout at the byte cap can intentionally produce curl exit 23.
    # That proves bytes were read, not that the entire segment was transferred.
    intentional_prefix = segment and limit_reached and process.returncode in (0, 23)
    if process.returncode != 0 and not intentional_prefix:
        raise ProbeError(f"curl exit {process.returncode}; HTTP {evidence['http_status']}", evidence)
    redirect = metadata.get("redirect_url")
    if not follow_redirects and evidence["http_status"] in (301, 302, 303, 307, 308) and redirect:
        return body, final_url, evidence, redirect
    if not 200 <= evidence["http_status"] < 300 or not body:
        raise ProbeError("No successful nonempty HTTP response", evidence)
    if limit_reached and not segment:
        raise ProbeError("Catalog or playlist reached response limit", evidence)
    evidence["passed"] = True
    evidence["complete_response"] = not limit_reached
    return body, final_url, evidence, None


class PhysicalTransport:
    """Per-socket interface binding plus pinned, TLS-validated official DoH.

    No OS resolver answers or automatic curl redirects are used. Each redirect
    host is independently resolved through the same physical DoH connection.
    """
    def __init__(self, interface):
        if not re.fullmatch(r"[a-zA-Z][a-zA-Z0-9]{0,15}", interface):
            raise ValueError("Invalid interface name")
        self.interface = interface
        self.cache = {}
        self.lock = threading.Lock()

    def options(self, host, port, address):
        return ["--interface", self.interface, "-4", "--resolve", f"{host}:{port}:{address}", "--verbose"]

    def resolve(self, host):
        with self.lock:
            cached = self.cache.get(host)
        if cached and cached[0] > time.monotonic():
            return cached[1], {**cached[2], "cached_within_ttl": True}
        url = DOH_ENDPOINT + "?" + urllib.parse.urlencode({"name": host, "type": "A"})
        body, _, evidence, redirect = curl_fetch(
            url, extra_options=self.options("dns.alidns.com", 443, DOH_BOOTSTRAP_IPV4), follow_redirects=False)
        if redirect:
            raise ProbeError("Pinned DoH redirected; no fallback performed", evidence)
        if not evidence.get("socket_bound_to_interface_verified"):
            raise ProbeError("DoH physical interface binding not verified", evidence)
        try:
            data = json.loads(body)
        except (ValueError, UnicodeDecodeError):
            raise ProbeError("DoH did not return JSON", evidence)
        if not isinstance(data, dict):
            raise ProbeError("DoH JSON was not an object", evidence)
        answers = []
        for answer in data.get("Answer", []):
            if answer.get("type") == 1:
                try:
                    address = ipaddress.IPv4Address(answer.get("data", ""))
                    if address.is_global:
                        answers.append((str(address), max(0, int(answer.get("TTL", 0)))))
                except (ValueError, TypeError):
                    continue
        if data.get("Status") != 0 or not answers:
            raise ProbeError("DoH returned no globally routable A record", evidence)
        ttl = min(answer[1] for answer in answers)
        for answer in data.get("Answer", []):
            if answer.get("type") == 5:
                try:
                    ttl = min(ttl, max(0, int(answer.get("TTL", 0))))
                except (ValueError, TypeError):
                    ttl = 0
        record = {"provider": "Alibaba Public DNS", "endpoint": DOH_ENDPOINT,
                  "bootstrap_ipv4": DOH_BOOTSTRAP_IPV4, "tls_verification_enabled": True,
                  "host": host, "a_record_count": len(answers), "minimum_ttl_seconds": ttl,
                  "resolved_at": utc_now(), "cached_within_ttl": False,
                  "selected_address_sha256": hashlib.sha256(answers[0][0].encode()).hexdigest(),
                  "http_status": evidence["http_status"], "wall_seconds": evidence["wall_seconds"],
                  "socket_bound_to_interface_verified": evidence["socket_bound_to_interface_verified"],
                  "payload_sha256": evidence["payload_sha256"]}
        with self.lock:
            self.cache[host] = (time.monotonic() + ttl, answers[0][0], record)
        return answers[0][0], record

    def fetch(self, original_url, segment=False):
        began = time.monotonic()
        url = original_url
        hops = []
        for _ in range(5):
            parsed = urllib.parse.urlsplit(valid_url(url))
            address, dns = self.resolve(parsed.hostname)
            try:
                body, final_url, evidence, redirect = curl_fetch(
                    url, segment=segment, follow_redirects=False,
                    extra_options=self.options(parsed.hostname, parsed.port or (443 if parsed.scheme == "https" else 80), address))
            except ProbeError as error:
                error.evidence.update(dns=dns, redirect_chain=hops)
                raise
            evidence["dns"] = dns
            if not evidence.get("socket_bound_to_interface_verified"):
                raise ProbeError("Media/API physical interface binding not verified", evidence)
            if redirect:
                hops.append(evidence)
                url = urllib.parse.urljoin(final_url, redirect)
                continue
            evidence["redirect_chain"] = hops
            evidence["redirect_count"] = len(hops)
            evidence["requested_host"] = urllib.parse.urlsplit(original_url).hostname
            evidence["requested_url_sha256"] = hashlib.sha256(original_url.encode()).hexdigest()
            evidence["total_wall_seconds_including_dns"] = round(time.monotonic() - began, 3)
            return body, final_url, evidence
        raise ProbeError("Exceeded four manually resolved HTTP redirects", {"redirect_chain": hops})


def fetch(url, segment=False):
    if PHYSICAL_TRANSPORT:
        return PHYSICAL_TRANSPORT.fetch(url, segment=segment)
    body, final_url, evidence, _ = curl_fetch(url, segment=segment)
    return body, final_url, evidence


def api(endpoint, **params):
    url = endpoint + "?" + urllib.parse.urlencode(params)
    body, _, evidence = fetch(url)
    try:
        data = json.loads(body)
    except (ValueError, UnicodeDecodeError):
        raise ProbeError("Response was not valid JSON", evidence)
    if not isinstance(data, dict) or not isinstance(data.get("list"), list) or str(data.get("code", 1)) not in ("1", "200"):
        raise ProbeError("Response was not a successful CMS list", evidence)
    evidence["item_count"] = len(data["list"])
    evidence["declared_total"] = data.get("total")
    return data["list"], evidence


def media_entry(row):
    names = str(row.get("vod_play_from", "")).split("$$$")
    for index, block in enumerate(str(row.get("vod_play_url", "")).split("$$$")):
        entries = []
        for item in block.split("#"):
            episode, separator, url = item.partition("$")
            if not separator:
                continue
            try:
                valid_url(url)
            except ValueError:
                continue
            if urllib.parse.urlsplit(url).path.lower().endswith(".m3u8"):
                entries.append((episode, url))
        if entries:
            return entries[0][1], {"line": names[index] if index < len(names) else str(index),
                                  "episode": entries[0][0], "episode_count": len(entries)}
    raise ProbeError("No direct HLS line in detail response")


def inspect_hls(url):
    evidence = {"playlists": [], "segments": [], "decoded": False,
                "key_requested": False, "segment_prefix_reachable": False}
    seen = set()
    try:
        for _ in range(5):
            if url in seen:
                raise ProbeError("Playlist loop")
            seen.add(url)
            body, final_url, fetched = fetch(url)
            evidence["playlists"].append(fetched)
            try:
                lines = [x.strip() for x in body.decode("utf-8-sig").splitlines() if x.strip()]
            except UnicodeDecodeError:
                raise ProbeError("Playlist was not UTF-8")
            if not lines or lines[0] != "#EXTM3U":
                raise ProbeError("Response was not an HLS playlist")
            refs = [x for x in lines if not x.startswith("#")]
            if not refs:
                raise ProbeError("HLS playlist had no media references")
            if any(x.startswith("#EXT-X-STREAM-INF:") for x in lines):
                url = urllib.parse.urljoin(final_url, refs[0])
                continue
            evidence["segment_count"] = len(refs)
            evidence["endlist"] = "#EXT-X-ENDLIST" in lines
            evidence["encryption_methods"] = sorted({
                match.group(1) for line in lines if line.startswith("#EXT-X-KEY:")
                for match in [re.search(r"(?:^|[:,])METHOD=([^,]+)", line)] if match
            })
            evidence["initialization_map_required"] = any(x.startswith("#EXT-X-MAP:") for x in lines)
            evidence["byte_range_required"] = any(x.startswith("#EXT-X-BYTERANGE:") for x in lines)
            if evidence["byte_range_required"]:
                raise ProbeError("Byte-range playlist requires offsets; sample skipped")
            for reference in refs[:2]:
                segment_url = urllib.parse.urljoin(final_url, reference)
                try:
                    prefix, _, segment_evidence = fetch(segment_url, segment=True)
                    segment_evidence["mpeg_ts_sync_seen"] = any(
                        prefix[i] == 0x47 and prefix[i + 188] == 0x47 and prefix[i + 376] == 0x47
                        for i in range(min(188, max(0, len(prefix) - 376)))
                    )
                    segment_evidence["iso_media_box_seen"] = prefix[4:8] in (b"ftyp", b"styp", b"moof", b"sidx")
                    segment_evidence["html_response_seen"] = prefix[:256].lstrip().lower().startswith((b"<!doctype html", b"<html"))
                    if segment_evidence["html_response_seen"]:
                        segment_evidence["passed"] = False
                        segment_evidence["error"] = "Segment response was HTML"
                    evidence["segments"].append(segment_evidence)
                except ProbeError as error:
                    evidence["segments"].append({**error.evidence, "passed": False, "error": str(error)})
            evidence["segment_prefix_reachable"] = len(evidence["segments"]) == min(2, len(refs)) and all(x["passed"] for x in evidence["segments"])
            return evidence
        raise ProbeError("Exceeded five HLS playlist levels")
    except (ProbeError, ValueError) as error:
        evidence["error"] = str(error)
        if isinstance(error, ProbeError) and error.evidence:
            evidence["failed_request"] = error.evidence
        return evidence


def probe(provider_id):
    name, endpoint, action, title, catalog_id, category = SOURCES[provider_id]
    result = {"provider_id": provider_id, "name": name, "endpoint": endpoint, "checked_at": utc_now(),
              "title": title, "catalog_id": catalog_id, "sample_category": category,
              "search": {"passed": False}, "detail": {"passed": False}, "catalog_passed": False,
              "media": {"segment_prefix_reachable": False}}
    stage = "search"
    try:
        search_params = {"wd": title, "pg": 1}
        if action:
            search_params["ac"] = action
        rows, result["search"] = api(endpoint, **search_params)
        if not any(str(x.get("vod_id")) == catalog_id for x in rows):
            raise ProbeError("Expected sample ID not present in search results", result["search"])
        result["search"]["sample_found"] = True
        stage = "detail"
        rows, result["detail"] = api(endpoint, ac="detail", ids=catalog_id)
        matches = [x for x in rows if str(x.get("vod_id")) == catalog_id]
        if not matches:
            raise ProbeError("Expected sample ID not present in detail results", result["detail"])
        row = matches[0]
        result["returned_title"] = row.get("vod_name")
        result["returned_category"] = row.get("type_name")
        result["catalog_passed"] = True
        stage = "media"
        url, media_identity = media_entry(row)
        result["media"] = {**media_identity, **inspect_hls(url)}
    except (ProbeError, ValueError) as error:
        failed = {"passed": False, "error": str(error)}
        if isinstance(error, ProbeError):
            failed = {**error.evidence, **failed}
        result[stage] = {**result.get(stage, {}), **failed}
    result["completed_at"] = utc_now()
    return result


def write_markdown(report, path):
    rows = ["# 当前网络媒体源分层探测", "", f"检测时间：{report['started_at']}", "",
            "curl 已显式关闭 HTTP/HTTPS/SOCKS 代理配置，且忽略 curlrc 与代理环境变量。"
            "这不能绕过或排除系统 VPN、TUN、路由分流，也不能证明中国大陆各运营商均可访问。", "",
            f"本次网络背景：{report['network_context']}。", "",
            "| 来源 | 代表样本 | 搜索与详情 | HLS / 片段前缀 |", "|---|---|---|---|"]
    for result in report["providers"]:
        media = result["media"]
        catalog_status = "通过" if result["catalog_passed"] else "失败"
        if not result["catalog_passed"]:
            for stage, label in (("search", "搜索"), ("detail", "详情")):
                if result[stage].get("error"):
                    catalog_status += f"（{label}：{result[stage]['error']}）"
                    break
        if media.get("segment_prefix_reachable"):
            size = sum(x.get("bytes_read", 0) for x in media["segments"])
            media_status = f"读取 {len(media['segments'])} 个片段前缀，共 {size:,} 字节"
        else:
            media_status = media.get("error", "未通过或未执行")
        rows.append(f"| {result['name']} | {result['title']} | {catalog_status} | {media_status} |")
    rows += ["", "检测最多并发 3 个请求，每个请求最多 12 秒，目录和清单上限 4 MiB，"
             "每个样本最多读取 2 个片段、每段 256 KiB。所有媒体字节仅在内存中存在，没有保存媒体文件或密钥。", "",
             "本次只验证目录内容、HLS 清单及片段前缀可取，不包含视频解码、声音、整集连续播放、"
             "原生 4K、影片画面身份核对或中国大陆无 VPN 认证。样本结果不能推广到全库。", "",
             "复现：`python3 scripts/probe-direct-media.py`；如在关闭 VPN 后重测，可增加 "
             "`--network-context user-reported-vpn-off` 并保存到新输出文件，保留前次证据。", ""]
    if report.get("physical_mode"):
        rows[4] = ("本次为显式物理接口探针：curl 以 `--interface " + report["physical_interface"] +
                   " -4` 绑定 socket，并在每次请求的 verbose 诊断中核实绑定成功。DNS 通过 TLS 校验的 "
                   "[阿里公共 DNS](https://www.alidns.com) `/resolve` 查询取得，DNS 自身也绑定相同物理接口，"
                   "并用其官方 IPv4 223.5.5.5 启动解析。API、HLS、分片及每次重定向均用 `--resolve` "
                   "指定独立解析结果，没有使用系统合成 DNS，也没有修改系统代理、VPN 或路由配置。")
        rows += ["物理接口成功说明这些特定请求在当前设备上按接口约束访问；本次没有记录公网出口 IP，"
                 "也未独立核验网络所在地区。它不能证明全国各地、各运营商、所有影片或后续时间都可用。", "",
                 "物理模式复现：`python3 scripts/probe-direct-media.py --physical-interface " +
                 report["physical_interface"] + "`；默认另存 `direct-media-physical.json/.md`。", ""]
    path.write_text("\n".join(rows), encoding="utf-8")


def self_test():
    """Exercise bounded reads against a local HTTP fixture, without Internet."""
    global curl_fetch
    import http.server
    import threading

    class Handler(http.server.BaseHTTPRequestHandler):
        def log_message(self, *_):
            pass

        def do_GET(self):
            if self.path == "/redirect":
                self.send_response(302)
                self.send_header("Location", "/dir/master.m3u8")
                self.end_headers()
                return
            if self.path.endswith("/master.m3u8"):
                body = b"#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=100\nchild.m3u8\n"
            elif self.path.endswith("/child.m3u8"):
                body = b"#EXTM3U\n#EXTINF:4,\nseg.ts\n#EXT-X-ENDLIST\n"
            elif self.path.endswith("/seg.ts"):
                body = (b"G" + b"\0" * 187) * 3000
            elif self.path == "/huge":
                body = b"x" * (CATALOG_LIMIT + 1)
            elif self.path == "/bad.m3u8":
                body = b"#EXTM3U\n#EXTINF:4,\nbad.ts\n#EXT-X-ENDLIST\n"
            elif self.path == "/bad.ts":
                body = b"<!doctype html><html>error page</html>"
            else:
                body = b'{"code":1,"list":[]}'
            self.send_response(200)
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            try:
                self.wfile.write(body)
            except (BrokenPipeError, ConnectionResetError):
                pass

    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    base = f"http://127.0.0.1:{server.server_port}"
    try:
        body, _, evidence = fetch(base + "/json")
        assert evidence["passed"] and json.loads(body)["code"] == 1
        hls = inspect_hls(base + "/redirect")
        assert hls["segment_prefix_reachable"], hls
        assert len(hls["playlists"]) == 2
        assert hls["segments"][0]["bytes_read"] == SEGMENT_LIMIT
        assert hls["segments"][0]["mpeg_ts_sync_seen"]
        try:
            fetch(base + "/huge")
            raise AssertionError("Oversized catalog was not rejected")
        except ProbeError as error:
            assert error.evidence["bytes_read"] <= CATALOG_LIMIT
        bad_hls = inspect_hls(base + "/bad.m3u8")
        assert not bad_hls["segment_prefix_reachable"]
        assert bad_hls["segments"][0]["html_response_seen"]
    finally:
        server.shutdown()
        server.server_close()
    original_curl_fetch = curl_fetch
    requests = []

    def fake_curl_fetch(url, segment=False, extra_options=None, follow_redirects=True):
        requests.append(url)
        assert follow_redirects is False
        assert extra_options[:3] == ["--interface", "en0", "-4"]
        evidence = {"http_status": 200, "wall_seconds": 0.01, "payload_sha256": "fixture",
                    "socket_bound_to_interface_verified": True, "passed": True}
        if url.startswith(DOH_ENDPOINT):
            assert "dns.alidns.com:443:" + DOH_BOOTSTRAP_IPV4 in extra_options
            body = json.dumps({"Status": 0, "Answer": [{"type": 1, "data": "1.2.3.4", "TTL": 60}]}).encode()
            return body, url, evidence, None
        host = urllib.parse.urlsplit(url).hostname
        assert f"{host}:443:1.2.3.4" in extra_options
        if host == "first.example":
            return b"", url, {**evidence, "http_status": 302}, "https://second.example/playlist"
        assert host == "second.example"
        return b"#EXTM3U", url, evidence, None

    try:
        curl_fetch = fake_curl_fetch
        transport = PhysicalTransport("en0")
        _, final_url, evidence = transport.fetch("https://first.example/start")
        assert final_url == "https://second.example/playlist" and evidence["redirect_count"] == 1
        assert len(requests) == 4  # Two DoH requests and two HTTP requests.
        transport.fetch("https://first.example/start")
        assert len(requests) == 6  # Both DNS answers reused within their TTL.
    finally:
        curl_fetch = original_curl_fetch
    return {"checked_at": utc_now(), "passed": True, "external_network_used": False,
            "checks": ["JSON response bytes", "redirect and relative HLS URLs",
                       "segment cap when server ignores Range", "MPEG-TS signature detection",
                       "oversized catalog rejected", "HTML segment rejected",
                       "physical redirects resolve every host independently", "DoH TTL cache reuse"]}


def main():
    global PHYSICAL_TRANSPORT
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--sources", default=",".join(SOURCES))
    parser.add_argument("--output", type=Path)
    parser.add_argument("--network-context", choices=("current-network-vpn-not-excluded", "user-reported-vpn-off"),
                        default="current-network-vpn-not-excluded")
    parser.add_argument("--self-test", action="store_true", help="Run only local HTTP fixture checks")
    parser.add_argument("--physical-interface", help="Bind all sockets and pinned official DoH to a physical interface, e.g. en0")
    args = parser.parse_args()
    if args.self_test:
        print(json.dumps(self_test(), ensure_ascii=False, indent=2))
        return
    selected = list(dict.fromkeys(args.sources.split(",")))
    if not selected or any(x not in SOURCES for x in selected):
        parser.error("Unknown source; allowed: " + ",".join(SOURCES))
    if args.physical_interface:
        PHYSICAL_TRANSPORT = PhysicalTransport(args.physical_interface)
    if not args.output:
        filename = "direct-media-physical.json" if PHYSICAL_TRANSPORT else "direct-media.json"
        args.output = ROOT / "docs/validation/v0.2.2" / filename
    report = {"schema_version": 1, "started_at": utc_now(), "network_context": args.network_context,
              "http_proxy_disabled": True, "curlrc_ignored": True, "proxy_environment_removed": True,
              "system_vpn_excluded_by_probe": False, "mainland_china_direct_certified": False,
              "transport": "curl -q --noproxy '*' --proxy '' (HTTP(S), default TLS validation)",
              "maximum_parallel_requests": 3, "request_timeout_seconds": 12,
              "catalog_playlist_limit_bytes": CATALOG_LIMIT, "segment_prefix_limit_bytes": SEGMENT_LIMIT,
              "maximum_segments_per_sample": 2, "media_files_saved": False, "keys_requested": False,
              "video_decode_verified": False, "full_episode_verified": False, "native_4k_verified": False}
    if PHYSICAL_TRANSPORT:
        report.update(physical_mode=True, physical_interface=args.physical_interface,
                      network_context="explicit-physical-socket-binding-with-independent-doh",
                      system_network_configuration_changed=False, system_dns_used=False,
                      physical_exit_location_verified=False, public_exit_ip_saved=False,
                      dns_provider="Alibaba Public DNS", dns_endpoint=DOH_ENDPOINT,
                      dns_bootstrap_ipv4=DOH_BOOTSTRAP_IPV4,
                      dns_bootstrap_reference="https://www.alidns.com",
                      redirects="manual; independent DoH and --resolve for every host",
                      transport="curl -q --noproxy '*' --proxy '' --interface " + args.physical_interface +
                                " -4 --resolve HOST:PORT:DoH_A_RECORD; default TLS validation, per-request binding diagnostics")
    with concurrent.futures.ThreadPoolExecutor(max_workers=3) as executor:
        report["providers"] = list(executor.map(probe, selected))
    report["completed_at"] = utc_now()
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    write_markdown(report, args.output.with_suffix(".md"))
    for result in report["providers"]:
        failure = next((result[stage]["error"] for stage in ("search", "detail", "media")
                        if result[stage].get("error")), None)
        print(json.dumps({"provider": result["provider_id"], "catalog_passed": result["catalog_passed"],
                          "media_prefix_passed": result["media"].get("segment_prefix_reachable", False),
                          "error": failure}, ensure_ascii=False), flush=True)
    print(str(args.output), flush=True)


if __name__ == "__main__":
    main()
