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
        /*__RTL_CORE__*/
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
