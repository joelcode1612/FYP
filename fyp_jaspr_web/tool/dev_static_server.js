// Minimal static server with SPA fallback for verifying the BUILT client-mode
// Jaspr bundle (pubspec `jaspr: mode: client`). The previous server-mode
// workflow (build/jaspr/app.exe) no longer applies: deep routes are resolved
// client-side, so any unknown path falls back to index.html.
//
// Usage: PORT=8090 node tool/dev_static_server.js
const http = require('http');
const fs = require('fs');
const path = require('path');

const root = path.join(__dirname, '..', 'build', 'jaspr');
const port = Number(process.env.PORT || 8090);
const types = {
  '.html': 'text/html; charset=utf-8',
  '.css': 'text/css; charset=utf-8',
  '.js': 'text/javascript; charset=utf-8',
  '.json': 'application/json',
  '.png': 'image/png',
  '.jpg': 'image/jpeg',
  '.svg': 'image/svg+xml',
  '.woff2': 'font/woff2',
  '.woff': 'font/woff',
  '.webp': 'image/webp',
  '.map': 'application/json',
  '.txt': 'text/plain; charset=utf-8',
};

http
  .createServer((req, res) => {
    const urlPath = decodeURIComponent(req.url.split('?')[0]);
    let file = path.join(root, urlPath);
    if (!fs.existsSync(file) || fs.statSync(file).isDirectory()) {
      file = path.join(root, 'index.html');
    }
    fs.readFile(file, (err, data) => {
      if (err) {
        res.writeHead(404, { 'content-type': 'text/plain' });
        res.end('not found');
        return;
      }
      res.writeHead(200, {
        'content-type': types[path.extname(file)] || 'application/octet-stream',
        'cache-control': 'no-store',
      });
      res.end(data);
    });
  })
  .listen(port, '127.0.0.1', () => {
    console.log(`static build server on http://127.0.0.1:${port}`);
  });
