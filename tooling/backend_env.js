// Small shared parser for SiteWise's local KEY=VALUE environment files.
// It does not execute shell syntax, expand variables, or log any values.
'use strict';

const fs = require('fs');

function readBackendEnv(file) {
  const values = {};
  const raw = fs.readFileSync(file, 'utf8').replace(/^\uFEFF/, '');
  for (const line of raw.split(/\r?\n/)) {
    const match = line.match(/^\s*(?:export\s+)?([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*?)\s*$/);
    if (!match) continue;
    let value = match[2];
    if ((value.startsWith('"') && value.endsWith('"')) ||
        (value.startsWith("'") && value.endsWith("'"))) {
      value = value.slice(1, -1);
    } else {
      value = value.replace(/\s+#.*$/, '');
    }
    values[match[1]] = value.trim();
  }
  return values;
}

module.exports = { readBackendEnv };
