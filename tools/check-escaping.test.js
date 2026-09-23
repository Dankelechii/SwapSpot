#!/usr/bin/env node
'use strict';

/**
 * Proves check-escaping.js catches the bugs it exists for.
 *
 * A checker nobody has tried to fool is a checker nobody knows works. Each
 * case below re-introduces a hole that was really shipped to the live site,
 * by editing a copy of index.html in a temp file, and asserts the checker
 * fails on it. The last case asserts the real file passes, so the two halves
 * cannot both be satisfied by a checker that just always fails.
 *
 *   node tools/check-escaping.test.js
 */

const fs = require('fs');
const os = require('os');
const path = require('path');
const { execFileSync } = require('child_process');

const ROOT = path.resolve(__dirname, '..');
const CHECKER = path.join(__dirname, 'check-escaping.js');
const SOURCE = fs.readFileSync(path.join(ROOT, 'index.html'), 'utf8');

function runOn(html) {
  const tmp = path.join(fs.mkdtempSync(path.join(os.tmpdir(), 'chkesc-')), 'index.html');
  fs.writeFileSync(tmp, html);
  try {
    execFileSync(process.execPath, [CHECKER], {
      env: { ...process.env, CHECK_ESCAPING_TARGET: tmp },
      stdio: 'pipe',
    });
    return { failed: false, output: '' };
  } catch (e) {
    return { failed: true, output: String(e.stdout || '') + String(e.stderr || '') };
  } finally {
    fs.rmSync(path.dirname(tmp), { recursive: true, force: true });
  }
}

// Each case removes the escaping from a real sink, the way the bug looked.
const cases = [
  {
    name: 'a display name rendered raw on the listing card',
    from: 'Swap with <b>${escapeHtml(l.owner)}</b>',
    to: 'Swap with <b>${l.owner}</b>',
  },
  {
    name: 'a bay number rendered raw inside the SVG <text>',
    from: 'opacity="0.85">${escapeHtml(code)}</text>',
    to: 'opacity="0.85">${code}</text>',
  },
  {
    name: 'an avatar url rendered raw into an img src',
    from: '<img src="${escapeHtml(user.avatar)}">',
    to: '<img src="${user.avatar}">',
  },
  {
    name: 'a display name passed through jsId into an inline handler',
    from: 'onclick="toggleFavMember(${attrJsId(memberKey(l))})"',
    to: 'onclick="toggleFavMember(${jsId(l.owner)})"',
  },
  {
    name: 'a street rendered raw in the booking modal',
    from: '${escapeHtml(l.bay)} · ${escapeHtml(l.street)}</div>',
    to: '${l.bay} · ${l.street}</div>',
  },
];

let failures = 0;

for (const c of cases) {
  if (!SOURCE.includes(c.from)) {
    console.error(`SKIP (anchor moved, update this test): ${c.name}\n       looked for: ${c.from}`);
    failures++;
    continue;
  }
  const mutated = SOURCE.replace(c.from, c.to);
  const { failed, output } = runOn(mutated);
  if (failed) {
    console.log(`  caught: ${c.name}`);
  } else {
    console.error(`  MISSED: ${c.name}`);
    console.error(`          checker said: ${output.trim().slice(0, 200)}`);
    failures++;
  }
}

// and the real file must pass, or "catches everything" is trivially true
const real = runOn(SOURCE);
if (real.failed) {
  console.error('  MISSED: index.html as committed should be clean');
  console.error(real.output.trim().slice(0, 600));
  failures++;
} else {
  console.log('  clean:  index.html as committed');
}

if (failures) {
  console.error(`\n${failures} case${failures === 1 ? '' : 's'} wrong.`);
  process.exit(1);
}
console.log(`\n${cases.length + 1} cases, all correct.`);
