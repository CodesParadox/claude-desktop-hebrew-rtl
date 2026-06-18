'use strict';

const test = require('node:test');
const assert = require('node:assert');
const core = require('../src/rtl-core.js');

const cp = (s) => s.codePointAt(0);

test('isRTL covers Hebrew only', () => {
    assert.ok(core.isRTL(cp('א')), 'Hebrew aleph');
    assert.ok(core.isRTL(cp('ת')), 'Hebrew tav');
    assert.ok(core.isRTL(cp('ﬡ')), 'Hebrew presentation form');
    assert.ok(!core.isRTL(cp('ا')), 'Arabic is NOT treated as RTL (Hebrew-only scope)');
    assert.ok(!core.isRTL(cp('ܐ')), 'Syriac is NOT treated as RTL');
    assert.ok(!core.isRTL(cp('A')), 'Latin');
    assert.ok(!core.isRTL(cp('5')), 'digit');
    assert.ok(!core.isRTL(cp('$')), 'dollar');
});

test('hasRTL detects Hebrew, ignores Arabic', () => {
    assert.ok(core.hasRTL('hello שלום'));
    assert.ok(core.hasRTL('בדיקה'));
    assert.ok(!core.hasRTL('plain ascii 123'));
    assert.ok(!core.hasRTL('price $5.99'));
    assert.ok(!core.hasRTL('مرحبا'), 'Arabic-only text is not RTL in Hebrew-only scope');
});

test('firstStrong picks first strong character', () => {
    assert.strictEqual(core.firstStrong('שלום world'), 'rtl');
    assert.strictEqual(core.firstStrong('world שלום'), 'ltr');
    assert.strictEqual(core.firstStrong('123 — שלום'), 'rtl');
    assert.strictEqual(core.firstStrong('123 456'), null);
});

test('currency $ is NOT treated as LaTeX', () => {
    assert.deepStrictEqual(core.findLatexRanges('המחיר הוא $5.99 היום'), []);
    assert.deepStrictEqual(core.findLatexRanges('עולה $5 עד $10'), []);
    assert.deepStrictEqual(core.findLatexRanges('costs $20 and $30'), []);
});

test('real LaTeX is detected', () => {
    assert.strictEqual(core.findLatexRanges('זה $x^2$ פה').length, 1);
    assert.strictEqual(core.findLatexRanges('נוסחה $$\\frac{a}{b}$$ כאן').length, 1);
    assert.strictEqual(core.findLatexRanges('inline \\(a+b\\) here').length, 1);
    assert.strictEqual(core.findLatexRanges('block \\[E=mc^2\\] done').length, 1);
});

test('$$ wins over inner single $', () => {
    const ranges = core.findLatexRanges('a $$x = 5$$ b');
    assert.strictEqual(ranges.length, 1);
    assert.strictEqual('a $$x = 5$$ b'.slice(ranges[0][0], ranges[0][1]), '$$x = 5$$');
});

test('segmentText splits text and math', () => {
    const segs = core.segmentText('עברית $x^2$ עוד');
    assert.strictEqual(segs.length, 3);
    assert.strictEqual(segs[0].type, 'text');
    assert.strictEqual(segs[1].type, 'math');
    assert.strictEqual(segs[1].value, '$x^2$');
    assert.strictEqual(segs[2].type, 'text');
});

test('segmentText with no math returns single text segment', () => {
    const segs = core.segmentText('סתם טקסט עם $5 מחיר');
    assert.strictEqual(segs.length, 1);
    assert.strictEqual(segs[0].type, 'text');
});

test('cellDir: contains-Hebrew beats first-strong (header starting with Latin term)', () => {
    assert.strictEqual(core.cellDir('blob מקומי (HEAD c16c988)'), 'rtl');
    assert.strictEqual(core.cellDir('blob מה-CDN'), 'rtl');
    assert.strictEqual(core.cellDir('קובץ'), 'rtl');
    assert.strictEqual(core.cellDir('patch.ps1'), 'ltr');
    assert.strictEqual(core.cellDir('9f954eb'), 'ltr');
    assert.strictEqual(core.cellDir('123.45'), null);
});

test('tableDirFromCells: header majority RTL -> rtl', () => {
    const headers = [core.firstStrong('עברית'), core.firstStrong('English'), core.firstStrong('תעתיק')];
    assert.strictEqual(core.tableDirFromCells(headers, []), 'rtl');
});

test('table with Latin-first Hebrew headers flips', () => {
    const headers = ['קובץ', 'blob מקומי (HEAD c16c988)', 'blob מה-CDN', 'תוצאה'].map(core.cellDir);
    const firstCol = ['patch.ps1', 'patch.ps1.sig'].map(core.cellDir);
    assert.deepStrictEqual(headers, ['rtl', 'rtl', 'rtl', 'rtl']);
    assert.strictEqual(core.tableDirFromCells(headers, firstCol), 'rtl');
});

test('mostly-English table does NOT flip even with one Hebrew header', () => {
    const headers = ['Name', 'Value', 'שם'].map(core.cellDir);
    assert.strictEqual(core.tableDirFromCells(headers, []), null);
});

test('tableDirFromCells: header majority LTR -> null (no flip)', () => {
    const headers = [core.firstStrong('Name'), core.firstStrong('Value'), core.firstStrong('שם')];
    assert.strictEqual(core.tableDirFromCells(headers, []), null);
});

test('tableDirFromCells: first column tie-breaks when headers are inconclusive', () => {
    const headers = [null, null];
    const firstCol = [core.firstStrong('שלום'), core.firstStrong('תודה'), core.firstStrong('בית')];
    assert.strictEqual(core.tableDirFromCells(headers, firstCol), 'rtl');
});

test('stripLeadingLTR drops leading filename then detects RTL', () => {
    const stripped = core.stripLeadingLTR('foo.js שלום עולם');
    assert.strictEqual(core.firstStrong(stripped), 'rtl');
});
