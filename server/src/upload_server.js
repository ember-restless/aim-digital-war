// AIM 素材接收服务 — 独立端口 8001
// 用途：牢大把收款码 / Logo 传上来：
//   POST /upload        → public/downloads/wechat_qr.png
//   POST /upload_logo   → public/downloads/logo.png
// 支持两种上传方式：
//   1. multipart/form-data:  curl -F "file=@qr.png" http://<host>:8001/upload
//   2. JSON base64:          curl -H "Content-Type: application/json" -d '{"base64":"..."}' http://<host>:8001/upload
// GET /  -> 网页上传页（拖拽/选择 + 预览 + 当前生效图）
'use strict';
const http = require('http');
const fs = require('fs');
const path = require('path');

const PORT = 8001;
const SAVE_DIR = path.join(__dirname, '..', 'public', 'downloads');
const TARGETS = {
  upload: { file: path.join(SAVE_DIR, 'wechat_qr.png'), key: 'qr' },
  upload_logo: { file: path.join(SAVE_DIR, 'logo.png'), key: 'logo' },
  upload_image: { file: path.join(SAVE_DIR, 'aim_upload.png'), key: 'gen' }, // 通用图片（B 站素材/截图等，离离读图用）
};

fs.mkdirSync(SAVE_DIR, { recursive: true });

function sendJson(res, code, obj) {
  const body = JSON.stringify(obj);
  res.writeHead(code, { 'Content-Type': 'application/json; charset=utf-8' });
  res.end(body);
}

// 解析 multipart/form-data，取出第一个文件字段的二进制
function parseMultipart(buf, contentType) {
  const m = /boundary=(?:"([^"]+)"|([^;]+))/i.exec(contentType || '');
  if (!m) return null;
  const boundary = '--' + (m[1] || m[2]);
  const parts = buf.toString('binary').split(boundary);
  for (const part of parts) {
    if (!part || part.trim() === '--') continue;
    if (part.startsWith('--')) continue;
    const headerEnd = part.indexOf('\r\n\r\n');
    if (headerEnd < 0) continue;
    const header = part.slice(0, headerEnd);
    const bodyBin = part.slice(headerEnd + 4);
    const data = bodyBin.replace(/\r\n$/, '');
    if (!/name="/i.test(header)) continue;
    const nameM = /name="([^"]+)"/i.exec(header);
    if (!nameM) continue;
    const fieldName = nameM[1];
    if (fieldName === 'file' || fieldName === 'image' || fieldName === 'qr' || fieldName === 'logo') {
      return Buffer.from(data, 'binary');
    }
  }
  return null;
}

function saveImage(res, buf, target, okMsg) {
  if (!buf || buf.length === 0) {
    sendJson(res, 400, { ok: false, msg: '没解析到图片，请用 -F "file=@xx.png" 或 JSON base64' });
    return;
  }
  if (fs.existsSync(target.file)) {
    try { fs.copyFileSync(target.file, target.file + '.bak'); } catch (e) { /* ignore */ }
  }
  fs.writeFileSync(target.file, buf);
  sendJson(res, 200, { ok: true, msg: okMsg, size: buf.length, url: path.basename(target.file) });
}

function handleUpload(req, res, target, okMsg) {
  const chunks = [];
  let size = 0;
  req.on('data', c => {
    size += c.length;
    if (size > 10 * 1024 * 1024) {
      req.destroy();
      sendJson(res, 413, { ok: false, msg: '图片太大（上限 10MB）' });
      return;
    }
    chunks.push(c);
  });
  req.on('end', () => {
    const buf = Buffer.concat(chunks);
    const ctype = req.headers['content-type'] || '';
    let image = null;
    if (ctype.startsWith('multipart/form-data')) {
      image = parseMultipart(buf, ctype);
    } else if (ctype.includes('application/json')) {
      try {
        const obj = JSON.parse(buf.toString('utf8'));
        image = obj.base64 ? Buffer.from(obj.base64, 'base64') : null;
      } catch (e) { /* fallthrough */ }
    }
    if (!image || image.length === 0) {
      // 表单提交失败 → 跳回页面提示
      if (req.url.includes('form=1')) {
        res.writeHead(302, { Location: '/?err=parse' });
        res.end();
        return;
      }
      sendJson(res, 400, { ok: false, msg: '没解析到图片，请用 -F "file=@xx.png" 或 JSON base64' });
      return;
    }
    if (fs.existsSync(target.file)) {
      try { fs.copyFileSync(target.file, target.file + '.bak'); } catch (e) { /* ignore */ }
    }
    fs.writeFileSync(target.file, image);
    if (req.url.includes('form=1')) {
      res.writeHead(302, { Location: '/?ok=1' });
      res.end();
      return;
    }
    sendJson(res, 200, { ok: true, msg: okMsg, size: image.length, url: path.basename(target.file) });
  });
}

// 网页上传页（两个上传卡片：收款码 / Logo）
function pageHtml(qrExists, logoExists, genExists, host) {
  return `<!DOCTYPE html>
<html lang="zh">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>AIM · 素材上传</title>
<style>
  * { margin: 0; padding: 0; box-sizing: border-box; }
  body {
    background: #0d1020; color: #e8e8ff;
    font-family: 'Courier New', monospace;
    min-height: 100vh; display: flex; align-items: center; justify-content: center;
    padding: 16px; image-rendering: pixelated;
  }
  .row { display: flex; gap: 16px; flex-wrap: wrap; justify-content: center; }
  .card {
    background: #141a30; border: 3px solid #3a4a7a;
    box-shadow: 0 0 0 3px #0d1020, 0 0 0 6px #3a4a7a, 0 8px 0 rgba(0,0,0,.5);
    padding: 24px; width: 100%; max-width: 400px; text-align: center;
  }
  h1 { font-size: 18px; letter-spacing: 2px; color: #ffd75e; margin-bottom: 4px; text-shadow: 2px 2px 0 #000; }
  .sub { font-size: 12px; color: #8fa0d0; margin-bottom: 16px; }
  .drop {
    border: 3px dashed #3a4a7a; background: #0f1530; padding: 22px 10px;
    cursor: pointer; transition: all .15s; font-size: 13px; color: #aab8e8;
    position: relative; overflow: hidden;
  }
  .legacy { margin-top: 18px; padding-top: 14px; border-top: 1px dashed #3a4a7a; font-size: 12px; color: #8fa0d0; }
  .legacy input[type=file] { color: #aab8e8; font-size: 12px; margin-bottom: 8px; }
  .legacy button {
    background: #3a6ea5; color: #fff; border: 2px solid #6aa8e0;
    padding: 8px 18px; font-family: inherit; font-size: 13px; cursor: pointer;
  }
  .drop:hover, .drop.over { border-color: #ffd75e; background: #161d3a; color: #ffd75e; }
  .preview {
    max-width: 220px; max-height: 160px; margin: 14px auto; display: none;
    image-rendering: pixelated; border: 3px solid #3a4a7a; background: #000;
  }
  .preview.show { display: block; }
  .btn {
    display: block; width: 100%; margin-top: 12px; padding: 13px;
    font-family: inherit; font-size: 15px; letter-spacing: 3px;
    background: #3a6ea5; color: #fff; border: 3px solid #6aa8e0; border-bottom-width: 6px;
    cursor: pointer; text-shadow: 1px 1px 0 #000;
  }
  .btn:hover { background: #4a7eb5; }
  .btn:active { transform: translateY(3px); border-bottom-width: 3px; }
  .btn:disabled { background: #2a3a5a; border-color: #4a5a7a; cursor: not-allowed; }
  .status { margin-top: 12px; font-size: 13px; min-height: 20px; }
  .ok { color: #6fe06f; } .err { color: #ff7070; }
  .cur { margin-top: 10px; font-size: 12px; color: #8fa0d0; }
  .cur img { max-width: 140px; max-height: 100px; margin-top: 8px; border: 2px solid #3a4a7a; background: #000; }
</style>
</head>
<body>
<div class="row">
  ${card('✦ 投喂收款码 ✦', '微信收款码，投喂按钮用的', 'upload', 'wechat_qr', qrExists, 'qr')}
  ${card('✦ 开机 Logo ✦', '透明底白字 logo，启动页淡入用', 'upload_logo', 'logo', logoExists, 'logo')}
  ${card('✦ 通用图片 ✦', '任意截图/素材（离离读取分析）', 'upload_image', 'gen', genExists, 'gen')}
</div>
<script>
  function pick(input, preview, up, status, file) {
    if (file.size > 10 * 1024 * 1024) { status.className = 'status err'; status.textContent = '图片太大（上限 10MB）'; return; }
    input._f = file;
    try { preview.src = URL.createObjectURL(file); } catch (e) { preview.src = ''; }
    preview.classList.add('show');
    up.disabled = false;
    status.className = 'status';
    status.textContent = '已选：' + file.name + '（' + Math.round(file.size / 1024) + ' KB）';
  }
  function uploadNow(target, input, up, status, curId) {
    if (!input._f) return;
    up.disabled = true; status.className = 'status'; status.textContent = '传送中…';
    const fd = new FormData();
    fd.append('file', input._f);
    fetch('/' + target, { method: 'POST', body: fd })
      .then(r => r.json())
      .then(d => {
        if (d.ok) {
          status.className = 'status ok';
          status.textContent = '✅ 成功！已生效';
          document.getElementById(curId).innerHTML = '<img src="/preview_' + target + '?t=' + Date.now() + '">';
        } else {
          status.className = 'status err';
          status.textContent = '失败：' + (d.msg || '未知错误');
          up.disabled = false;
        }
      })
      .catch(e => { status.className = 'status err'; status.textContent = '网络错误：' + e; up.disabled = false; });
  }
  function bind(target, previewId, upId, statusId, curId) {
    const drop = document.getElementById(target + '_drop');
    const input = document.getElementById(target + '_file');
    const preview = document.getElementById(previewId);
    const up = document.getElementById(upId);
    const status = document.getElementById(statusId);
    // input 透明铺满 drop，点击/选择都是原生行为；拖拽事件绑在 input 上（冒泡到 drop）
    input.ondragover = e => { e.preventDefault(); drop.classList.add('over'); };
    input.ondragleave = () => drop.classList.remove('over');
    input.ondrop = e => { e.preventDefault(); drop.classList.remove('over'); if (e.dataTransfer.files[0]) pick(input, preview, up, status, e.dataTransfer.files[0]); };
    // 选完文件立即自动上传（不需要点任何按钮）
    input.onchange = () => {
      if (input.files && input.files[0]) {
        pick(input, preview, up, status, input.files[0]);
        uploadNow(target, input, up, status, curId);
      }
    };
    // 「传送」按钮：自动上传失败时手动重试
    up.onclick = () => uploadNow(target, input, up, status, curId);
  }
  bind('upload', 'qr_preview', 'qr_up', 'qr_status', 'qr_cur');
  bind('upload_logo', 'logo_preview', 'logo_up', 'logo_status', 'logo_cur');
  bind('upload_image', 'gen_preview', 'gen_up', 'gen_status', 'gen_cur');
</script>
</body>
</html>`;

  function card(title, sub, target, key, exists, curId) {
    const cur = exists ? '已上传' : '还没有';
    return `<div class="card">
  <h1>${title}</h1>
  <div class="sub">${sub}</div>
  <div class="drop" id="${target}_drop">
    点击选择图片<br>或直接拖进来<br><br>
    <span style="color:#6aa8e0">支持 png / jpg</span>
    <input type="file" id="${target}_file" accept="image/*"
           style="position:absolute; inset:0; width:100%; height:100%; opacity:0; cursor:pointer;">
  </div>
  <img class="preview" id="${key}_preview" alt="预览">
  <button class="btn" id="${key}_up" disabled>传 送</button>
  <div class="status" id="${key}_status">当前：${cur}</div>
  <div class="cur" id="${key}_cur">${exists ? '<img src="/preview_' + target + '?t=' + Date.now() + '">' : ''}</div>
  <div class="legacy">📎 如果上面自动上传没反应，用这个经典方式：
    <form action="/${target}?form=1" method="post" enctype="multipart/form-data">
      <input type="file" name="file" accept="image/*">
      <button type="submit">选择并上传</button>
    </form>
  </div>
</div>`;
  }
}

const server = http.createServer((req, res) => {
  const url = (req.url || '/').split('?')[0];
  console.log(`[AIM-upload] ${new Date().toISOString()} ${req.method} ${req.url} from ${req.socket.remoteAddress}`);
  res.on('finish', () => console.log(`  → ${res.statusCode}`));

  if (req.method === 'GET') {
    const qrExists = fs.existsSync(TARGETS.upload.file);
    const logoExists = fs.existsSync(TARGETS.upload_logo.file);
    const genExists = fs.existsSync(TARGETS.upload_image.file);
    if (url === '/preview_upload') {
      if (!qrExists) { sendJson(res, 404, { ok: false, msg: '还没有收款码' }); return; }
      res.writeHead(200, { 'Content-Type': 'image/png', 'Cache-Control': 'no-store' });
      fs.createReadStream(TARGETS.upload.file).pipe(res);
      return;
    }
    if (url === '/preview_upload_logo') {
      if (!logoExists) { sendJson(res, 404, { ok: false, msg: '还没有 Logo' }); return; }
      res.writeHead(200, { 'Content-Type': 'image/png', 'Cache-Control': 'no-store' });
      fs.createReadStream(TARGETS.upload_logo.file).pipe(res);
      return;
    }
    if (url === '/preview_upload_image') {
      if (!genExists) { sendJson(res, 404, { ok: false, msg: '还没有图片' }); return; }
      res.writeHead(200, { 'Content-Type': 'image/png', 'Cache-Control': 'no-store' });
      fs.createReadStream(TARGETS.upload_image.file).pipe(res);
      return;
    }
    res.writeHead(200, { 'Content-Type': 'text/html; charset=utf-8' });
    res.end(pageHtml(qrExists, logoExists, genExists, req.headers.host));
    return;
  }

  if (req.method === 'POST') {
    if (url === '/upload') {
      handleUpload(req, res, TARGETS.upload, '收款码已更新');
      return;
    }
    if (url === '/upload_logo') {
      handleUpload(req, res, TARGETS.upload_logo, 'Logo 已更新');
      return;
    }
    if (url === '/upload_image') {
      handleUpload(req, res, TARGETS.upload_image, '图片已更新');
      return;
    }
  }

  sendJson(res, 404, { ok: false, msg: 'not found' });
});

server.listen(PORT, () => {
  console.log(`[AIM-upload] 素材接收端口 ${PORT} 已启动`);
  console.log(`  GET  ${PORT}/                  上传页（收款码 + Logo）`);
  console.log(`  POST ${PORT}/upload             收款码 → downloads/wechat_qr.png`);
  console.log(`  POST ${PORT}/upload_logo        Logo   → downloads/logo.png`);
});
