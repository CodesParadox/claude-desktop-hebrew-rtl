'use strict';

// DOM-level tests for src/rtl-payload.js using jsdom (no Electron / Claude needed).
//
// We assemble the payload exactly like tools/build-payload.ps1 does -- inline the
// pure core into the /*__RTL_CORE__*/ marker -- then run it inside a jsdom window
// and assert the direction outcomes on real DOM nodes. This covers the layer the
// reference repo never tested: the renderer payload itself.

const test = require('node:test');
const assert = require('node:assert');
const fs = require('node:fs');
const path = require('node:path');
const { JSDOM } = require('jsdom');

function assemblePayload() {
    let core = fs.readFileSync(path.join(__dirname, '../src/rtl-core.js'), 'utf8');
    const guard = core.indexOf('if (typeof module !==');
    if (guard >= 0) core = core.slice(0, guard).trimEnd();
    const pay = fs.readFileSync(path.join(__dirname, '../src/rtl-payload.js'), 'utf8');
    if (pay.indexOf('/*__RTL_CORE__*/') < 0) throw new Error('core marker missing in rtl-payload.js');
    return pay.replace('/*__RTL_CORE__*/', core);
}

const PAYLOAD = assemblePayload();

// Build a jsdom document with the given <body> HTML, optionally with an <html dir>,
// then execute the payload in that window. Returns the jsdom window.
function runPayload(bodyHtml, opts) {
    opts = opts || {};
    const htmlDir = opts.htmlDir ? ' dir="' + opts.htmlDir + '"' : '';
    const dom = new JSDOM(
        '<!DOCTYPE html><html' + htmlDir + '><head></head><body>' + bodyHtml + '</body></html>',
        { runScripts: 'outside-only', pretendToBeVisual: true }
    );
    dom.window.eval(PAYLOAD);
    // jsdom with runScripts:'outside-only' leaves readyState='loading', so the
    // payload defers init() to DOMContentLoaded. Fire it deterministically.
    if (dom.window.document.readyState === 'loading') {
        dom.window.document.dispatchEvent(new dom.window.Event('DOMContentLoaded', { bubbles: true }));
    }
    return dom.window;
}

const delay = (ms) => new Promise((r) => setTimeout(r, ms));

test('payload assembles with the Hebrew-only core inlined (no Arabic ranges)', () => {
    assert.ok(PAYLOAD.indexOf('[0x0590, 0x05FF]') >= 0, 'Hebrew range present');
    assert.ok(PAYLOAD.indexOf('[0x0600, 0x06FF]') < 0, 'Arabic range must NOT be present');
    assert.ok(PAYLOAD.indexOf('/*__RTL_CORE__*/') < 0, 'marker should have been replaced');
});

test('Hebrew paragraph becomes RTL', () => {
    const win = runPayload('<p id="t">שלום עולם, זו פסקה בעברית</p>');
    assert.strictEqual(win.document.getElementById('t').getAttribute('dir'), 'rtl');
});

test('English paragraph is not forced RTL', () => {
    const win = runPayload('<p id="t">Hello world, this is English</p>');
    assert.notStrictEqual(win.document.getElementById('t').getAttribute('dir'), 'rtl');
});

test('code block stays LTR even with Hebrew inside', () => {
    const win = runPayload('<pre id="c">שלום const x = 1;</pre>');
    assert.strictEqual(win.document.getElementById('c').getAttribute('dir'), 'ltr');
});

test('inline code is pinned LTR', () => {
    const win = runPayload('<p id="t">הפונקציה <code id="c">useState()</code> מחזירה מערך</p>');
    assert.strictEqual(win.document.getElementById('c').getAttribute('dir'), 'ltr');
    assert.strictEqual(win.document.getElementById('t').getAttribute('dir'), 'rtl');
});

test('input box (chat-input) flips to RTL for Hebrew', () => {
    const win = runPayload('<div data-testid="chat-input" id="in">שלום קלוד</div>');
    assert.strictEqual(win.document.getElementById('in').style.direction, 'rtl');
});

test('input box stays LTR for English', () => {
    const win = runPayload('<div data-testid="chat-input" id="in">hello claude</div>');
    assert.strictEqual(win.document.getElementById('in').style.direction, 'ltr');
});

test('window chrome is forced LTR even when the shell starts RTL', () => {
    const win = runPayload('<p>שלום</p>', { htmlDir: 'rtl' });
    assert.strictEqual(win.document.documentElement.getAttribute('dir'), 'ltr');
});

test('raw LaTeX is isolated into an LTR island inside an RTL paragraph', () => {
    const win = runPayload('<p id="m">הנוסחה $x^2 + 1$ מופיעה כאן</p>');
    const island = win.document.querySelector('[data-rtl-island]');
    assert.ok(island, 'an LTR math island span should be created');
    assert.strictEqual(island.style.direction, 'ltr');
    assert.strictEqual(island.textContent, '$x^2 + 1$');
    assert.strictEqual(win.document.getElementById('m').getAttribute('dir'), 'rtl');
});

test('currency $ is NOT isolated as math', () => {
    const win = runPayload('<p id="p">המחיר הוא $5 או $10 בלבד</p>');
    assert.strictEqual(win.document.querySelector('[data-rtl-island]'), null);
    assert.strictEqual(win.document.getElementById('p').getAttribute('dir'), 'rtl');
});

test('a Hebrew table is flipped to RTL column order', () => {
    const win = runPayload(
        '<table id="tbl"><thead><tr><th>שם</th><th>ערך</th></tr></thead>' +
        '<tbody><tr><td>אחד</td><td>1</td></tr></tbody></table>'
    );
    assert.strictEqual(win.document.getElementById('tbl').getAttribute('dir'), 'rtl');
});

test('an English table is not flipped', () => {
    const win = runPayload(
        '<table id="tbl"><thead><tr><th>Name</th><th>Value</th></tr></thead>' +
        '<tbody><tr><td>one</td><td>1</td></tr></tbody></table>'
    );
    assert.notStrictEqual(win.document.getElementById('tbl').getAttribute('dir'), 'rtl');
});

test('streaming: a Hebrew paragraph added after load is processed by the observer', async () => {
    const win = runPayload('<div id="root"></div>');
    const doc = win.document;
    const p = doc.createElement('p');
    p.id = 'streamed';
    p.textContent = 'תוכן שמגיע בהזרמה מאוחר יותר';
    doc.body.appendChild(p);
    await delay(200); // observer throttle (50ms) + jsdom scheduling
    assert.strictEqual(doc.getElementById('streamed').getAttribute('dir'), 'rtl');
});
