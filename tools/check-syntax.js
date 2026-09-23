#!/usr/bin/env node
'use strict';

/**
 * Fails when the inline script in index.html will not parse.
 *
 * index.html is the whole app and main is the deploy branch, so a syntax
 * error is not a broken build- there is no build. It is a blank page on the
 * live site, served within about a minute of the push, with no earlier
 * version still standing. This is the cheapest possible guard against that.
 *
 * It compiles the script without running it, which is what `node --check`
 * does, and reports the line in index.html rather than in the extracted
 * fragment.
 *
 *   node tools/check-syntax.js
 */

const fs = require('fs');
const path = require('path');
const vm = require('vm');

const ROOT = path.resolve(__dirname, '..');
const TARGET = process.env.CHECK_SYNTAX_TARGET || path.join(ROOT, 'index.html');

const html = fs.readFileSync(TARGET, 'utf8');
const re = /<script(?![^>]*\bsrc=)[^>]*>([\s\S]*?)<\/script>/g;

let m;
let blocks = 0;
let failed = false;

while ((m = re.exec(html))) {
  blocks++;
  const code = m[1];
  const startIndex = m.index + m[0].indexOf(code);
  const lineOffset = html.slice(0, startIndex).split('\n').length - 1;
  try {
    // compiles and throws on a syntax error, without executing anything
    new vm.Script(code, { filename: 'index.html' });
  } catch (e) {
    failed = true;
    const where = /index\.html:(\d+)/.exec(e.stack || '');
    const line = where ? Number(where[1]) + lineOffset : null;
    console.error('\ncheck-syntax: index.html will not parse\n');
    console.error(`  ${line ? `index.html:${line}` : 'index.html'}`);
    console.error(`    ${e.message}\n`);
  }
}

if (!blocks) {
  console.error('check-syntax: found no inline script in index.html, which is not expected');
  process.exit(1);
}
if (failed) process.exit(1);

console.log(`check-syntax: clean (${blocks} inline script block${blocks === 1 ? '' : 's'} parse)`);
