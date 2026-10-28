import sys,re,threading,urllib.request,secrets
from http.server import BaseHTTPRequestHandler,SimpleHTTPRequestHandler,ThreadingHTTPServer
from pathlib import Path
from functools import partial
from urllib.parse import urlsplit
base=Path(sys.argv[1]); base.mkdir(parents=True,exist_ok=True)
class Origin(SimpleHTTPRequestHandler):
 def do_GET(self):
  if self.path != '/range.ts' or not self.headers.get('Range'): return super().do_GET()
  match=re.fullmatch(r'bytes=(\d+)-(\d*)',self.headers['Range'])
  if not match:self.send_error(416);return
  with (base/'range-requests.log').open('a') as log: log.write(self.headers['Range']+'\n')
  data=(base/'fixture'/'range.ts').read_bytes(); start=int(match.group(1)); end=min(int(match.group(2) or len(data)-1),len(data)-1)
  if start>end:self.send_error(416);return
  body=data[start:end+1]; self.send_response(206);self.send_header('Content-Type','video/mp2t');self.send_header('Content-Range',f'bytes {start}-{end}/{len(data)}');self.send_header('Content-Length',str(len(body)));self.end_headers();self.wfile.write(body)
origin=ThreadingHTTPServer(('127.0.0.1',0),partial(Origin,directory=str(base/'fixture')))
threading.Thread(target=origin.serve_forever,daemon=True).start()
token=secrets.token_urlsafe(32); names={'master.m3u8','video.m3u8','subs.m3u8','sub.vtt','aes-master.m3u8','crypto.m3u8','crypto.key','range-master.m3u8','range.m3u8','range.ts'} | {p.name for p in (base/'fixture').glob('*-*.ts')}
opener=urllib.request.build_opener(urllib.request.ProxyHandler({}))
class H(BaseHTTPRequestHandler):
 def do_GET(self):
  path=urlsplit(self.path).path; parts=path.strip('/').split('/')
  if len(parts)!=2 or parts[0]!=token or parts[1] not in names:self.send_error(404);return
  name=parts[1]; url=f'http://127.0.0.1:{origin.server_port}/{name}'
  try:
   req=urllib.request.Request(url)
   if self.headers.get('Range'):req.add_header('Range',self.headers['Range'])
   with opener.open(req,timeout=4) as response:
    data=response.read();mime=response.headers.get('Content-Type') or 'application/octet-stream'; status=response.status;content_range=response.headers.get('Content-Range')
  except Exception:self.send_error(502);return
  if name.endswith('.m3u8'):
   body=data.decode('utf-8')
   def replace_uri(match):
    inner=match.group(1)
    if inner not in names: raise ValueError('unknown URI')
    return 'URI="'+inner+'"'
   body=re.sub(r'URI="([^"]+)"',replace_uri,body)
   for line in body.splitlines():
    if line and not line.startswith('#') and line not in names: raise ValueError('unknown media')
   data=body.encode();mime='application/vnd.apple.mpegurl'
  self.send_response(status);self.send_header('Content-Type',mime);self.send_header('Content-Length',str(len(data)))
  if content_range:self.send_header('Content-Range',content_range)
  self.end_headers()
  try:self.wfile.write(data)
  except (BrokenPipeError,ConnectionResetError):pass
 def log_message(self,format,*args):pass
server=ThreadingHTTPServer(('127.0.0.1',0),H)
(base/'poc_url').write_text(f'http://127.0.0.1:{server.server_port}/{token}/master.m3u8'); (base/'poc_aes_url').write_text(f'http://127.0.0.1:{server.server_port}/{token}/aes-master.m3u8'); (base/'poc_range_url').write_text(f'http://127.0.0.1:{server.server_port}/{token}/range-master.m3u8')
server.serve_forever()
