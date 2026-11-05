// Minimal SPA-fallback static server for the built `build/jaspr` output.
//
// The Jaspr build emits a single `index.html` at the root and relies on
// client-side `jaspr_router` for deep links (e.g. /login, /login?portal=staff).
// Netlify handles this via `_redirects` (`/* /index.html 200`); a plain static
// server returns 404 on deep routes. This server serves real files when they
// exist and falls back to index.html otherwise so client routing works for
// local verification of the production build.
//
// The handler is wrapped so a transient error (e.g. files momentarily missing
// while `jaspr build` rewrites `build/jaspr`) returns a 404/500 response
// instead of crashing the whole process.
//
// Usage: node tool/serve_spa.js [port] [rootDir]
const http = require('http');
const fs = require('fs');
const path = require('path');

const PORT = Number(process.argv[2] || 8141);
const ROOT = path.resolve(process.argv[3] || path.join(__dirname, '..', 'build', 'jaspr'));

const MIME = {
  '.html': 'text/html; charset=utf-8',
  '.js': 'text/javascript; charset=utf-8',
  '.mjs': 'text/javascript; charset=utf-8',
  '.css': 'text/css; charset=utf-8',
  '.json': 'application/json; charset=utf-8',
  '.map': 'application/json; charset=utf-8',
  '.svg': 'image/svg+xml',
  '.png': 'image/png',
  '.jpg': 'image/jpeg',
  '.jpeg': 'image/jpeg',
  '.webp': 'image/webp',
  '.gif': 'image/gif',
  '.ico': 'image/x-icon',
  '.woff': 'font/woff',
  '.woff2': 'font/woff2',
  '.ttf': 'font/ttf',
  '.eot': 'application/vnd.ms-fontobject',
};

function send(res, status, body, type) {
  if (res.headersSent) return;
  res.writeHead(status, { 'Content-Type': type || 'text/plain; charset=utf-8' });
  res.end(body);
}

const server = http.createServer((req, res) => {
  let urlPath;
  try {
    urlPath = decodeURIComponent((req.url || '/').split('?')[0]);
  } catch (e) {
    return send(res, 400, 'Bad request');
  }
  if (urlPath === '/') urlPath = '/index.html';

  const filePath = path.join(ROOT, path.normalize(urlPath));
  if (!filePath.startsWith(ROOT)) {
    return send(res, 403, 'Forbidden');
  }

  fs.stat(filePath, (err, stat) => {
    if (!err && stat.isFile()) {
      const ext = path.extname(filePath).toLowerCase();
      fs.readFile(filePath, (rerr, data) => {
        if (rerr) return send(res, 500, 'Read error');
        send(res, 200, data, MIME[ext] || 'application/octet-stream');
      });
      return;
    }
    // SPA fallback: serve index.html for unknown (extension-less) routes.
    if (!path.extname(urlPath)) {
      const idx = path.join(ROOT, 'index.html');
      fs.readFile(idx, (ierr, data) => {
        if (ierr) return send(res, 404, 'index.html not found (build may be in progress)');
        send(res, 200, data, MIME['.html']);
      });
      return;
    }
    return send(res, 404, 'Not found');
  });
});

server.on('error', (e) => {
  console.error('Server error:', e.message);
});

server.listen(PORT, '127.0.0.1', () => {
  console.log(`SPA fallback server on http://127.0.0.1:${PORT} (root: ${ROOT})`);
});
