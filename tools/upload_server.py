#!/usr/bin/env python3
"""AIM 上传服务：音频（/）+ 视频（/video）"""
import os
import sys
import html
import re
from http.server import HTTPServer, BaseHTTPRequestHandler
from urllib.parse import urlparse, parse_qs
import cgi

SAVE_DIR = "/root/aim/audio_upload"
VIDEO_DIR = "/tmp/aim_video_upload"
os.makedirs(SAVE_DIR, exist_ok=True)
os.makedirs(VIDEO_DIR, exist_ok=True)

PAGE = """<!DOCTYPE html>
<html lang="zh">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>AIM 音频上传</title>
<style>
  body { background:#11110f; color:#fff5dc; font-family:monospace; padding:24px; max-width:560px; margin:0 auto; }
  h1 { color:#ff4e35; font-size:20px; }
  h2 { color:#ffd36a; font-size:14px; margin-top:28px; }
  .box { background:#1e1d1a; border:1px solid #5a554c; padding:16px; margin-bottom:12px; }
  label { display:block; margin-bottom:6px; color:#77736b; font-size:12px; }
  input[type=file] { color:#fff5dc; margin-bottom:10px; width:100%; }
  input[type=text] { background:#11110f; border:1px solid #5a554c; color:#fff5dc; padding:6px; width:100%; box-sizing:border-box; margin-bottom:10px; }
  button { background:#ff4e35; border:none; color:#fff; padding:10px 20px; font-size:14px; cursor:pointer; font-family:monospace; }
  button:hover { filter:brightness(1.15); }
  .files { list-style:none; padding:0; }
  .files li { padding:6px 0; border-bottom:1px solid #2a2824; font-size:13px; }
  .ok { color:#61d39e; margin-top:10px; font-size:13px; }
  .err { color:#ff4e35; margin-top:10px; font-size:13px; }
  .note { color:#77736b; font-size:11px; margin-top:16px; }
</style>
</head>
<body>
<h1>AIM 音频上传</h1>
<div class="box">
  <h2>🎵 非战斗 BGM（数码闲时）</h2>
  <label>选择文件（mp3/wav/ogg）</label>
  <input type="file" id="f1" accept="audio/*">
  <label>保存为文件名（默认 bgm_idle.mp3）</label>
  <input type="text" id="n1" value="bgm_idle.mp3">
  <button onclick="up(1)">上传</button>
  <div id="s1"></div>
</div>
<div class="box">
  <h2>⚔️ 战斗 BGM（数码指挥部）</h2>
  <label>选择文件（mp3/wav/ogg）</label>
  <input type="file" id="f2" accept="audio/*">
  <label>保存为文件名（默认 bgm_battle.mp3）</label>
  <input type="text" id="n2" value="bgm_battle.mp3">
  <button onclick="up(2)">上传</button>
  <div id="s2"></div>
</div>
<h2>已接收文件</h2>
<ul class="files" id="flist">__FILES__</ul>
<p class="note">上传后显示 ✅ 即成功。文件会保存到服务器，随后集成进游戏。</p>
<script>
function up(n) {
  var file = document.getElementById('f'+n).files[0];
  var name = document.getElementById('n'+n).value.trim() || ('bgm_'+(n==1?'idle':'battle')+'.mp3');
  var box = document.getElementById('s'+n);
  if (!file) { box.innerHTML = '<div class="err">请先选择文件</div>'; return; }
  box.innerHTML = '<div class="ok">上传中…</div>';
  var xhr = new XMLHttpRequest();
  xhr.open('POST', '/upload?name=' + encodeURIComponent(name), true);
  xhr.onload = function() {
    if (xhr.status == 200) {
      box.innerHTML = '<div class="ok">✅ 上传成功：' + name + '</div>';
      setTimeout(function(){ location.reload(); }, 1200);
    } else {
      box.innerHTML = '<div class="err">上传失败：' + xhr.responseText + '</div>';
    }
  };
  xhr.onerror = function() { box.innerHTML = '<div class="err">网络错误</div>'; };
  xhr.send(file);
}
</script>
</body>
</html>"""

VIDEO_PAGE = """<!DOCTYPE html>
<html lang="zh">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>AIM 视频上传</title>
<style>
body { background:#11110f; color:#fff5dc; font-family:monospace; padding:24px; max-width:600px; margin:0 auto; }
h1 { color:#ff4e35; font-size:20px; }
h2 { color:#ffd36a; font-size:14px; margin-top:28px; }
.box { background:#1e1d1a; border:1px solid #5a554c; padding:16px; margin-bottom:12px; }
label { display:block; margin-bottom:6px; color:#77736b; font-size:12px; }
input[type=file] { color:#fff5dc; margin-bottom:10px; width:100%; }
button { background:#ff4e35; color:#fff; border:2px solid #5a554c; padding:10px 20px; font-size:14px; cursor:pointer; }
.ok { color:#5ac87a; font-size:13px; }
.err { color:#ff6b6b; font-size:13px; }
ul { list-style:none; padding:0; }
li { padding:6px 10px; background:#1e1d1a; border:1px solid #5a554c; margin-bottom:4px; font-size:13px; }
li a { color:#ffd36a; text-decoration:none; }
.sz { color:#77736b; font-size:11px; margin-left:8px; }
.nav { color:#77736b; font-size:12px; margin-bottom:16px; }
.nav a { color:#ffd36a; text-decoration:none; }
</style>
</head>
<body>
<h1>AIM 视频上传</h1>
<div class="nav"><a href="/audio">→ 音频上传页</a></div>
<p style="color:#77736b; font-size:13px;">选择游戏视频上传，我下载下来分析后告诉你哪里要改。建议10MB 以内。</p>
<div class="box">
<form id="vf" action="/video" method="post" enctype="multipart/form-data">
<label>选择视频文件（MP4 / MOV）</label>
<input type="file" name="video" id="vfile" accept="video/*" required>
<br>
<button type="submit">上传</button>
</form>
<div id="vstat"></div>
</div>
<h2>已上传视频</h2>
<ul>__FILES__</ul>
<script>
document.getElementById('vf').addEventListener('submit', function(e) {
  e.preventDefault();
  var f = document.getElementById('vfile').files[0];
  if (!f) return;
  document.getElementById('vstat').innerHTML = '<div class="ok">上传中…</div>';
  var fd = new FormData();
  fd.append('video', f);
  var xhr = new XMLHttpRequest();
  xhr.open('POST', '/video', true);
  xhr.onload = function() { if (xhr.status < 400) location.reload(); else document.getElementById('vstat').innerHTML = '<div class="err">上传失败</div>'; };
  xhr.send(fd);
});
</script>
</body>
</html>"""

class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        u = urlparse(self.path)
        # 游戏介绍：HTML 展示页 + TXT 下载
        if u.path == "/aim_intro" or u.path == "/aim_intro.html":
            hp = os.path.join(os.path.dirname(os.path.abspath(__file__)), "aim_intro.html")
            if os.path.isfile(hp):
                with open(hp, "rb") as f:
                    data = f.read()
                self.send_response(200)
                self.send_header("Content-Type", "text/html; charset=utf-8")
                self.send_header("Content-Length", str(len(data)))
                self.end_headers()
                self.wfile.write(data)
                return
            self.send_response(404); self.end_headers(); return
        # 游戏介绍 TXT 下载
        if u.path == "/aim_intro.txt":
            p = os.path.join(os.path.dirname(os.path.abspath(__file__)), "aim_intro.txt")
            if os.path.isfile(p):
                with open(p, "rb") as f:
                    data = f.read()
                self.send_response(200)
                self.send_header("Content-Type", "text/plain; charset=utf-8")
                self.send_header("Content-Length", str(len(data)))
                self.send_header("Content-Disposition", "attachment; filename=aim_intro.txt")
                self.end_headers()
                self.wfile.write(data)
                return
            self.send_response(404); self.end_headers(); return
        if u.path == "/" or u.path == "/index.html":
            self.send_response(303); self.send_header("Location", "/audio"); self.end_headers()
            return
        if u.path == "/audio" or u.path == "/audio.html":
            files = sorted(os.listdir(SAVE_DIR)) if os.path.isdir(SAVE_DIR) else []
            items = ""
            for f in files:
                p = os.path.join(SAVE_DIR, f)
                sz = os.path.getsize(p)
                kb = sz / 1024
                items += f"<li>{html.escape(f)} — {kb:.1f} KB</li>"
            page = PAGE.replace("__FILES__", items)
            data = page.encode()
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)
            return
        if u.path == "/video" or u.path == "/video.html":
            files = []
            for f in sorted(os.listdir(VIDEO_DIR)):
                p = os.path.join(VIDEO_DIR, f)
                if os.path.isfile(p):
                    sz = os.path.getsize(p)
                    files.append((f, sz))
            items = ""
            for name, sz in files:
                mb = sz / (1024*1024)
                items += f'<li><a href="/videofile/{html.escape(name)}">{html.escape(name)}</a> <span class="sz">{mb:.2f} MB</span></li>'
            page = VIDEO_PAGE.replace("__FILES__", items or '<li style="color:#77736b">还没有视频</li>')
            data = page.encode()
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)
            return
        if u.path.startswith("/videofile/"):
            fname = os.path.basename(u.path[len("/videofile/"):])
            p = os.path.join(VIDEO_DIR, fname)
            if os.path.isfile(p):
                sz = os.path.getsize(p)
                ext = os.path.splitext(fname)[1].lower()
                mime = "video/mp4" if ext == ".mp4" else "video/quicktime" if ext == ".mov" else "application/octet-stream"
                self.send_response(200)
                self.send_header("Content-Type", mime)
                self.send_header("Content-Length", str(sz))
                self.send_header("Cache-Control", "no-store")
                self.end_headers()
                with open(p, "rb") as f:
                    while chunk := f.read(64*1024):
                        self.wfile.write(chunk)
                return
            self.send_response(404); self.end_headers(); return
        self.send_response(404)
        self.end_headers()

    def do_POST(self):
        u = urlparse(self.path)
        # 视频上传（/video）
        if u.path == "/video":
            n = int(self.headers.get("Content-Length", 0))
            data = self.rfile.read(n)
            m = re.search(rb'filename="([^"]+)"', data)
            if not m:
                self.send_response(400); self.end_headers(); return
            fname = os.path.basename(m.group(1).decode("utf-8", errors="replace"))
            boundary = self.headers.get("Content-Type", "").split("boundary=")[-1].encode()
            parts = data.split(b"--" + boundary)
            for p in parts:
                if b"Content-Type:" in p and b"\r\n\r\n" in p:
                    head, body = p.split(b"\r\n\r\n", 1)
                    if body.endswith(b"\r\n"):
                        body = body[:-2]
                    if fname and len(body) > 1024:
                        out = os.path.join(VIDEO_DIR, fname)
                        with open(out, "wb") as f:
                            f.write(body)
                        print(f"[video] {fname} ({len(body)/1024/1024:.2f} MB) -> {out}", flush=True)
                        break
            self.send_response(303); self.send_header("Location", "/video"); self.end_headers()
            return
        if u.path == "/video-list":
            self.send_response(303); self.send_header("Location", "/video"); self.end_headers()
            return
        if u.path != "/upload":
            self.send_response(404)
            self.end_headers()
            return
        qs = parse_qs(u.query)
        name = (qs.get("name") or [""])[0].strip()
        if not name:
            self.send_response(400)
            self.end_headers()
            self.wfile.write(b"missing name")
            return
        name = os.path.basename(name)
        ctype = self.headers.get("Content-Type", "")
        if "multipart/form-data" in ctype:
            # 浏览器 XHR send(file) 是原始二进制；form 表单则走 multipart
            form = cgi.FieldStorage(
                fp=self.rfile,
                headers=self.headers,
                environ={"REQUEST_METHOD": "POST", "CONTENT_TYPE": ctype})
            body = b""
            if form and form.file:
                body = form.file.read()
        else:
            length = int(self.headers.get("Content-Length", 0))
            body = self.rfile.read(length) if length > 0 else b""
        if not body:
            self.send_response(400)
            self.end_headers()
            self.wfile.write(b"empty body")
            return
        path = os.path.join(SAVE_DIR, name)
        with open(path, "wb") as f:
            f.write(body)
        self.send_response(200)
        self.send_header("Content-Type", "text/plain; charset=utf-8")
        self.end_headers()
        self.wfile.write(f"OK saved {name} {len(body)} bytes".encode())

    def log_message(self, *a):
        pass

if __name__ == "__main__":
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 8001
    srv = HTTPServer(("0.0.0.0", port), Handler)
    print(f"upload server on :{port}, save to {SAVE_DIR}")
    srv.serve_forever()
