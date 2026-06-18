#Requires -Version 5.1
<#
.SYNOPSIS
    Claude Desktop Hebrew RTL patch -- operator tool (Windows, PowerShell 5.1).
.DESCRIPTION
    Patches the Squirrel/winget build of Claude Desktop so Hebrew renders naturally
    in the input box and in streaming replies, while keeping the window chrome LTR.

    Integrity bypass strategy:
      PRIMARY  : disable the Electron fuse EnableEmbeddedAsarIntegrityValidation
                 via @electron/fuses on Claude.exe.
      FALLBACK : byte-patch the ASAR header SHA-256 hash inside Claude.exe (only on
                 a single, unambiguous match). Never touches the trusted root store.
      On any failure -> automatic rollback from .bak.

    Hebrew only. Squirrel-only (MSIX/Store installs are refused). Backs up every
    modified file. Idempotent. Supports -DryRun for destructive operations.

    The injected renderer payload lives between the CLAUDE RTL PATCH markers below
    and is assembled from src/rtl-core.js + src/rtl-payload.js by
    tools/build-payload.ps1. Do not hand-edit the payload here; edit src/ and rebuild.
.NOTES
    Run via install.ps1 (which verifies the signature first), or directly.
#>
[CmdletBinding()]
param(
    [switch]$DryRun,
    [string]$TrustedPubKey = '',
    [ValidateSet('', 'install', 'restore')]
    [string]$Action = '',
    [switch]$NonInteractive
)

$ErrorActionPreference = 'Stop'
$script:DryRun = [bool]$DryRun

# Pinned npm packages. Bump by hand after testing a new Claude release.
$script:AsarPackage  = '@electron/asar@4.2.0'
$script:FusesPackage = '@electron/fuses@2.1.1'

# Idempotency marker prepended to the patched main-process file.
$script:Marker = '/*__CLAUDE_HEBREW_RTL__*/'
$script:FuseName = 'EnableEmbeddedAsarIntegrityValidation'

# Per-user state / logs (no admin required for a per-user Squirrel install).
$script:DataDir   = Join-Path $env:LOCALAPPDATA 'ClaudeHebrewRtl'
$script:StateFile = Join-Path $script:DataDir 'state.json'
$script:LogFile   = Join-Path $script:DataDir 'patch.log'
$script:TaskName  = 'ClaudeHebrewRtlAutoRepatch'

# Rollback stack of script blocks (LIFO).
$script:Rollback = New-Object System.Collections.Stack

# ---------------------------------------------------------------------------
# RTL payload (assembled by tools/build-payload.ps1 -- DO NOT hand edit).
# ---------------------------------------------------------------------------
$RTL_INJECTION_CODE = @'
// --- CLAUDE RTL PATCH START ---
;(function() {
    'use strict';
    if (typeof document === 'undefined') return;
    if (window.__claudeHebrewRtl) return; // idempotent: never install twice
    window.__claudeHebrewRtl = true;
    try {
        var WRITING_SEL = '[data-testid="chat-input"]';

        // Streaming tunables. THROTTLE_MS coalesces bursts of mutations during a
        // streaming reply; MAX_ROOTS caps targeted processing before we fall back to
        // a full pass (prevents pathological churn on huge subtree changes).
        var THROTTLE_MS = 50;
        var MAX_ROOTS = 30;

        // --- PURE DETECTION CORE (inlined from src/rtl-core.js by build-payload.ps1) ---
        // rtl-core.js -- pure, DOM-free Hebrew RTL / LaTeX detection logic.
//
// SOURCE OF TRUTH for the detection engine. tools/build-payload.ps1 inlines the
// function bodies of this file into the injected IIFE inside patch.ps1 (it strips
// the module.exports guard at the bottom). test/rtl-core.test.js requires this
// file directly. Keep this file DOM-free so it stays unit-testable.
//
// SCOPE: Hebrew only. We deliberately do NOT detect Arabic, Syriac, Thaana, etc.
// The product targets Hebrew users; treating other RTL scripts as RTL here would
// be out of scope and could mis-handle content the user did not ask us to flip.
'use strict';

// Strong-RTL code-point ranges for HEBREW only, [lo, hi] inclusive.
//   0x0590-0x05FF  Hebrew (letters, points, cantillation, punctuation)
//   0xFB1D-0xFB4F  Hebrew presentation forms (wide/ligature/pointed variants)
// Tested against code points (codePointAt), not UTF-16 code units.
var RTL_RANGES = [
    [0x0590, 0x05FF], // Hebrew
    [0xFB1D, 0xFB4F]  // Hebrew presentation forms
];

// cp: a Unicode code point (from String.prototype.codePointAt).
function isRTL(cp) {
    for (var i = 0; i < RTL_RANGES.length; i++) {
        if (cp >= RTL_RANGES[i][0] && cp <= RTL_RANGES[i][1]) return true;
    }
    return false;
}

// True if the text contains at least one Hebrew character.
function hasRTL(text) {
    if (!text) return false;
    for (var i = 0; i < text.length;) {
        var cp = text.codePointAt(i);
        if (isRTL(cp)) return true;
        i += cp > 0xFFFF ? 2 : 1;
    }
    return false;
}

// Direction of the first strong character: 'rtl', 'ltr', or null (no strong char).
// Hebrew letters are strong-RTL; ASCII Latin letters are strong-LTR.
function firstStrong(text) {
    if (!text) return null;
    for (var i = 0; i < text.length;) {
        var cp = text.codePointAt(i);
        if (isRTL(cp)) return 'rtl';
        if ((cp >= 0x41 && cp <= 0x5A) || (cp >= 0x61 && cp <= 0x7A)) return 'ltr';
        i += cp > 0xFFFF ? 2 : 1;
    }
    return null;
}

// Remove leading LTR-only noise (filenames, URLs, paths, backtick-code) so a
// Hebrew sentence that starts with "foo.js" still detects as RTL.
function stripLeadingLTR(text) {
    return text
        .replace(/^[\s]*(?:[\w.\-]+\.[\w]{1,5})\s*/g, '')
        .replace(/https?:\/\/\S+/g, '')
        .replace(/[\w.\-]+[\/\\][\w.\-\/\\]+/g, '')
        .replace(/`[^`]+`/g, '');
}

// A "$...$" body is treated as math only when it carries a real LaTeX signal.
// This is the currency guard: "$5.99" or "$5 to $10" lack the signal and stay text.
var LATEX_SIGNAL = /[\\^_{}]|\b(?:frac|sqrt|sum|prod|int|lim|infty|cdot|times|div|leq|geq|neq|approx|partial|nabla|alpha|beta|gamma|delta|theta|lambda|mu|pi|sigma|omega|matrix|begin|end|left|right|text|mathbb|mathcal|vec|hat|bar|overline|underline)\b/;

function hasLatexSignal(body) {
    return LATEX_SIGNAL.test(body);
}

// Find math regions as [start, end) index pairs over `text`.
// Unambiguous delimiters ($$...$$, \[...\], \(...\)) always count; single $...$
// only counts with a LaTeX signal and only outside already-claimed regions.
function findLatexRanges(text) {
    var ranges = [];
    if (!text) return ranges;

    function overlaps(s, e) {
        for (var i = 0; i < ranges.length; i++) {
            if (s < ranges[i][1] && e > ranges[i][0]) return true;
        }
        return false;
    }
    function claim(re, requireSignal, bodyStart, bodyEnd) {
        var m;
        re.lastIndex = 0;
        while ((m = re.exec(text)) !== null) {
            var start = m.index;
            var end = m.index + m[0].length;
            if (overlaps(start, end)) continue;
            if (requireSignal) {
                var body = m[0].slice(bodyStart, m[0].length - bodyEnd);
                if (!hasLatexSignal(body)) continue;
            }
            ranges.push([start, end]);
        }
    }

    // Order matters: claim the unambiguous, greedier delimiters first.
    claim(/\$\$[\s\S]+?\$\$/g, false, 0, 0);
    claim(/\\\[[\s\S]+?\\\]/g, false, 0, 0);
    claim(/\\\([\s\S]+?\\\)/g, false, 0, 0);
    // Single $...$ -- no newline inside, must carry a LaTeX signal (currency guard).
    claim(/\$[^$\n]+?\$/g, true, 1, 1);

    ranges.sort(function (a, b) { return a[0] - b[0]; });
    return ranges;
}

// Split text into alternating {type:'text'|'math', value} segments.
function segmentText(text) {
    var segs = [];
    if (!text) return segs;
    var ranges = findLatexRanges(text);
    if (!ranges.length) {
        segs.push({ type: 'text', value: text });
        return segs;
    }
    var pos = 0;
    for (var i = 0; i < ranges.length; i++) {
        if (ranges[i][0] > pos) {
            segs.push({ type: 'text', value: text.slice(pos, ranges[i][0]) });
        }
        segs.push({ type: 'math', value: text.slice(ranges[i][0], ranges[i][1]) });
        pos = ranges[i][1];
    }
    if (pos < text.length) segs.push({ type: 'text', value: text.slice(pos) });
    return segs;
}

// Classify a table cell's direction from its text. A cell counts as RTL if it
// *contains* any Hebrew character -- not merely if its first strong char is RTL.
// Header labels often start with a Latin term ("blob ...", "ID ...") yet belong
// to a Hebrew column, so first-strong is too weak here. Neutral cells (digits,
// hashes, punctuation only) return null so they do not sway the majority.
function cellDir(text) {
    if (hasRTL(text)) return 'rtl';
    if (firstStrong(text) === 'ltr') return 'ltr';
    return null;
}

// Header wins; first column is the tie-breaker. Returns 'rtl' (flip columns) or
// null (leave LTR). Each input is an array of 'rtl' | 'ltr' | null.
function tableDirFromCells(headerDirs, firstColDirs) {
    if (headerDirs && headerDirs[0] === 'rtl' &&
            firstColDirs && firstColDirs[0] === 'rtl') return 'rtl';
    var h = majorityDir(headerDirs || []);
    if (h === 'rtl') return 'rtl';
    if (h === 'ltr') return null;
    var c = majorityDir(firstColDirs || []);
    return c === 'rtl' ? 'rtl' : null;
}

function majorityDir(dirs) {
    var r = 0, l = 0;
    for (var i = 0; i < dirs.length; i++) {
        if (dirs[i] === 'rtl') r++;
        else if (dirs[i] === 'ltr') l++;
    }
    if (r > l) return 'rtl';
    if (l > r) return 'ltr';
    return null;
}
        // --- END PURE DETECTION CORE ---

        // --- WINDOW CHROME: FORCE LTR -------------------------------------------
        //
        // On a Hebrew-locale Windows, Claude Desktop sets the whole window shell to
        // RTL (<html dir="rtl">). That mirrors the layout: the OS title-bar window
        // controls (minimize/maximize/close) collide with Claude's own nav/settings
        // controls, and the preview panel jumps to the far left. We pin the root
        // shell to LTR so the chrome/layout never mirrors. Chat *content* direction
        // is still applied per-element below, so Hebrew text stays right-to-left
        // inside an LTR shell.
        function forceChromeLTR() {
            var html = document.documentElement;
            if (html) {
                if (html.getAttribute('dir') !== 'ltr') html.setAttribute('dir', 'ltr');
                html.style.direction = 'ltr';
            }
            if (document.body && document.body.getAttribute('dir') === 'rtl') {
                document.body.setAttribute('dir', 'ltr');
                document.body.style.direction = 'ltr';
            }
        }

        // Get text from element excluding <code>/<pre> children (DOM-aware).
        function textWithoutCode(el) {
            var out = '';
            var nodes = el.childNodes;
            for (var i = 0; i < nodes.length; i++) {
                var n = nodes[i];
                if (n.nodeType === 3) { out += n.textContent; }
                else if (n.nodeType === 1 && n.tagName !== 'CODE' && n.tagName !== 'PRE') {
                    out += textWithoutCode(n);
                }
            }
            return out;
        }

        // --- PER-LINE DIRECTIONAL SPLITTING ---
        //
        // A paragraph carrying multiple lines (via <br> or newlines), each in a
        // different script, cannot take a single dir without mangling lines that
        // disagree. We defer to unicode-bidi:plaintext (each line auto-picks its
        // direction from its first-strong char) and flag it so later passes skip it.
        var RTL_SPLIT_FLAG = 'data-rtl-split';
        var BR_OR_NL_SPLIT = /(<br\s*\/?>|\n)/i;

        function hasMultiScriptLines(el) {
            var src = el.textContent;
            if (!src) return false;
            if (!/[a-zA-Z]{2,}/.test(src)) return false;
            if (!hasRTL(src)) return false;
            return BR_OR_NL_SPLIT.test(el.innerHTML) || src.indexOf('\n') !== -1;
        }

        function splitToDirectionalSpans(el) {
            if (el.hasAttribute(RTL_SPLIT_FLAG)) return;
            // No DOM rewriting -- assigning innerHTML breaks React reconciliation.
            // unicode-bidi:plaintext treats <br>/newlines as paragraph separators.
            el.setAttribute(RTL_SPLIT_FLAG, '1');
            if (el.hasAttribute('dir')) el.removeAttribute('dir');
            el.style.direction = '';
            el.style.textAlign = 'start';
            el.style.unicodeBidi = 'plaintext';
        }

        // If the element inherits RTL via a parent CSS class (not an explicit dir
        // on itself), removing dir alone won't free it -- pin direction=ltr.
        function resetDirOrPinLTR(el) {
            if (window.getComputedStyle(el).direction === 'rtl') {
                el.dir = 'ltr';
                el.style.direction = 'ltr';
                return;
            }
            if (el.hasAttribute('dir')) el.removeAttribute('dir');
            el.style.direction = '';
        }

        // --- HYBRID DIRECTION DETECTION ---

        // For DOM elements (output): 3-layer detection.
        function detectElDir(el) {
            var full = el.textContent || '';
            if (!hasRTL(full)) return null;

            var noCode = textWithoutCode(el);
            var d = firstStrong(noCode);
            if (d === 'rtl') return 'rtl';

            var stripped = stripLeadingLTR(noCode);
            d = firstStrong(stripped);
            if (d === 'rtl') return 'rtl';

            // Hebrew chars exist but hide behind code/filenames -> treat as RTL.
            return 'rtl';
        }

        // For plain text (input box, dialogs without DOM structure).
        function detectTextDir(text) {
            if (!text || !text.trim()) return null;
            var d = firstStrong(text);
            if (d === 'rtl') return 'rtl';
            if (!hasRTL(text)) return 'ltr';

            var stripped = stripLeadingLTR(text);
            d = firstStrong(stripped);
            if (d === 'rtl') return 'rtl';

            return 'rtl';
        }

        // --- ELEMENT PROCESSING ---

        // querySelectorAll that INCLUDES root itself if it matches.
        function qsa(root, sel) {
            var base = root.querySelectorAll ? root : document;
            var els = Array.prototype.slice.call(base.querySelectorAll(sel));
            if (root.matches && root.matches(sel)) els.unshift(root);
            return els;
        }

        function forceCodeLTR(root) {
            qsa(root, 'pre, .code-block__code, .relative.group\\/copy').forEach(function(b) {
                b.dir = 'ltr'; b.style.textAlign = 'left'; b.style.unicodeBidi = 'embed';
            });
            qsa(root, 'code').forEach(function(c) {
                if (!c.closest('pre') && !c.closest('.code-block__code')) c.dir = 'ltr';
            });
            // Rendered math (KaTeX/MathJax), if present, is an LTR island too.
            qsa(root, '.katex, .katex-display, mjx-container').forEach(function(m) {
                m.style.unicodeBidi = 'isolate'; m.style.direction = 'ltr';
            });
        }

        // --- RAW LaTeX ISOLATION ---
        //
        // Claude Desktop (Windows) often shows raw "$...$" text. Inside an RTL
        // paragraph the neutral $ \ { } chars scramble the formula. We isolate each
        // math segment in its own ltr/unicode-bidi:isolate span. We replace a single
        // TEXT node with a fragment (replaceChild) -- never innerHTML -- to stay
        // gentle on React, and flag islands so we never re-wrap during streaming.
        var ISLAND_FLAG = 'data-rtl-island';

        function isolateMath(root) {
            if (typeof document.createTreeWalker !== 'function') return;
            var host = (root && root.nodeType === 1) ? root : document.body;
            if (!host) return;
            var walker = document.createTreeWalker(host, NodeFilter.SHOW_TEXT, {
                acceptNode: function(node) {
                    var v = node.nodeValue;
                    if (!v || (v.indexOf('$') === -1 && v.indexOf('\\') === -1)) return NodeFilter.FILTER_REJECT;
                    var p = node.parentElement;
                    if (!p) return NodeFilter.FILTER_REJECT;
                    if (p.tagName === 'SCRIPT' || p.tagName === 'STYLE') return NodeFilter.FILTER_REJECT;
                    if (p.closest('pre, code, .code-block__code, [' + ISLAND_FLAG + '], ' + WRITING_SEL)) return NodeFilter.FILTER_REJECT;
                    return NodeFilter.FILTER_ACCEPT;
                }
            });
            var targets = [];
            var n;
            while ((n = walker.nextNode())) targets.push(n);
            targets.forEach(function(textNode) {
                var segs = segmentText(textNode.nodeValue);
                var hasMath = segs.some(function(s) { return s.type === 'math'; });
                if (!hasMath) return;
                var frag = document.createDocumentFragment();
                segs.forEach(function(s) {
                    if (s.type === 'math') {
                        var span = document.createElement('span');
                        span.setAttribute(ISLAND_FLAG, '1');
                        span.style.unicodeBidi = 'isolate';
                        span.style.direction = 'ltr';
                        span.textContent = s.value;
                        frag.appendChild(span);
                    } else {
                        frag.appendChild(document.createTextNode(s.value));
                    }
                });
                if (textNode.parentNode) textNode.parentNode.replaceChild(frag, textNode);
            });
        }

        // --- TABLE COLUMN ORDERING ---
        //
        // A Hebrew table should read right-to-left (first column on the right). We
        // only flip the whole table's column order via dir="rtl" on a stable <table>
        // element. Only flip once confident it is a Hebrew table; otherwise leave it
        // so a still-streaming table can re-evaluate later.
        var TABLE_FLAG = 'data-rtl-table';

        function processTables(root) {
            qsa(root, 'table').forEach(function(t) {
                if (t.getAttribute(TABLE_FLAG) === 'rtl') return;
                if (t.closest(WRITING_SEL)) return;
                var headerCells = Array.prototype.slice.call(t.querySelectorAll('thead th'));
                if (!headerCells.length) {
                    var firstRow = t.querySelector('tr');
                    if (firstRow) headerCells = Array.prototype.slice.call(firstRow.querySelectorAll('th, td'));
                }
                var headerDirs = headerCells.map(function(c) { return cellDir(c.textContent || ''); });
                var rows = Array.prototype.slice.call(t.querySelectorAll('tbody tr'));
                if (!rows.length) rows = Array.prototype.slice.call(t.querySelectorAll('tr')).slice(1);
                var firstColDirs = rows.map(function(r) {
                    var cell = r.querySelector('th, td');
                    return cell ? cellDir(cell.textContent || '') : null;
                });
                if (tableDirFromCells(headerDirs, firstColDirs) === 'rtl') {
                    t.setAttribute(TABLE_FLAG, 'rtl');
                    t.dir = 'rtl';
                    t.style.direction = 'rtl';
                }
            });
        }

        function processText(root) {
            qsa(root, 'p, li, h1, h2, h3, h4, h5, h6, blockquote, td, th, summary, label, dt, dd').forEach(function(el) {
                if (el.closest(WRITING_SEL) || el.closest('pre') || el.closest('.code-block__code')) return;
                if (el.hasAttribute(RTL_SPLIT_FLAG)) return;
                var dir = detectElDir(el);
                if (dir) {
                    if (dir === 'rtl' && hasMultiScriptLines(el)) {
                        splitToDirectionalSpans(el);
                        return;
                    }
                    el.dir = dir;
                    el.style.direction = dir;
                    if (el.tagName === 'LI') {
                        el.style.listStylePosition = (dir === 'rtl') ? 'inside' : '';
                        var parentList = el.closest('ul, ol');
                        if (parentList && dir === 'rtl' && !parentList.hasAttribute('dir')) {
                            parentList.dir = 'rtl';
                            parentList.style.direction = 'rtl';
                            var pl = getComputedStyle(parentList).paddingLeft;
                            if (parseFloat(pl) > 0) { parentList.style.paddingRight = pl; parentList.style.paddingLeft = '0'; }
                        }
                    }
                } else {
                    resetDirOrPinLTR(el);
                    if (el.tagName === 'LI') el.style.listStylePosition = '';
                }
            });

            qsa(root, 'ul, ol').forEach(function(el) {
                if (el.closest(WRITING_SEL) || el.closest('pre')) return;
                var dir = detectElDir(el);
                if (dir === 'rtl') {
                    el.dir = 'rtl';
                    el.style.direction = 'rtl';
                    var pl = getComputedStyle(el).paddingLeft;
                    if (parseFloat(pl) > 0) { el.style.paddingRight = pl; el.style.paddingLeft = '0'; }
                } else {
                    resetDirOrPinLTR(el);
                    el.style.paddingRight = ''; el.style.paddingLeft = '';
                }
            });
        }

        // Universal: process leaf text containers (dialogs, tooltips, etc.).
        function processContainers(root) {
            qsa(root, 'div, span, button, a, label').forEach(function(el) {
                if (el.closest('pre') || el.closest('code') || el.closest(WRITING_SEL)) return;
                if (el.hasAttribute(RTL_SPLIT_FLAG)) return;
                if (el.hasAttribute(ISLAND_FLAG)) return;
                var parent = el.parentElement;
                if (parent && parent.hasAttribute(RTL_SPLIT_FLAG)) return;
                if (el.querySelector('p, div, ul, ol, h1, h2, h3, h4, h5, h6, pre, table')) return;
                if (/^(P|LI|H[1-6]|BLOCKQUOTE|TD|TH|UL|OL)$/.test(el.tagName)) return;
                var text = (el.textContent || '').trim();
                if (text.length < 2) return;
                if (hasRTL(text)) {
                    if (hasMultiScriptLines(el)) {
                        splitToDirectionalSpans(el);
                    } else {
                        el.dir = detectTextDir(text) || 'rtl';
                        el.style.textAlign = 'start';
                    }
                } else if (el.hasAttribute('dir')) {
                    el.removeAttribute('dir');
                    el.style.textAlign = '';
                }
            });
        }

        function applyInputDir(el) {
            var text = el.textContent || el.innerText || el.value || '';
            var dir = detectTextDir(text);
            if (dir === 'rtl') {
                el.style.direction = 'rtl'; el.style.textAlign = 'right'; el.style.paddingRight = '25px';
            } else {
                el.style.direction = 'ltr'; el.style.textAlign = 'left'; el.style.paddingRight = '';
            }
        }

        function processInput() {
            document.querySelectorAll(WRITING_SEL).forEach(applyInputDir);
        }

        function processAll() {
            forceChromeLTR();
            isolateMath(document.body);
            processText(document);
            processContainers(document.body);
            processTables(document.body);
            processInput();
            forceCodeLTR(document.body);
        }

        function injectStyles() {
            if (document.getElementById('claude-hebrew-rtl-styles')) return;
            var s = document.createElement('style');
            s.id = 'claude-hebrew-rtl-styles';
            s.textContent = [
                // Keep the window shell/chrome LTR regardless of OS locale.
                'html{direction:ltr!important}',
                // Context-sensitive content: plaintext lets each block pick its own side.
                'p:not([dir]),li:not([dir]),h1:not([dir]),h2:not([dir]),h3:not([dir]),h4:not([dir]),h5:not([dir]),h6:not([dir]),blockquote:not([dir]),td:not([dir]),th:not([dir]),summary:not([dir]),label:not([dir]),legend:not([dir]),dt:not([dir]),dd:not([dir]),figcaption:not([dir]),caption:not([dir]){unicode-bidi:plaintext!important;text-align:start!important}',
                'pre,.code-block__code,.relative.group\\/copy{unicode-bidi:embed!important;direction:ltr!important;text-align:left!important}',
                'code{unicode-bidi:isolate!important;direction:ltr!important}',
                '[data-rtl-island]{unicode-bidi:isolate!important;direction:ltr!important}',
                '.katex,.katex-display,mjx-container{unicode-bidi:isolate!important;direction:ltr!important}',
                'table[dir="rtl"]{direction:rtl!important}',
                '[dir]{text-align:start!important}[dir="rtl"]{direction:rtl!important}[dir="ltr"]{direction:ltr!important}',
                '[dir]>*:not([dir]):not(pre):not(code):not(.code-block__code){unicode-bidi:plaintext;text-align:start}',
                '[dir="rtl"][class*="mask-image:linear-gradient(to_right"]{-webkit-mask-image:linear-gradient(to left,hsl(var(--always-black)) 85%,transparent 99%)!important;mask-image:linear-gradient(to left,hsl(var(--always-black)) 85%,transparent 99%)!important}',
                '.group:hover [dir="rtl"][class*="mask-image:linear-gradient(to_right"],.group:focus-within [dir="rtl"][class*="mask-image:linear-gradient(to_right"],[data-menu-open="true"] [dir="rtl"][class*="mask-image:linear-gradient(to_right"]{-webkit-mask-image:linear-gradient(to left,hsl(var(--always-black)) 60%,transparent 78%)!important;mask-image:linear-gradient(to left,hsl(var(--always-black)) 60%,transparent 78%)!important}'
            ].join('');
            (document.head || document.documentElement).appendChild(s);
        }

        function init() {
            injectStyles();
            forceChromeLTR();
            processAll();

            // Input box live direction switching as the user types.
            document.addEventListener('input', function(e) {
                var t = e.target;
                if (!t || !(t.tagName === 'TEXTAREA' || t.tagName === 'INPUT' || t.isContentEditable)) return;
                applyInputDir(t);
            }, true);

            // Watch DOM changes. Throttle (not debounce) so we process DURING streaming.
            var pendingMuts = [];
            var obs = new MutationObserver(function(muts) {
                var dominated = false;
                for (var i = 0; i < muts.length; i++) {
                    if (muts[i].addedNodes.length > 0 || muts[i].type === 'characterData') { dominated = true; break; }
                }
                if (!dominated) return;
                for (var j = 0; j < muts.length; j++) pendingMuts.push(muts[j]);
                if (window._rtlT) return; // throttle: already scheduled
                window._rtlT = setTimeout(function() {
                    window._rtlT = null;
                    var toProcess = pendingMuts;
                    pendingMuts = [];
                    var roots = new Set();
                    toProcess.forEach(function(m) {
                        m.addedNodes.forEach(function(n) { if (n.nodeType === 1) roots.add(n); });
                        if (m.type === 'characterData' && m.target.parentElement) roots.add(m.target.parentElement);
                    });
                    var expanded = new Set(roots);
                    roots.forEach(function(r) {
                        if (!r.closest) return;
                        var txt = r.closest('p, li, h1, h2, h3, h4, h5, h6, blockquote, td, th, summary, label, dt, dd');
                        if (txt) expanded.add(txt);
                        var list = r.closest('ul, ol');
                        if (list) expanded.add(list);
                        var tbl = r.closest('table');
                        if (tbl) expanded.add(tbl);
                    });
                    roots = expanded;
                    if (roots.size > 0 && roots.size <= MAX_ROOTS) {
                        roots.forEach(function(r) {
                            isolateMath(r);
                            processText(r);
                            processContainers(r);
                            processTables(r);
                            forceCodeLTR(r);
                        });
                        processInput();
                    } else {
                        processAll();
                    }
                }, THROTTLE_MS);
            });
            obs.observe(document.body, { childList: true, subtree: true, characterData: true });

            // Window-chrome guard: Claude's React shell can re-apply dir="rtl" to the
            // root element after load on a Hebrew-locale Windows. The content observer
            // above watches document.body, not attribute changes on <html>/<body>, so
            // a dedicated observer re-pins the shell to LTR whenever the dir attribute
            // is flipped back. The __chromeGuard flag prevents reacting to our own write.
            var chromeObs = new MutationObserver(function() {
                if (window.__chromeGuard) return;
                window.__chromeGuard = true;
                forceChromeLTR();
                window.__chromeGuard = false;
            });
            chromeObs.observe(document.documentElement, { attributes: true, attributeFilter: ['dir', 'style'] });
            if (document.body) {
                chromeObs.observe(document.body, { attributes: true, attributeFilter: ['dir', 'style'] });
            }
        }

        if (document.readyState === 'loading') {
            document.addEventListener('DOMContentLoaded', init);
        } else { init(); }
    } catch(e) { console.error('[Claude Hebrew RTL]', e); }
})();
// --- CLAUDE RTL PATCH END ---
'@

# ===========================================================================
# Logging helpers (color-coded host output + plain-text log file).
# ===========================================================================
function Write-LogToFile {
    param([string]$Level, [string]$Msg)
    try {
        if (-not (Test-Path $script:DataDir)) { New-Item -ItemType Directory -Path $script:DataDir -Force | Out-Null }
        $line = '{0} [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Msg
        Add-Content -Path $script:LogFile -Value $line -Encoding UTF8
    } catch { }
}
function Write-Log     ($msg) { Write-Host "  [*] $msg" -ForegroundColor Cyan;    Write-LogToFile 'INFO' $msg }
function Write-Step    ($msg) { Write-Host "`n>> $msg"  -ForegroundColor Magenta; Write-LogToFile 'STEP' $msg }
function Write-Success ($msg) { Write-Host "  [+] $msg" -ForegroundColor Green;   Write-LogToFile 'OK'   $msg }
function Write-Warn    ($msg) { Write-Host "  [!] $msg" -ForegroundColor Yellow;  Write-LogToFile 'WARN' $msg }
function Write-Err     ($msg) { Write-Host "  [x] $msg" -ForegroundColor Red;     Write-LogToFile 'ERR'  $msg }
function Write-Dry     ($msg) { Write-Host "  [dry-run] $msg" -ForegroundColor DarkGray; Write-LogToFile 'DRY' $msg }

# ===========================================================================
# Rollback machinery.
# ===========================================================================
function Register-Rollback { param([scriptblock]$Action) $script:Rollback.Push($Action) }
function Clear-Rollback    { $script:Rollback.Clear() }
function Invoke-Rollback {
    if ($script:Rollback.Count -eq 0) { return }
    Write-Step "Rolling back changes"
    while ($script:Rollback.Count -gt 0) {
        $a = $script:Rollback.Pop()
        try { & $a } catch { Write-Err "Rollback step failed: $($_.Exception.Message)" }
    }
    Write-Warn "Rollback complete. Claude was restored to its previous state."
}

# ===========================================================================
# Environment / discovery.
# ===========================================================================
function Test-IsAdmin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $p  = New-Object Security.Principal.WindowsPrincipal($id)
    return $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Assert-NodeAvailable {
    Write-Step "Checking Node.js / npx"
    $node = Get-Command node -ErrorAction SilentlyContinue
    $npx  = Get-Command npx  -ErrorAction SilentlyContinue
    if (-not $node -or -not $npx) {
        Write-Err "Node.js (with npx) is required and was not found on PATH."
        Write-Warn "Install Node.js from https://nodejs.org/ and reopen PowerShell."
        throw "node/npx not available"
    }
    $ver = (& node --version) 2>$null
    Write-Success "Node.js $ver detected (npx: $($npx.Source))."
}

function Test-MsixClaude {
    # Returns $true if a Store/MSIX Claude package is present.
    try {
        $pkg = Get-AppxPackage -Name '*Claude*' -ErrorAction SilentlyContinue
        if ($pkg) { return $true }
    } catch { }
    return $false
}

function Find-ClaudeInstall {
    Write-Step "Locating Claude Desktop (Squirrel build)"

    $root = Join-Path $env:LOCALAPPDATA 'AnthropicClaude'
    $squirrelFound = (Test-Path $root) -and ((Get-ChildItem -Path $root -Directory -Filter 'app-*' -ErrorAction SilentlyContinue | Measure-Object).Count -gt 0)

    if (-not $squirrelFound) {
        if (Test-MsixClaude) {
            Write-Err "Detected a Microsoft Store / MSIX install of Claude Desktop."
            Write-Warn "The MSIX build is sealed (AppxBlockMap) and cannot be patched safely."
            Write-Warn "Install the Squirrel build instead:  winget install Anthropic.Claude"
            throw "MSIX install is not supported"
        }
        Write-Err "Could not find a Squirrel install under: $root"
        Write-Warn "Install Claude Desktop (winget install Anthropic.Claude) and retry."
        throw "Claude install not found"
    }

    # Pick the highest-versioned app-* directory.
    $appDir = Get-ChildItem -Path $root -Directory -Filter 'app-*' |
        Sort-Object { [version]([regex]::Match($_.Name, '\d+(\.\d+)+').Value) } -ErrorAction SilentlyContinue |
        Select-Object -Last 1
    if (-not $appDir) { $appDir = Get-ChildItem -Path $root -Directory -Filter 'app-*' | Select-Object -Last 1 }

    $resources = Join-Path $appDir.FullName 'resources'
    $asar = Join-Path $resources 'app.asar'
    $exe  = Join-Path $appDir.FullName 'claude.exe'
    if (-not (Test-Path $exe)) { $exe = Join-Path $appDir.FullName 'Claude.exe' }

    if (-not (Test-Path $asar)) { Write-Err "app.asar not found at: $asar"; throw "app.asar missing" }
    if (-not (Test-Path $exe))  { Write-Err "claude.exe not found in: $($appDir.FullName)"; throw "claude.exe missing" }

    $version = [regex]::Match($appDir.Name, '\d+(\.\d+)+').Value

    Write-Success "Found Claude $version at $($appDir.FullName)"
    return [pscustomobject]@{
        Root       = $root
        AppDir     = $appDir.FullName
        Resources  = $resources
        AsarPath   = $asar
        ExePath    = $exe
        Version    = $version
    }
}

# ===========================================================================
# Process / file-lock handling.
# ===========================================================================
function Stop-ClaudeProcesses {
    Write-Step "Stopping Claude processes"
    $names = @('claude', 'Claude')
    $stopped = $false
    foreach ($n in $names) {
        $procs = Get-Process -Name $n -ErrorAction SilentlyContinue
        foreach ($p in $procs) {
            if ($script:DryRun) { Write-Dry "Would stop process $($p.Name) (PID $($p.Id))"; continue }
            try { $p.CloseMainWindow() | Out-Null } catch { }
            Start-Sleep -Milliseconds 300
            try { Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue } catch { }
            $stopped = $true
        }
    }
    if ($stopped) { Start-Sleep -Milliseconds 800; Write-Success "Claude processes stopped." }
    else { Write-Log "No running Claude processes." }
}

function Test-FileLocked {
    param([string]$Path)
    if (-not (Test-Path $Path)) { return $false }
    try {
        $fs = [IO.File]::Open($Path, 'Open', 'ReadWrite', 'None')
        $fs.Close(); $fs.Dispose()
        return $false
    } catch { return $true }
}

function Wait-FileUnlock {
    param([string]$Path, [int]$TimeoutSeconds = 15)
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        if (-not (Test-FileLocked -Path $Path)) { return $true }
        Start-Sleep -Milliseconds 500
    }
    return -not (Test-FileLocked -Path $Path)
}

# ===========================================================================
# Validation helpers.
# ===========================================================================
function Test-PeFile {
    param([string]$Path)
    try {
        $b = New-Object byte[] 2
        $fs = [IO.File]::OpenRead($Path)
        [void]$fs.Read($b, 0, 2)
        $fs.Close()
        return ($b[0] -eq 0x4D -and $b[1] -eq 0x5A)  # 'MZ'
    } catch { return $false }
}

function Get-AsarHeaderHash {
    # SHA-256 (hex) of the ASAR header string -- the value Electron's integrity
    # check compares against. See docs/SPEC.md section 5/6.
    param([string]$AsarPath)
    $fs = [IO.File]::OpenRead($AsarPath)
    try {
        $head = New-Object byte[] 16
        $read = $fs.Read($head, 0, 16)
        if ($read -lt 16) { throw "asar too small to contain a header" }
        $strLen = [BitConverter]::ToUInt32($head, 12)
        if ($strLen -le 0 -or $strLen -gt 64MB) { throw "implausible asar header length: $strLen" }
        $strBuf = New-Object byte[] $strLen
        $got = 0
        while ($got -lt $strLen) {
            $n = $fs.Read($strBuf, $got, $strLen - $got)
            if ($n -le 0) { break }
            $got += $n
        }
        if ($got -ne $strLen) { throw "could not read full asar header" }
    } finally { $fs.Close() }
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        $bytes = $sha.ComputeHash($strBuf)
    } finally { $sha.Dispose() }
    return (($bytes | ForEach-Object { $_.ToString('x2') }) -join '')
}

function Test-AsarValid {
    param([string]$Path)
    try { [void](Get-AsarHeaderHash -AsarPath $Path); return $true } catch { return $false }
}

# ===========================================================================
# Backup.
# ===========================================================================
function Backup-File {
    param([string]$Path, [ValidateSet('asar', 'pe', 'none')] [string]$ValidateAs = 'none')
    $bak = "$Path.bak"
    if (Test-Path $bak) {
        # Keep a pristine backup; only trust it if it still validates.
        $ok = $true
        if ($ValidateAs -eq 'asar') { $ok = Test-AsarValid -Path $bak }
        elseif ($ValidateAs -eq 'pe') { $ok = Test-PeFile -Path $bak }
        if ($ok) { Write-Log "Backup already exists (kept pristine): $bak"; return $bak }
        Write-Warn "Existing backup failed validation; refreshing: $bak"
    }
    if ($script:DryRun) { Write-Dry "Would back up $Path -> $bak"; return $bak }
    Copy-Item -Path $Path -Destination $bak -Force
    $valid = $true
    if ($ValidateAs -eq 'asar') { $valid = Test-AsarValid -Path $bak }
    elseif ($ValidateAs -eq 'pe') { $valid = Test-PeFile -Path $bak }
    if (-not $valid) { throw "Backup validation failed for $bak" }
    Write-Success "Backed up: $bak"
    return $bak
}

function Restore-FromBackup {
    param([string]$Path)
    $bak = "$Path.bak"
    if (-not (Test-Path $bak)) { return $false }
    Copy-Item -Path $bak -Destination $Path -Force
    return $true
}

# ===========================================================================
# npx wrappers (asar / fuses).
# ===========================================================================
function Invoke-Npx {
    param([Parameter(Mandatory)][string[]]$Arguments)
    $out = & npx --yes @Arguments 2>&1
    return @{ ExitCode = $LASTEXITCODE; Output = ($out -join "`n") }
}

function Expand-Asar {
    param([string]$AsarPath, [string]$DestDir)
    Write-Log "Extracting ASAR -> $DestDir"
    $r = Invoke-Npx -Arguments @($script:AsarPackage, 'extract', $AsarPath, $DestDir)
    if ($r.ExitCode -ne 0) { Write-Err $r.Output; throw "asar extract failed" }
}

function Compress-Asar {
    param([string]$SrcDir, [string]$AsarOut)
    Write-Log "Packing ASAR -> $AsarOut"
    $r = Invoke-Npx -Arguments @($script:AsarPackage, 'pack', $SrcDir, $AsarOut)
    if ($r.ExitCode -ne 0) { Write-Err $r.Output; throw "asar pack failed" }
    if (-not (Test-AsarValid -Path $AsarOut)) { throw "packed asar failed header validation" }
}

function Get-FuseState {
    param([string]$ExePath)
    $r = Invoke-Npx -Arguments @($script:FusesPackage, 'read', '--app', $ExePath)
    return $r.Output
}

function Test-FuseDisabled {
    param([string]$ProbeOutput)
    return ($ProbeOutput -match ($script:FuseName + '[^\r\n]*(Disabled|false|off|0)'))
}

function Set-FuseOff {
    param([string]$ExePath)
    Write-Log "Disabling Electron fuse $($script:FuseName)"
    $r = Invoke-Npx -Arguments @($script:FusesPackage, 'write', '--app', $ExePath, ($script:FuseName + '=off'))
    if ($r.ExitCode -ne 0) { Write-Err $r.Output; return $false }
    $state = Get-FuseState -ExePath $ExePath
    return (Test-FuseDisabled -ProbeOutput $state)
}

# ===========================================================================
# Payload injection into the extracted ASAR main process.
# ===========================================================================
function Get-MainEntryPath {
    param([string]$ExtractDir)
    $pkgPath = Join-Path $ExtractDir 'package.json'
    $main = 'index.js'
    if (Test-Path $pkgPath) {
        try {
            $pkg = Get-Content $pkgPath -Raw | ConvertFrom-Json
            if ($pkg.main) { $main = $pkg.main }
        } catch { }
    }
    $mainPath = Join-Path $ExtractDir ($main -replace '/', '\')
    if (-not (Test-Path $mainPath)) { throw "main entry not found in asar: $main" }
    return $mainPath
}

function Build-MainInjection {
    # Wrap the renderer payload so the main process injects it into every
    # webContents via executeJavaScript. Base64 avoids JS string-escaping issues.
    param([string]$PayloadJs)
    $b64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($PayloadJs))
    $tpl = @'
__MARKER__
;(function(){
  try {
    var __e = require('electron');
    var __app = __e.app, __BW = __e.BrowserWindow;
    var __code = Buffer.from('__B64__', 'base64').toString('utf8');
    function __inject(wc){
      if(!wc) return;
      var run = function(){ try { wc.executeJavaScript(__code, true); } catch(e){} };
      try { wc.on('dom-ready', run); } catch(e){}
      try { wc.on('did-finish-load', run); } catch(e){}
    }
    if (__app && __app.on) {
      __app.on('browser-window-created', function(_e, win){ try { __inject(win.webContents); } catch(e){} });
    }
    try {
      if (__BW && __BW.getAllWindows) {
        __BW.getAllWindows().forEach(function(w){ try { __inject(w.webContents); } catch(e){} });
      }
    } catch(e){}
  } catch(e){}
})();
'@
    $tpl = $tpl.Replace('__MARKER__', $script:Marker).Replace('__B64__', $b64)
    return $tpl
}

function Inject-Payload {
    param([string]$ExtractDir)
    $mainPath = Get-MainEntryPath -ExtractDir $ExtractDir
    Write-Log "Main entry: $mainPath"
    $content = [IO.File]::ReadAllText($mainPath)
    if ($content.Contains($script:Marker)) {
        Write-Log "Main entry already injected (idempotent)."
        return
    }
    # Strip the marker comment lines from the payload here-string.
    $payload = ($RTL_INJECTION_CODE -split "`n" | Where-Object { $_ -notmatch '^// --- CLAUDE RTL PATCH (START|END) ---' }) -join "`n"
    $inject = Build-MainInjection -PayloadJs $payload
    $newContent = $inject + "`n" + $content
    if ($script:DryRun) { Write-Dry "Would inject RTL payload into $mainPath"; return }
    [IO.File]::WriteAllText($mainPath, $newContent, (New-Object Text.UTF8Encoding $false))
    Write-Success "Injected RTL payload into main entry."
}

# ===========================================================================
# Launch-validate (distinguish integrity failure from generic crash).
# ===========================================================================
function Test-LaunchValid {
    param([string]$ExePath, [int]$TimeoutSeconds = 10)
    if ($script:DryRun) { Write-Dry "Would launch-validate $ExePath"; return @{ Ok = $true; Integrity = $false } }
    Write-Step "Launch-validating Claude"
    try {
        $p = Start-Process -FilePath $ExePath -PassThru -ErrorAction Stop
    } catch {
        return @{ Ok = $false; Integrity = $false; Reason = "could not start: $($_.Exception.Message)" }
    }
    $exited = $p.WaitForExit($TimeoutSeconds * 1000)
    if ($exited) {
        $code = $null
        try { $code = $p.ExitCode } catch { }
        # An immediate exit during startup is the signature of an ASAR-integrity
        # failure (the app aborts while loading the archive). A nonzero/!=0 quick
        # exit is treated as integrity-related so it can route to the fallback.
        $integrity = $true
        Write-Warn "Claude exited during startup (code: $code) -- likely integrity-related."
        return @{ Ok = $false; Integrity = $integrity; Reason = "startup exit code $code" }
    }
    # Still running after the window -> healthy. Close it cleanly.
    try { $p.CloseMainWindow() | Out-Null } catch { }
    Start-Sleep -Milliseconds 500
    try { if (-not $p.HasExited) { Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue } } catch { }
    Write-Success "Claude launched cleanly."
    return @{ Ok = $true; Integrity = $false }
}

# ===========================================================================
# Hash-patch fallback (unique-match only; never touches trusted root store).
# ===========================================================================
function Find-AllByteIndexes {
    param([byte[]]$Haystack, [byte[]]$Needle)
    $hits = New-Object System.Collections.Generic.List[int]
    $max = $Haystack.Length - $Needle.Length
    for ($i = 0; $i -le $max; $i++) {
        $match = $true
        for ($j = 0; $j -lt $Needle.Length; $j++) {
            if ($Haystack[$i + $j] -ne $Needle[$j]) { $match = $false; break }
        }
        if ($match) { $hits.Add($i) }
    }
    return $hits
}

function Invoke-HashFallback {
    param([string]$ExePath, [string]$OriginalAsar, [string]$PatchedAsar)
    Write-Step "Fallback: ASAR hash replacement inside claude.exe"
    $oldHash = Get-AsarHeaderHash -AsarPath $OriginalAsar
    $newHash = Get-AsarHeaderHash -AsarPath $PatchedAsar
    Write-Log "old asar hash: $oldHash"
    Write-Log "new asar hash: $newHash"
    if ($oldHash -eq $newHash) { Write-Log "Hashes identical; nothing to patch."; return $true }

    $bytes = [IO.File]::ReadAllBytes($ExePath)
    $oldBytes = [Text.Encoding]::ASCII.GetBytes($oldHash)
    $newBytes = [Text.Encoding]::ASCII.GetBytes($newHash)
    if ($oldBytes.Length -ne $newBytes.Length) { throw "hash length mismatch (impossible for SHA-256)" }

    $hits = Find-AllByteIndexes -Haystack $bytes -Needle $oldBytes
    if ($hits.Count -eq 0) {
        Write-Err "Original ASAR hash not found in claude.exe. Aborting fallback."
        return $false
    }
    if ($hits.Count -gt 1) {
        Write-Err "ASAR hash appears $($hits.Count) times in claude.exe (ambiguous). Aborting fallback per safety policy."
        return $false
    }
    $idx = $hits[0]
    Write-Log "Unique hash match at offset $idx; replacing in place."
    if ($script:DryRun) { Write-Dry "Would byte-replace ASAR hash in claude.exe at offset $idx"; return $true }
    for ($k = 0; $k -lt $newBytes.Length; $k++) { $bytes[$idx + $k] = $newBytes[$k] }
    [IO.File]::WriteAllBytes($ExePath, $bytes)
    Write-Success "ASAR hash replaced in claude.exe."
    return $true
}

# ===========================================================================
# Patch-state persistence.
# ===========================================================================
function Save-PatchState {
    param([pscustomobject]$Install, [string]$Method)
    if ($script:DryRun) { Write-Dry "Would save patch state."; return }
    if (-not (Test-Path $script:DataDir)) { New-Item -ItemType Directory -Path $script:DataDir -Force | Out-Null }
    $state = [pscustomobject]@{
        Patched   = $true
        Version   = $Install.Version
        AppDir    = $Install.AppDir
        AsarPath  = $Install.AsarPath
        ExePath   = $Install.ExePath
        Method    = $Method
        PatchedAt = (Get-Date -Format 's')
    }
    $state | ConvertTo-Json | Set-Content -Path $script:StateFile -Encoding UTF8
}
function Get-PatchState {
    if (-not (Test-Path $script:StateFile)) { return $null }
    try { return (Get-Content $script:StateFile -Raw | ConvertFrom-Json) } catch { return $null }
}
function Remove-PatchState {
    if (Test-Path $script:StateFile) { Remove-Item $script:StateFile -Force -ErrorAction SilentlyContinue }
}

# ===========================================================================
# INSTALL.
# ===========================================================================
function Invoke-Install {
    Clear-Rollback
    $changed = @()
    $method = 'fuse'
    try {
        Assert-NodeAvailable
        $inst = Find-ClaudeInstall
        Stop-ClaudeProcesses

        foreach ($f in @($inst.AsarPath, $inst.ExePath)) {
            if (-not (Wait-FileUnlock -Path $f -TimeoutSeconds 15)) {
                throw "File is locked (close Claude and retry): $f"
            }
        }

        Write-Step "Backing up originals"
        $asarBak = Backup-File -Path $inst.AsarPath -ValidateAs asar
        $exeBak  = Backup-File -Path $inst.ExePath  -ValidateAs pe
        Register-Rollback { if (Restore-FromBackup -Path $inst.AsarPath) { Write-Log "Restored app.asar" } }.GetNewClosure()
        Register-Rollback { if (Restore-FromBackup -Path $inst.ExePath)  { Write-Log "Restored claude.exe" } }.GetNewClosure()

        # --- ASAR inject ---
        Write-Step "Injecting RTL payload into app.asar"
        $tmp = Join-Path $env:TEMP ("claude-rtl-" + [Guid]::NewGuid().ToString('N'))
        $extract = Join-Path $tmp 'app'
        $newAsar = Join-Path $tmp 'app.asar.new'
        if (-not $script:DryRun) { New-Item -ItemType Directory -Path $tmp -Force | Out-Null }
        Register-Rollback { if (Test-Path $tmp) { Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue } }.GetNewClosure()

        if (-not $script:DryRun) {
            Expand-Asar -AsarPath $inst.AsarPath -DestDir $extract
            Inject-Payload -ExtractDir $extract
            Compress-Asar -SrcDir $extract -AsarOut $newAsar
            Copy-Item -Path $newAsar -Destination $inst.AsarPath -Force
        } else {
            Write-Dry "Would extract/inject/repack app.asar and swap it in."
        }
        $changed += $inst.AsarPath

        # --- Primary integrity bypass: fuse-flip ---
        Write-Step "Disabling ASAR integrity fuse (primary method)"
        $fuseOk = $false
        if ($script:DryRun) { Write-Dry "Would flip $($script:FuseName) OFF on claude.exe"; $fuseOk = $true }
        else {
            $state = Get-FuseState -ExePath $inst.ExePath
            if (Test-FuseDisabled -ProbeOutput $state) { Write-Success "Fuse already disabled."; $fuseOk = $true }
            else { $fuseOk = Set-FuseOff -ExePath $inst.ExePath }
        }
        $changed += $inst.ExePath

        $needFallback = -not $fuseOk
        if ($fuseOk) {
            $lv = Test-LaunchValid -ExePath $inst.ExePath
            if (-not $lv.Ok) {
                if ($lv.Integrity) { Write-Warn "Integrity-related startup failure after fuse-flip; trying fallback."; $needFallback = $true }
                else { throw "Generic startup crash after fuse-flip: $($lv.Reason)" }
            }
        } else {
            Write-Warn "Fuse-flip did not take effect; trying hash-patch fallback."
        }

        # --- Fallback: hash replacement ---
        if ($needFallback) {
            $method = 'hash'
            # Original asar = the pristine .bak; patched asar = the live (swapped-in) file.
            $fbOk = Invoke-HashFallback -ExePath $inst.ExePath -OriginalAsar $asarBak -PatchedAsar $inst.AsarPath
            if (-not $fbOk) { throw "Hash-patch fallback failed or was ambiguous." }
            $lv2 = Test-LaunchValid -ExePath $inst.ExePath
            if (-not $lv2.Ok) { throw "Launch-validate failed after fallback: $($lv2.Reason)" }
        }

        Save-PatchState -Install $inst -Method $method
        Clear-Rollback

        Write-Host ""
        Write-Host "============================================================" -ForegroundColor Green
        Write-Host "  Hebrew RTL patch installed successfully" -ForegroundColor Green
        Write-Host "============================================================" -ForegroundColor Green
        Write-Host "  Claude version : $($inst.Version)" -ForegroundColor Gray
        Write-Host "  Method         : $method (fuse=primary, hash=fallback)" -ForegroundColor Gray
        Write-Host "  Files changed  :" -ForegroundColor Gray
        foreach ($c in ($changed | Select-Object -Unique)) { Write-Host "      $c" -ForegroundColor Gray }
        Write-Host "  Backups        : *.bak next to each changed file" -ForegroundColor Gray
        Write-Host "  Restore        : run this tool and choose option 2" -ForegroundColor Gray
        Write-Host ""
        return $true
    } catch {
        Write-Err "Install failed: $($_.Exception.Message)"
        Invoke-Rollback
        Remove-PatchState
        return $false
    }
}

# ===========================================================================
# RESTORE.
# ===========================================================================
function Invoke-Restore {
    try {
        Assert-NodeAvailable
        $inst = $null
        try { $inst = Find-ClaudeInstall } catch { }
        $state = Get-PatchState

        $asar = if ($inst) { $inst.AsarPath } elseif ($state) { $state.AsarPath } else { $null }
        $exe  = if ($inst) { $inst.ExePath }  elseif ($state) { $state.ExePath }  else { $null }

        if (-not $asar -and -not $exe) { Write-Warn "Nothing to restore (no install or state found)."; return $true }

        Stop-ClaudeProcesses

        Write-Step "Restoring original files from backup"
        $restoredAny = $false
        foreach ($f in @($asar, $exe)) {
            if (-not $f) { continue }
            if (Test-Path "$f.bak") {
                if (-not (Wait-FileUnlock -Path $f -TimeoutSeconds 15)) { Write-Warn "Locked, skipping: $f"; continue }
                if ($script:DryRun) { Write-Dry "Would restore $f from $f.bak"; $restoredAny = $true; continue }
                Copy-Item -Path "$f.bak" -Destination $f -Force
                Remove-Item "$f.bak" -Force -ErrorAction SilentlyContinue
                Write-Success "Restored: $f"
                $restoredAny = $true
            } else {
                Write-Log "No backup for: $f"
            }
        }

        # Re-enable the fuse so the binary returns to its shipped state.
        if ($exe -and (Test-Path $exe) -and -not $script:DryRun) {
            try {
                $r = Invoke-Npx -Arguments @($script:FusesPackage, 'write', '--app', $exe, ($script:FuseName + '=on'))
                if ($r.ExitCode -eq 0) { Write-Success "Re-enabled ASAR integrity fuse." }
            } catch { Write-Warn "Could not re-enable fuse: $($_.Exception.Message)" }
        }

        Remove-PatchState
        if ($restoredAny) { Write-Success "Restore complete." } else { Write-Warn "No backups were found to restore." }
        Write-Warn "If you also enabled auto re-patch, choose option 5 to remove it."
        return $true
    } catch {
        Write-Err "Restore failed: $($_.Exception.Message)"
        return $false
    }
}

# ===========================================================================
# Quick re-patch shortcut + auto re-patch scheduled task.
# ===========================================================================
function Get-SelfPath { return $PSCommandPath }

function New-QuickShortcut {
    try {
        $desktop = [Environment]::GetFolderPath('Desktop')
        $lnk = Join-Path $desktop 'Update Claude Hebrew RTL.lnk'
        $self = Get-SelfPath
        if ($script:DryRun) { Write-Dry "Would create shortcut: $lnk"; return $true }
        $sh = New-Object -ComObject WScript.Shell
        $s = $sh.CreateShortcut($lnk)
        $s.TargetPath = (Join-Path $PSHOME 'powershell.exe')
        $s.Arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$self`" -Action install -NonInteractive"
        $s.WorkingDirectory = (Split-Path -Parent $self)
        $s.IconLocation = (Join-Path $PSHOME 'powershell.exe')
        $s.Description = 'Re-apply the Claude Hebrew RTL patch after an update.'
        $s.Save()
        Write-Success "Desktop shortcut created: $lnk"
        return $true
    } catch { Write-Err "Could not create shortcut: $($_.Exception.Message)"; return $false }
}

function Enable-AutoRepatch {
    try {
        $self = Get-SelfPath
        if ($script:DryRun) { Write-Dry "Would register scheduled task '$($script:TaskName)'"; return $true }
        $ps = Join-Path $PSHOME 'powershell.exe'
        $action = New-ScheduledTaskAction -Execute $ps -Argument "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$self`" -Action install -NonInteractive"
        # Trigger: at logon + when a new Claude version directory appears (poll daily as a safety net).
        $t1 = New-ScheduledTaskTrigger -AtLogOn
        $t2 = New-ScheduledTaskTrigger -Daily -At 12pm
        $settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
        $principal = New-ScheduledTaskPrincipal -UserId ([Security.Principal.WindowsIdentity]::GetCurrent().Name) -LogonType Interactive
        Register-ScheduledTask -TaskName $script:TaskName -Action $action -Trigger @($t1, $t2) -Settings $settings -Principal $principal -Force | Out-Null
        Write-Success "Auto re-patch scheduled task registered: $($script:TaskName)"
        Write-Log "It re-applies the patch at logon and daily; safe because install is idempotent."
        return $true
    } catch { Write-Err "Could not register scheduled task: $($_.Exception.Message)"; return $false }
}

function Disable-AutoRepatch {
    try {
        if ($script:DryRun) { Write-Dry "Would unregister scheduled task '$($script:TaskName)'"; return $true }
        $existing = Get-ScheduledTask -TaskName $script:TaskName -ErrorAction SilentlyContinue
        if ($existing) {
            Unregister-ScheduledTask -TaskName $script:TaskName -Confirm:$false
            Write-Success "Auto re-patch task removed."
        } else { Write-Warn "Auto re-patch task was not registered." }
        return $true
    } catch { Write-Err "Could not remove scheduled task: $($_.Exception.Message)"; return $false }
}

# ===========================================================================
# Menu.
# ===========================================================================
function Show-Banner {
    Write-Host ""
    Write-Host "============================================================" -ForegroundColor Cyan
    Write-Host "   Claude Desktop - Hebrew RTL Patch (Windows)" -ForegroundColor Cyan
    Write-Host "   Fuse-first | Squirrel-only | reversible | Hebrew-only" -ForegroundColor DarkCyan
    if ($script:DryRun) { Write-Host "   *** DRY-RUN MODE: no files will be modified ***" -ForegroundColor Yellow }
    Write-Host "============================================================" -ForegroundColor Cyan
}

function Show-Menu {
    while ($true) {
        Show-Banner
        $state = Get-PatchState
        if ($state -and $state.Patched) {
            Write-Host "   Current state: PATCHED (v$($state.Version), method=$($state.Method))" -ForegroundColor Green
        } else {
            Write-Host "   Current state: not patched" -ForegroundColor Gray
        }
        Write-Host ""
        Write-Host "   1. Install Hebrew RTL patch"
        Write-Host "   2. Restore original state"
        Write-Host "   3. Create desktop shortcut for quick re-patch"
        Write-Host "   4. Enable auto re-patch after Claude updates"
        Write-Host "   5. Disable auto re-patch"
        Write-Host "   6. Exit"
        Write-Host ""
        $choice = Read-Host "   Choose an option [1-6]"
        switch ($choice) {
            '1' { [void](Invoke-Install) }
            '2' { [void](Invoke-Restore) }
            '3' { [void](New-QuickShortcut) }
            '4' { [void](Enable-AutoRepatch) }
            '5' { [void](Disable-AutoRepatch) }
            '6' { Write-Host "   Bye." -ForegroundColor Cyan; return }
            default { Write-Warn "Invalid choice: '$choice'" }
        }
        if (-not $NonInteractive) {
            Write-Host ""
            Read-Host "   Press Enter to return to the menu"
        }
    }
}

# ===========================================================================
# Entry point.
# ===========================================================================
try {
    if ($Action -eq 'install') { $ok = Invoke-Install; if (-not $NonInteractive) { Read-Host "Press Enter to exit" }; exit ([int](-not $ok)) }
    if ($Action -eq 'restore') { $ok = Invoke-Restore; if (-not $NonInteractive) { Read-Host "Press Enter to exit" }; exit ([int](-not $ok)) }
    Show-Menu
} catch {
    Write-Err "Fatal: $($_.Exception.Message)"
    exit 1
}
