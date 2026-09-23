#!/usr/bin/env node
'use strict';

/**
 * Fails when a template literal that builds markup interpolates a value that
 * has not been escaped.
 *
 * Why this exists: index.html builds every screen by assigning template
 * literals to innerHTML, and the values come from other members- display
 * names, bay numbers, street names. Three times now a field has reached
 * innerHTML raw, twice as a working stored XSS on the live site. Each time it
 * was found by reading a list of candidates by eye, and twice the bug was in
 * the list and got read past. A list you read is not a control. This exits
 * non-zero instead.
 *
 * How it decides:
 *
 *   1. Scan the inline script for template literals, tracking strings,
 *      comments and regexes so nesting is handled properly.
 *   2. A template is "markup" if its text contains a tag.
 *   3. In a markup template, every ${...} must be provably safe: wrapped in
 *      escapeHtml() or attrJsId(), or one of the helpers that returns markup
 *      it is itself responsible for (ICONS, starHTML, ticketCard, ...).
 *   4. Anything else is a candidate and must appear, character for character,
 *      in tools/escaping-allowlist.json- a file of expressions that have been
 *      looked at and found to be numbers, booleans, class names or literals.
 *
 * So the default is deny. A new unescaped interpolation fails until someone
 * either escapes it or writes it down as deliberately safe, which is a
 * decision rather than an oversight.
 *
 *   node tools/check-escaping.js            check, exit 1 on any finding
 *   node tools/check-escaping.js --list     print every candidate and its verdict
 *   node tools/check-escaping.js --update   rewrite the allowlist from the
 *                                           current file (review the diff!)
 */

const fs = require('fs');
const path = require('path');

const ROOT = path.resolve(__dirname, '..');
// overridable so check-escaping.test.js can run it against mutated copies
const TARGET = process.env.CHECK_ESCAPING_TARGET || path.join(ROOT, 'index.html');
const ALLOWLIST = path.join(__dirname, 'escaping-allowlist.json');

/* Calls that are responsible for their own output. escapeHtml and attrJsId
   escape; the rest return markup this file builds and checks elsewhere. */
const SAFE_CALLS = [
  'escapeHtml', 'attrJsId',
  'starHTML', 'starsHTML', 'ratingHTML', 'bayPhotoSVG', 'liveMapEmbed',
  'radiusChipsHTML', 'ticketCard', 'renderVerifyBlock', 'communityCompactHTML',
  'bayRow', 'actionFor',
];
/* jsId is deliberately NOT here. It builds a JS literal for an inline
   handler, which is not the same as being safe in an HTML attribute: a value
   containing a double quote ends the attribute early and the rest is parsed
   as markup. attrJsId is the one that survives both parsers. */
const SAFE_IDENTS = ['ICONS', 'STAR_PATH', 'TERMS_HTML'];

/* ------------------------------------------------------------------ */
/* scanning                                                            */
/* ------------------------------------------------------------------ */

function inlineScript(html) {
  const out = [];
  const re = /<script(?![^>]*\bsrc=)[^>]*>([\s\S]*?)<\/script>/g;
  let m;
  while ((m = re.exec(html))) out.push({ code: m[1], offset: m.index + m[0].indexOf(m[1]) });
  return out;
}

function lineOf(html, index) {
  let line = 1;
  for (let i = 0; i < index && i < html.length; i++) if (html[i] === '\n') line++;
  return line;
}

// A '/' starts a regex only where a value cannot already have ended.
function regexAllowed(src, i) {
  for (let j = i - 1; j >= 0; j--) {
    const c = src[j];
    if (c === ' ' || c === '\t' || c === '\n' || c === '\r') continue;
    return '(,=:[!&|?{};+-*%~^<>'.indexOf(c) !== -1 || /[\s]/.test(c);
  }
  return true;
}

function scanTemplates(src, base) {
  const templates = [];
  let i = 0;
  const n = src.length;

  const skipLine = () => { while (i < n && src[i] !== '\n') i++; };
  const skipBlock = () => { i += 2; while (i < n && !(src[i] === '*' && src[i + 1] === '/')) i++; i += 2; };
  const skipQuoted = (q) => {
    i++;
    while (i < n) {
      if (src[i] === '\\') { i += 2; continue; }
      if (src[i] === q) { i++; return; }
      i++;
    }
  };
  const skipRegex = () => {
    i++;
    let inClass = false;
    while (i < n) {
      const c = src[i];
      if (c === '\\') { i += 2; continue; }
      if (c === '[') inClass = true;
      else if (c === ']') inClass = false;
      else if (c === '/' && !inClass) { i++; while (i < n && /[a-z]/i.test(src[i])) i++; return; }
      else if (c === '\n') return;
      i++;
    }
  };

  function parseExpr() {
    const start = i;
    let depth = 0;
    while (i < n) {
      const c = src[i];
      if (c === '/' && src[i + 1] === '/') { skipLine(); continue; }
      if (c === '/' && src[i + 1] === '*') { skipBlock(); continue; }
      if (c === '/' && regexAllowed(src, i)) { skipRegex(); continue; }
      if (c === "'" || c === '"') { skipQuoted(c); continue; }
      if (c === '`') { parseTemplate(); continue; }
      if (c === '{') { depth++; i++; continue; }
      if (c === '}') {
        if (depth === 0) { const text = src.slice(start, i); i++; return { text, start }; }
        depth--; i++; continue;
      }
      i++;
    }
    return { text: src.slice(start, i), start };
  }

  function parseTemplate() {
    const start = i;
    i++;
    let text = '';
    const exprs = [];
    while (i < n) {
      const c = src[i];
      if (c === '\\') { text += src.substr(i, 2); i += 2; continue; }
      if (c === '`') { i++; break; }
      if (c === '$' && src[i + 1] === '{') {
        i += 2;
        const e = parseExpr();
        exprs.push(e);
        text += '\u0001';
        continue;
      }
      text += c; i++;
    }
    templates.push({ text, exprs, start: base + start });
    return templates[templates.length - 1];
  }

  while (i < n) {
    const c = src[i];
    if (c === '/' && src[i + 1] === '/') { skipLine(); continue; }
    if (c === '/' && src[i + 1] === '*') { skipBlock(); continue; }
    if (c === '/' && regexAllowed(src, i)) { skipRegex(); continue; }
    if (c === "'" || c === '"') { skipQuoted(c); continue; }
    if (c === '`') { parseTemplate(); continue; }
    i++;
  }
  return templates;
}

/* ------------------------------------------------------------------ */
/* classifying                                                         */
/* ------------------------------------------------------------------ */

const looksLikeMarkup = (text) => /<[a-zA-Z/!]/.test(text);

/* Only the value positions of an expression reach the page. In
   `hot ? 'flame' : 'person'` the condition never lands in the markup, so
   flagging `hot` is noise that trains people to ignore the check. These
   helpers walk down to the parts whose value is actually emitted. */

// A copy with the contents of strings, templates and regexes blanked out, so
// operators can be found by index without tripping over punctuation in text.
function mask(e) {
  const out = e.split('');
  let i = 0;
  const n = e.length;
  const blank = (from, to) => { for (let k = from; k < to && k < n; k++) if (out[k] !== '\n') out[k] = ' '; };
  while (i < n) {
    const c = e[i];
    if (c === "'" || c === '"' || c === '`') {
      const q = c;
      const start = i;
      i++;
      let depth = 0;
      while (i < n) {
        if (e[i] === '\\') { i += 2; continue; }
        if (q === '`' && e[i] === '$' && e[i + 1] === '{') { depth++; i += 2; continue; }
        if (q === '`' && depth > 0 && e[i] === '}') { depth--; i++; continue; }
        if (e[i] === q && depth === 0) { i++; break; }
        i++;
      }
      blank(start, i);
      continue;
    }
    i++;
  }
  return out.join('');
}

function depths(m) {
  const d = new Array(m.length).fill(0);
  let cur = 0;
  for (let i = 0; i < m.length; i++) {
    const c = m[i];
    if (c === '(' || c === '[' || c === '{') { d[i] = cur; cur++; continue; }
    if (c === ')' || c === ']' || c === '}') { cur--; d[i] = cur; continue; }
    d[i] = cur;
  }
  return d;
}

// `cond ? a : b` -> { then: a, else: b }, or null
function splitTernary(e) {
  const m = mask(e), d = depths(m);
  for (let i = 0; i < m.length; i++) {
    if (m[i] !== '?' || d[i] !== 0) continue;
    if (m[i + 1] === '?' || m[i + 1] === '.') continue;   // ?? and ?.
    if (m[i - 1] === '?') continue;
    let nest = 0;
    for (let j = i + 1; j < m.length; j++) {
      if (d[j] !== 0) continue;
      if (m[j] === '?' && m[j + 1] !== '?' && m[j + 1] !== '.' && m[j - 1] !== '?') { nest++; continue; }
      if (m[j] === ':') {
        if (nest > 0) { nest--; continue; }
        return { then: e.slice(i + 1, j), else: e.slice(j + 1) };
      }
    }
    return null;
  }
  return null;
}

// Split on a top-level binary operator, returning the operand list.
function splitTop(e, op) {
  const m = mask(e), d = depths(m);
  const parts = [];
  let last = 0;
  for (let i = 0; i < m.length; i++) {
    if (d[i] !== 0) continue;
    if (m.startsWith(op, i)) {
      // not part of a longer operator, and not a unary plus
      if (op === '+' && (m[i + 1] === '+' || m[i - 1] === '+')) { i++; continue; }
      parts.push(e.slice(last, i));
      i += op.length - 1;
      last = i + 1;
    }
  }
  if (!parts.length) return null;
  parts.push(e.slice(last));
  return parts;
}

const LITERAL = /^(?:'(?:\\.|[^'\\])*'|"(?:\\.|[^"\\])*"|-?\d+(?:\.\d+)?|true|false|null|undefined)$/;
const TEMPLATE = /^`[\s\S]*`$/;
const SAFE_CALL_RE = new RegExp('^(?:' + SAFE_CALLS.join('|') + ')\\s*\\(');
const SAFE_IDENT_RE = new RegExp('^(?:' + SAFE_IDENTS.join('|') + ')\\b');

// The argument of a top-level .map()/.flatMap(), when the whole expression is
// that call and at most a .join() after it. Found by balancing parens rather
// than by regex: a greedy match happily pairs the opening paren with the
// closing paren of the .join(), which silently mangles the callback body.
function mapCallbackArg(e) {
  const m = mask(e), d = depths(m);
  for (let i = 0; i < m.length; i++) {
    if (d[i] !== 0 || m[i] !== '.') continue;
    const head = /^\.\s*(?:map|flatMap)\s*\(/.exec(m.slice(i));
    if (!head) continue;
    const open = i + head[0].length - 1;
    let depth = 0, j = open;
    for (; j < m.length; j++) {
      if (m[j] === '(') depth++;
      else if (m[j] === ')') { depth--; if (depth === 0) break; }
    }
    if (j >= m.length) return null;
    const rest = mask(e.slice(j + 1)).trim();
    if (rest && !/^\.\s*join\s*\([^()]*\)$/.test(rest)) return null;
    return e.slice(open + 1, j);
  }
  return null;
}

// Everything whose value can land in the markup, flattened to leaves.
function valueLeaves(expr) {
  let e = expr.trim();
  if (!e) return [];

  // (x) -> x
  while (e.startsWith('(') && e.endsWith(')')) {
    const m = mask(e), d = depths(m);
    let closedEarly = false;
    for (let i = 1; i < e.length - 1; i++) if (d[i] === 0) { closedEarly = true; break; }
    if (closedEarly) break;
    e = e.slice(1, -1).trim();
  }

  const tern = splitTernary(e);
  if (tern) return [...valueLeaves(tern.then), ...valueLeaves(tern.else)];

  // `a && b` emits b when a is truthy, and a falsy a renders as nothing
  // worth attacking, so only b is a value position.
  const and = splitTop(e, '&&');
  if (and) return valueLeaves(and[and.length - 1]);

  for (const op of ['||', '+']) {
    const parts = splitTop(e, op);
    if (parts) return parts.flatMap(valueLeaves);
  }

  // arr.map(x => `...`).join('') - the callback's own template is scanned in
  // its own right, so follow the callback body rather than the receiver.
  const cbArg = mapCallbackArg(e);
  if (cbArg !== null) {
    const body = cbArg.replace(/^[\s\S]*?=>/, '').trim();
    if (body && body !== cbArg.trim()) return valueLeaves(body);
  }

  // A block-bodied arrow emits whatever it returns, so follow the returns.
  if (e.startsWith('{') && e.endsWith('}')) {
    const inner = e.slice(1, -1);
    const m = mask(inner), d = depths(m);
    const outs = [];
    for (let i = 0; i < m.length; i++) {
      if (d[i] !== 0 || !m.startsWith('return', i)) continue;
      if (i > 0 && /[\w$.]/.test(m[i - 1])) continue;
      if (/[\w$]/.test(m[i + 6] || '')) continue;
      let j = i + 6;
      while (j < m.length && !(d[j] === 0 && m[j] === ';')) j++;
      outs.push(inner.slice(i + 6, j));
    }
    if (outs.length) return outs.flatMap(valueLeaves);
  }

  return [e];
}

function isSafeLeaf(leaf) {
  const e = leaf.trim();
  if (!e) return true;
  if (LITERAL.test(e)) return true;
  if (TEMPLATE.test(e)) return true;              // scanned as its own template
  if (SAFE_CALL_RE.test(e)) return true;
  if (SAFE_IDENT_RE.test(e)) return true;
  return false;
}

function unsafeLeaves(expr) {
  return valueLeaves(expr).filter(l => !isSafeLeaf(l)).map(l => l.trim().replace(/\s+/g, ' '));
}

function isProvablySafe(expr) {
  return unsafeLeaves(expr).length === 0;
}

/* ------------------------------------------------------------------ */
/* run                                                                 */
/* ------------------------------------------------------------------ */

function collect() {
  const html = fs.readFileSync(TARGET, 'utf8');
  const candidates = [];
  for (const { code, offset } of inlineScript(html)) {
    for (const t of scanTemplates(code, offset)) {
      if (!looksLikeMarkup(t.text)) continue;
      for (const e of t.exprs) {
        for (const leaf of unsafeLeaves(e.text)) {
          candidates.push({ expr: leaf, line: lineOf(html, offset + e.start) });
        }
      }
    }
  }
  return candidates;
}

function loadAllowlist() {
  if (!fs.existsSync(ALLOWLIST)) return [];
  const j = JSON.parse(fs.readFileSync(ALLOWLIST, 'utf8'));
  return Array.isArray(j.allowed) ? j.allowed : [];
}

const args = process.argv.slice(2);
const candidates = collect();

if (args.includes('--update')) {
  const allowed = [...new Set(candidates.map(c => c.expr))].sort();
  fs.writeFileSync(ALLOWLIST, JSON.stringify({
    comment: 'Interpolations in markup templates that are not escaped and have been reviewed as safe (numbers, booleans, class names, literal-only ternaries). Read the diff before committing a change to this file: adding a line here is a decision that something cannot carry member-supplied text.',
    allowed,
  }, null, 2) + '\n');
  console.log(`wrote ${allowed.length} entries to ${path.relative(ROOT, ALLOWLIST)}`);
  process.exit(0);
}

const allowed = new Set(loadAllowlist());
const findings = candidates.filter(c => !allowed.has(c.expr));

if (args.includes('--list')) {
  for (const c of candidates) {
    console.log(`${allowed.has(c.expr) ? 'allowed ' : 'FINDING '} index.html:${c.line}  ${c.expr.slice(0, 100)}`);
  }
  console.log(`\n${candidates.length} candidates, ${findings.length} not allowlisted`);
}

if (findings.length === 0) {
  if (!args.includes('--list')) {
    console.log(`check-escaping: clean (${candidates.length} reviewed interpolations allowlisted)`);
  }
  process.exit(0);
}

console.error('\ncheck-escaping: unescaped values in markup templates\n');
for (const f of findings) {
  console.error(`  index.html:${f.line}`);
  console.error(`    ${f.expr.slice(0, 140)}\n`);
}
console.error(`${findings.length} interpolation${findings.length === 1 ? '' : 's'} reaching markup without escapeHtml() or attrJsId().`);
console.error('Wrap it, or if it genuinely cannot carry member-supplied text, add it to');
console.error(`${path.relative(ROOT, ALLOWLIST)} (node tools/check-escaping.js --update).\n`);
process.exit(1);
