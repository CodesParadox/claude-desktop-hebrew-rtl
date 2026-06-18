# Claude Desktop Hebrew RTL Patch — Implementation Spec

Status: pending human approval.
Scope: Windows only. Hebrew only. Squirrel/winget build of Claude Desktop only.

This document is the source of truth for the design. The running implementation
checklist lives at the bottom (see "Implementation checklist").

---

## 1. Goal

Patch Claude Desktop on Windows so that Hebrew text feels native in:

- the input box (live direction switching as the user types), and
- Claude's replies, including while a response is still streaming.

While doing so, preserve correct LTR rendering for English, code blocks, inline
code, fenced code, math/LaTeX, file paths, shell commands, hashes, and URLs, and
keep mixed Hebrew/English technical content readable.

Separately, fix the Windows Hebrew-locale bug where Claude Desktop's window chrome
flips to RTL and the title-bar window controls (minimize/maximize/close) overlap
Claude's own navigation/settings controls. The window shell/chrome is forced to
stay LTR; only chat *content* direction is context-sensitive.

The tool must be safe, reversible, auditable, idempotent where practical, and must
support reinstall / restore / re-patch after Claude updates.

---

## 2. Non-negotiable constraints

- Windows only.
- Windows PowerShell 5.1 first (not pwsh-first). All `.ps1` must parse and run
  under Windows PowerShell 5.1.
- Node.js / `npx` is assumed present but is verified explicitly before patching.
- Safe, reversible, auditable.
- Back up every modified file before touching it.
- Automatic rollback on any failure.
- Idempotent where practical.
- Dry-run mode for destructive operations where feasible.

---

## 3. Confirmed design decisions

| Decision | Choice | Rationale |
| :-- | :-- | :-- |
| Integrity bypass (primary) | Disable Electron fuse `EnableEmbeddedAsarIntegrityValidation` via `@electron/fuses` | Current (2026) community-validated method; least invasive that still works on all Squirrel builds. |
| Integrity bypass (fallback) | Byte-patch the ASAR SHA-256 hash inside `claude.exe` only | Recovers if fuse tooling changes; touches a single, validated binary. |
| Trusted root store | NEVER modified | Hard delta from reference repo. We do not add a self-signed cert nor touch `cowork-svc.exe`. |
| `cowork-svc.exe` | NEVER touched | Cowork VM service is unrelated to RTL rendering; modifying it is high-risk. |
| Target build | Squirrel/winget `.exe` only | MSIX/Store build is sealed by AppxBlockMap per-file hashing and is effectively unpatchable. |
| Language scope | Hebrew only | RTL detection limited to Hebrew block + Hebrew presentation forms. No Arabic. |
| Signing | Real RSA-4096; valid `patch.ps1.sig`; public key embedded in `install.ps1` | End-to-end working verification; private key gitignored, never committed. |

---

## 4. Architecture

### 4.1 Components

```
install.ps1            Thin, verifiable bootstrap. Downloads patch.ps1 + .sig,
                       verifies RSA-4096 signature (fail closed), self-elevates
                       (UAC), launches the verified patch.ps1.

patch.ps1              The operator tool. Numbered menu. Contains the built RTL
                       payload (assembled from src/) between marker comments.
                       Implements install / restore / shortcut / auto-repatch.

src/rtl-core.js        Pure, DOM-free Hebrew detection + LaTeX/table direction
                       logic. Unit-tested. Single source of truth for detection.

src/rtl-payload.js     DOM integration: MutationObserver, math/code isolation,
                       input-box live direction, window-chrome LTR enforcement.
                       Contains a /*__RTL_CORE__*/ marker where the core is inlined.

tools/build-payload.ps1     Assembles core + payload, validates with `node --check`,
                            splices into patch.ps1 between START/END markers.
tools/generate-keypair.ps1  Creates the local RSA-4096 keypair (private key local only).
tools/sign-release.ps1      Signs LF-normalized patch.ps1 -> patch.ps1.sig.
tools/verify-signature.ps1  Audits patch.ps1 against patch.ps1.sig + embedded pubkey.

test/rtl-core.test.js  node --test unit tests for rtl-core.js.
```

### 4.2 Data / control flow

```
User: irm .../install.ps1 | iex
  -> install.ps1 downloads patch.ps1 (raw bytes) + patch.ps1.sig
  -> verify RSA-4096 PKCS#1 SHA-256 signature over the exact bytes
       fail  -> print error, fail closed, exit (never runs patch)
       pass  -> write verified patch.ps1 to TEMP, Start-Process -Verb RunAs
                (UAC), passing the verified public key as -TrustedPubKey param
  -> elevated patch.ps1 shows numbered menu

Menu 1 (Install):
  preflight -> backup -> asar inject -> fuse-flip -> launch-validate
    any failure -> auto rollback from .bak
    fuse-flip fails -> hash-patch fallback -> launch-validate
      fallback fails -> auto rollback from .bak -> abort
  success -> write patch state marker -> summary report
```

### 4.3 Build pipeline (no hidden blobs)

`rtl-core.js` (with its `module.exports` guard stripped) is inlined into
`rtl-payload.js` at the `/*__RTL_CORE__*/` marker by `tools/build-payload.ps1`.
The assembled IIFE is validated with `node --check`, then spliced into `patch.ps1`
between `// --- CLAUDE RTL PATCH START ---` and `// --- CLAUDE RTL PATCH END ---`.
The detection logic is therefore human-readable in `src/` and reviewable; only the
final packaging concatenates it. After building, `patch.ps1` must be re-signed.

---

## 5. Patching flow (Install)

1. **Preflight (read-only, may abort cleanly):**
   - Confirm running on Windows + (re-)elevated.
   - Verify `node`/`npx` are on PATH; abort with guidance if missing.
   - Locate the Claude install. Resolve the active versioned dir
     (`%LOCALAPPDATA%\AnthropicClaude\app-<ver>\` or `...\app-<ver>\resources`).
   - Reject MSIX/Store installs (path under `WindowsApps` / `Program Files\WindowsApps`)
     with a clear message to use the winget/Squirrel build.
   - Locate `resources\app.asar` and `claude.exe`.
   - Stop Claude (and its helper processes) and confirm target files are not locked;
     wait/retry with a bounded timeout.
2. **Backup:** copy `app.asar` (+ `app.asar.unpacked` if present) and `claude.exe`
   to `*.bak` next to the originals. Validate each backup (ASAR header parses; PE
   header valid) before proceeding. Skip backup if a valid `.bak` already exists
   (idempotency) but never overwrite a good backup with a patched file.
3. **ASAR inject:**
   - `npx @electron/asar extract app.asar <tmp>`.
   - Inject the window-chrome LTR enforcement into the main-process entry and the
     RTL payload into the renderer entry/preload, guarded by an idempotency marker
     so re-injection is a no-op.
   - `npx @electron/asar pack <tmp> app.asar.new`, validate header, atomically
     replace `app.asar`.
4. **Integrity bypass (primary):** `npx @electron/fuses` read the current fuse
   state; if `EnableEmbeddedAsarIntegrityValidation` is enabled, flip it OFF on
   `claude.exe`. Re-read to confirm Disabled.
5. **Launch-validate:** start Claude headlessly/normally for a bounded time and
   confirm the process stays up. Where possible, distinguish an *integrity-related*
   startup failure (e.g. the known ASAR-integrity exit signature / non-zero exit
   immediately at load, integrity assertion text in stderr/log) from a *generic*
   crash (later runtime fault). An integrity-related failure means the chosen bypass
   did not take effect and should route to the fallback (step 6) before giving up; a
   generic crash routes straight to rollback. When the cause cannot be determined
   confidently, treat it as failure and roll back (fail safe).
6. **Fallback (only if fuse-flip fails or launch-validate reports an integrity-related
   failure after fuse-flip):** compute the new ASAR SHA-256 header hash, then search
   `claude.exe` for the original hash ASCII string. The match must be **unique**: if
   the hash is not found, is found more than once, or is otherwise ambiguous (e.g.
   wrong length / not exact-length ASCII), **abort the fallback and roll back** rather
   than guessing which occurrence to edit. Only on an unambiguous single match is the
   hash byte-replaced in place (same length), followed by re-launch-validate. This
   path never touches the trusted root store.
7. **Failure at any step -> automatic rollback** (Section 7).
8. **Success:** write a patch-state marker (versioned), print a summary of files
   changed, backups created, method used (fuse vs hash), and current state.

---

## 6. Safety model

- **Backup-before-touch:** no original file is modified before a validated `.bak`
  exists beside it.
- **Atomic writes:** new artifacts written to `*.new`, validated, then swapped in.
- **Validation gates:** ASAR header parse check and PE header check before trusting
  any copied/produced binary; `node --check` on the payload at build time.
- **Idempotency:** install detects an existing patch marker and an existing valid
  backup; re-running re-applies cleanly without stacking changes or clobbering the
  pristine backup.
- **Dry-run:** `-DryRun` switch on `patch.ps1` prints every planned destructive
  action (backup/extract/pack/fuse-flip/replace) and performs none.
- **Fail closed:** signature verification failure, malformed embedded key, or a
  network error all stop before any modification.
- **Least privilege over key material:** signing private key never ships and is
  gitignored; `install.ps1` only ever carries the public key. No private key
  material is persisted by the installed tool.
- **Explicit over heuristic for binaries:** the hash-patch fallback requires a
  single, exact-length ASCII hash match (validated) rather than fuzzy edits. If the
  hash is missing, appears multiple times, or is otherwise ambiguous, the fallback
  aborts and rolls back rather than guessing which occurrence to edit.
- **Launch-validate failure classification:** when feasible, integrity-related
  startup failures are distinguished from generic crashes so only the former route
  to the hash-patch fallback; an indeterminate result is treated as a failure and
  rolled back.

---

## 7. Rollback strategy

- Each destructive step registers its inverse on a rollback stack as it runs
  (e.g. "restore app.asar from .bak", "re-enable fuse", "restore claude.exe").
- On any thrown error or failed launch-validate, the stack is unwound in LIFO order:
  1. restore `claude.exe` from `claude.exe.bak`,
  2. restore `app.asar` (+ unpacked) from `.bak`,
  3. re-enable the fuse if it was flipped,
  4. remove any partial `.new` artifacts and the patch marker.
- Restore (menu option 2) is the user-facing rollback: it restores all originals
  from `.bak`, re-enables the fuse, removes the patch marker, and offers to remove
  the auto-repatch scheduled task. Restore is itself idempotent and safe to run when
  nothing is patched.

---

## 8. Signature verification flow

- **Key:** RSA-4096. Public key embedded in `install.ps1` as a base64 JSON blob
  `{Modulus, Exponent}`; fingerprint (SHA-256 over the blob) is published in the
  README for out-of-band cross-check.
- **Sign (maintainer):** `tools/sign-release.ps1` reads `patch.ps1` as bytes,
  normalizes CRLF->LF (the canonical signed form), signs with RSA PKCS#1 v1.5 +
  SHA-256, writes base64 to `patch.ps1.sig`.
- **Verify (installer):** `install.ps1` downloads `patch.ps1` as raw bytes (via
  `WebClient`, not `Invoke-RestMethod`, to avoid BOM normalization) and the `.sig`,
  imports the embedded public key, and calls `RSA.VerifyData(..., SHA256, Pkcs1)`.
  On mismatch it refuses to run and prints remediation. The verified public-key
  blob is passed to the elevated `patch.ps1` as `-TrustedPubKey` so the auto-repatch
  watcher pins the same trust anchor (avoids a re-download TOCTOU window).
- **Audit:** `tools/verify-signature.ps1` lets anyone recompute and confirm the
  signature locally without installing; also used by a maintainer pre-commit check.

---

## 9. Update / re-patch strategy

Claude Desktop auto-updates overwrite the patched files. Two optional mechanisms
(menu options 3 and 4) keep the patch applied:

- **Quick re-patch shortcut (option 3):** a desktop shortcut that re-runs the
  verified install flow silently.
- **Auto re-patch (option 4):** a Windows Scheduled Task that, on detecting a new
  `claude.exe` version (new versioned `app-<ver>` dir), re-runs the install flow
  and notifies the user. Option 5 removes the task. The task pins the trusted
  public key captured at install time. Re-patch reuses the idempotent install path.

---

## 10. Test strategy

- **Unit (rtl-core.js):** `node --test` over `test/rtl-core.test.js`. Covers:
  Hebrew detection (incl. presentation forms), first-strong direction, currency vs
  LaTeX `$...$` discrimination, `$$`/`\[\]`/`\(\)` detection, segmentation, table
  cell/whole-table direction, and `stripLeadingLTR`. Pure logic, no DOM, runs on any
  Node. This is the gate that must pass before building the payload.
- **DOM (rtl-payload.js):** `test/rtl-payload.test.js` assembles the payload the same
  way `build-payload.ps1` does (core inlined) and runs it inside a `jsdom` window
  (dev-only dependency). Asserts real DOM outcomes: Hebrew paragraph -> RTL, English
  -> not RTL, code/inline-code pinned LTR, chat input live direction, window chrome
  forced LTR from an RTL shell, raw-LaTeX isolation island, currency not isolated,
  Hebrew vs English table flip, and streaming (a node added after load is processed
  by the MutationObserver). This closes the gap the reference repo left untested.
- **Build validation:** `node --check` on the assembled payload; a size sanity guard
  prevents truncating `patch.ps1`.
- **PowerShell static checks:** scripts must parse under Windows PowerShell 5.1;
  ASCII-only for BOM-less build tooling.
- **Manual integration (documented):** dry-run output review; install on a real
  Squirrel build; verify Hebrew input + streaming replies; verify code/LaTeX stay
  LTR; verify window chrome stays LTR on a Hebrew-locale Windows; verify restore
  returns to pristine; verify re-patch after an update.
- **Signature self-test:** `verify-signature.ps1` returns success on a freshly
  signed release and failure on a mutated `patch.ps1`.

---

## 11. Exact file layout

```
.
├─ install.ps1                 # verified bootstrap + UAC self-elevation
├─ patch.ps1                   # operator menu + built RTL payload
├─ patch.ps1.sig              # base64 RSA-4096 signature over patch.ps1 (LF bytes)
├─ package.json               # npm test/build scripts
├─ .gitignore                 # ignores private key, node_modules, temp artifacts
├─ README.md                  # Hebrew documentation
├─ docs/
│  └─ SPEC.md                 # this document
├─ src/
│  ├─ rtl-core.js             # pure Hebrew detection (unit-tested)
│  └─ rtl-payload.js          # DOM payload (inlines core at /*__RTL_CORE__*/)
├─ test/
│  ├─ rtl-core.test.js        # node --test unit tests (pure core)
│  └─ rtl-payload.test.js     # node --test DOM tests via jsdom (dev-only dep)
└─ tools/
   ├─ build-payload.ps1       # assemble + node --check + splice into patch.ps1
   ├─ generate-keypair.ps1    # create local RSA-4096 keypair
   ├─ sign-release.ps1        # sign patch.ps1 -> patch.ps1.sig
   └─ verify-signature.ps1    # audit signature
```

Local-only (gitignored), produced by `generate-keypair.ps1`:
```
.keys/private.xml             # RSA private key (NEVER committed)
```

---

## 12. Assumptions to validate during implementation

1. `@electron/fuses` can flip `EnableEmbeddedAsarIntegrityValidation` OFF on the
   current `claude.exe` and the app still launches (Authenticode signature is
   invalidated by the flip, but the Squirrel launcher does not re-verify it).
2. The UI still lives in `resources\app.asar`; the install path is the versioned
   `%LOCALAPPDATA%\AnthropicClaude\app-<ver>\` layout.
3. Renderer DOM selectors (`[data-testid="chat-input"]`, `pre`,
   `.code-block__code`, `code`, `table`) still match the current build.
4. The main-process entry can be located inside the extracted ASAR for chrome-LTR
   injection (e.g. a `.vite/build/*.js` main entry or `index.js`).
5. The original ASAR hash is stored as an ASCII SHA-256 string inside `claude.exe`
   (needed only for the fallback path).

Each assumption is checked at runtime; failure produces a clear message and, where
relevant, triggers fallback or rollback rather than proceeding blindly.

---

## 13. Risks and mitigations

| Risk | Impact | Mitigation |
| :-- | :-- | :-- |
| Claude update overwrites patch | Patch lost | Quick re-patch shortcut + auto-repatch task; idempotent install. |
| Fuse tooling/format changes | Primary bypass fails | Hash-patch fallback; if both fail, rollback + clear error. |
| ASAR repack corrupts app | App won't start | Validate ASAR header; launch-validate; auto-rollback from `.bak`. |
| File locks during patch (running app/service) | Write fails midway | Stop processes, bounded wait for unlock, abort cleanly before writes. |
| MSIX build targeted | Patch impossible/unsafe | Detect and refuse with guidance to switch to winget build. |
| Signed `patch.ps1` tampered in transit | Malicious code | RSA-4096 verify fail-closed before execution; published fingerprint. |
| Private key leakage | Trust compromise | Key never committed (`.gitignore`); installer carries only public key. |
| React reconciliation breakage from DOM edits | UI crash | Avoid `innerHTML` rewrites; use `replaceChild`/CSS (`unicode-bidi:plaintext/isolate`) and idempotency flags. |
| Over-flipping LTR technical content | Unreadable code/paths | Detection isolates code/inline-code/LaTeX/URLs/paths; first-strong + contains-RTL heuristics tuned and unit-tested. |
| Window chrome flips on Hebrew locale | Controls overlap | Force chrome/shell LTR in main process independent of content direction. |

---

## 14. Chosen approach vs rejected alternatives

**Chosen: fuse-flip primary + hash-patch fallback, no trusted-root changes.**
Least invasive method that reliably defeats ASAR integrity on all Squirrel builds,
keeps the blast radius to two files (`app.asar`, `claude.exe`), and never alters the
machine trust store.

**Rejected A: cert-swap primary (reference-repo approach).** Replacing Anthropic's
signing certificate inside `cowork-svc.exe` and adding a self-signed cert to the
Windows trusted root store is far more invasive, weakens machine trust, has more
moving parts to roll back, and is unnecessary because the fuse-flip already bypasses
the integrity check for RTL rendering.

**Rejected B: CSS-only / no integrity bypass.** Injecting CSS without disabling
integrity is impossible on the sealed ASAR — any modification to `app.asar` trips
`EnableEmbeddedAsarIntegrityValidation` and the app refuses to launch. A purely
external overlay cannot reach the Electron renderer DOM reliably across updates.

---

## 15. Implementation checklist (kept updated during Phase 2)

- [x] `src/rtl-core.js` (Hebrew-only) + `test/rtl-core.test.js` pass `node --test` (15/15).
- [x] `src/rtl-payload.js` (DOM + chrome-LTR + streaming observer); `node --check` OK.
- [x] `tools/build-payload.ps1` assembles + `node --check` + splices into patch.ps1.
- [x] `patch.ps1` install/restore/dry-run/menu with fuse-primary + hash-fallback (parses clean).
- [x] `install.ps1` sig-verify + UAC self-elevation (parses clean).
- [x] `tools/generate-keypair.ps1`, `tools/sign-release.ps1`, `tools/verify-signature.ps1`.
- [x] Valid `patch.ps1.sig` + embedded public key in `install.ps1` (verify-signature: OK).
- [x] Quick re-patch shortcut + auto-repatch scheduled task (patch.ps1 menu 3/4/5).
- [x] Hebrew `README.md`, `package.json`, `.gitignore`, `LICENSE`.

Note: items above are verified by static/unit checks (`node --test`, `node --check`,
PowerShell parser, signature verify). Live integration against a real Claude Desktop
install (ASAR inject, fuse-flip, launch-validate, fallback) remains a manual step per
Section 10 and the runtime-validated assumptions in Section 12.

---

## 16. Validation checklist before Phase 2 starts

These gates must all be satisfied before any further implementation (patch.ps1,
install.ps1, tools/, signatures, shortcuts, scheduled tasks) begins:

- [ ] This spec (`docs/SPEC.md`) is reviewed and explicitly approved by the human.
- [ ] Draft `src/rtl-core.js` passes `node --test test/rtl-core.test.js` (all green).
- [ ] Draft `src/rtl-core.js` passes `node --check` (valid syntax).
- [ ] Draft `src/rtl-payload.js` passes `node --check` (valid syntax).
- [ ] The Hebrew-only detection scope is confirmed acceptable (no Arabic/other RTL).
- [ ] The fuse-flip-primary / hash-patch-fallback / never-touch-trusted-root strategy
      is confirmed acceptable.
- [ ] Squirrel-only targeting (refuse MSIX) is confirmed acceptable.
- [ ] Assumptions in Section 12 are acknowledged as runtime-validated, not pre-proven.

Only after every box above is checked and the human approves does Phase 2 begin.

---

## 17. Approval Gate

IMPLEMENTATION BEYOND THE CURRENT DRAFT FILES MUST NOT CONTINUE UNTIL THE HUMAN
EXPLICITLY APPROVES THIS SPEC.

Current draft files under review (the only files that may exist at this stage):

- `docs/SPEC.md`
- `src/rtl-core.js`
- `src/rtl-payload.js`
- `test/rtl-core.test.js`

No other implementation files may be created or modified until approval. Explicitly
gated artifacts include: `patch.ps1`, `install.ps1`, `patch.ps1.sig`, everything
under `tools/`, `package.json`, `README.md`, the desktop shortcut, and the
auto-repatch scheduled task. Work resumes only on an explicit "approved" / "proceed
to Phase 2" instruction from the human.
