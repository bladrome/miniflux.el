# Repository Guidelines

## Project Overview

`miniflux.el` is a single-file Emacs Lisp package that integrates a Miniflux RSS server with elfeed. It fetches Miniflux entries, stores them in elfeed's database, and lets users read/search/filter through the elfeed UI while syncing read/unread and star/bookmark state.

## Architecture & Data Flow

- Main module: `miniflux.el` contains package metadata, defcustoms, HTTP helpers, Miniflux API wrappers, Miniflux-to-elfeed conversion, sync/reconciliation, elfeed hooks, keybindings, and interactive commands.
- HTTP stack: built-in `url.el` + `json.el`; no `request.el`. `miniflux--request` is synchronous; `miniflux--request-async` uses `url-retrieve` callbacks.
- API flow:
  1. Build `/v1` API URLs and auth headers from `miniflux-server`, explicit token/basic-auth variables, or auth-source credentials.
  2. Fetch recent, starred, and unread entries with `miniflux--fetch-entry-pages-async`.
  3. Convert API alists to elfeed feeds/entries.
  4. Reconcile local elfeed tags/meta from server state.
  5. Save the elfeed DB and update `miniflux-last-sync-time` after successful batches.
- Entry identity invariant: Miniflux-owned elfeed entries use IDs of the form `(miniflux . "<api-id>")`. Reconciliation scopes on `(eq (car id) 'miniflux)`; preserve this in new entry-creation code.
- Feed identity: elfeed feed IDs are `miniflux://<feed-id>`.
- Metadata stored on entries includes `:miniflux-id`, `:miniflux-feed-id`, `:miniflux-category-id`, `:miniflux-category-title`, and feed URLs.
- Sync invariant: `miniflux-sync` is pull-only. The Miniflux server is the source of truth during sync. Local read/unread/star changes are pushed immediately by elfeed tag hooks, not by sync reconciliation.
- Batch invariant: unread/star reconciliation only removes local tags when the fetched server batch is complete. Incomplete batches may add tags but must not strip local state.
- Category tags: `miniflux-category-tag-prefix` controls category tag names. The current default is `""`, which uses bare category slugs and disables stale namespace pruning; a non-empty prefix such as `"miniflux-category-"` enables managed category-tag cleanup while preserving unrelated user tags.
- Auth precedence: `miniflux-token` wins, then explicit `miniflux-username`/`miniflux-password`, then auth-source. Auth-source logins `token`, `api-token`, and `miniflux-token` produce `X-Auth-Token`; other logins use HTTP Basic Auth.

## Key Directories

- `miniflux.el` — core package and public API.
- `test/` — ERT unit tests; currently one file, `test/miniflux-test.el`.
- Project root — `Makefile`, `readme.org`, `.gitignore`, and this `AGENTS.md`.
- No `src/`, `lib/`, `scripts/`, `docs/`, `examples/`, or CI directories are present.

## Development Commands

The Makefile uses `emacs -Q`, so elfeed must be discoverable on `load-path`.

```sh
# Byte-compile; may fail unless elfeed is on load-path.
make compile

# Run the full ERT suite; may fail unless elfeed is on load-path.
make test

# Compile then test.
make check
```

Working explicit commands when elfeed is installed under an Emacs package dir:

```sh
ELFEED=$(ls -d ~/.config/emacs/elpa/elfeed-* ~/.emacs.d/elpa/elfeed-* 2>/dev/null | head -1)

emacs -Q --batch -L . -L "$ELFEED" -f batch-byte-compile miniflux.el
emacs -Q --batch -L . -L "$ELFEED" -L test -l test/miniflux-test.el -f ert-run-tests-batch-and-exit

# Focused test selector.
emacs -Q --batch -L . -L "$ELFEED" -L test -l test/miniflux-test.el \
  --eval '(ert-run-tests-batch-and-exit "^miniflux-slugify")'
```

One-time dependency install example:

```sh
emacs -Q --batch --eval "(progn (require 'package) (package-refresh-contents) (package-install 'elfeed))"
```

## Code Conventions & Common Patterns

- Keep `lexical-binding: t` in Emacs Lisp files.
- Public commands/API functions use `miniflux-*`; internal helpers use `miniflux--*`.
- User configuration lives in `defgroup miniflux` / `defcustom` forms.
- User-facing precondition failures should use `user-error`; request/HTTP failures generally log with `message` and return `nil`.
- API data is represented as JSON alists and read with `assoc-default`.
- Async code is callback-based, not promises/threads. Do not block UI paths with synchronous network calls unless working on explicit API wrapper functions.
- Preserve the custom `gv-define-setter` forms for `elfeed-entry-tags`, `elfeed-entry-title`, and `elfeed-entry-meta`. Reconciliation relies on `(setf (elfeed-entry-tags entry) ...)` routing through these direct `aset` setters so elfeed tag hooks are not triggered.
- Code paths that should push state to Miniflux use elfeed tag/untag hooks. Code paths that reconcile server state into the local DB should mutate tags directly and must not invoke hook-driven API pushes.
- Avoid introducing a second abstraction style; this package is intentionally a small, single-file Elisp package.

## Important Files

- `miniflux.el:1-42` — package header, dependencies, commentary.
- `miniflux.el:60-93` — custom elfeed struct setters; byte-compilation/runtime invariant.
- `miniflux.el:95-181` — customization and sync state.
- `miniflux.el:183-323` — HTTP/auth/JSON request primitives.
- `miniflux.el:323-443` — Miniflux API wrappers.
- `miniflux.el:445-614` — elfeed feed/entry conversion.
- `miniflux.el:616-895` — pull-only sync, async orchestration, reconciliation finish.
- `miniflux.el:906-1153` — selected-entry helpers, failed-sync tags, retry, UI commands, tag hooks.
- `miniflux.el:1155-1217` — elfeed hook compatibility, keybindings, main `miniflux` entry point.
- `test/miniflux-test.el` — no-network ERT suite.
- `readme.org` — user documentation in Org format; keep docs changes in Org, not Markdown.
- `Makefile` — compile/test/check targets.

## Runtime/Tooling Preferences

- Required runtime: Emacs 27.1+.
- Required package dependency: elfeed 3.4.1+.
- Package install examples use straight.el/use-package or manual `load-path` setup; there is no project-local package manager.
- Build/test tooling is plain Make + `emacs -Q --batch`.
- No configured CI, lint target, package-lint, checkdoc, Cask, Eldev, Nix, Bun, Node, or lockfile is present.
- `.gitignore` ignores `*.elc`; byte-compiled artifacts should not be treated as source.

## Testing & QA

- Test framework: ERT in `test/miniflux-test.el`.
- Full suite: 32 `ert-deftest` tests observed.
- Tests are pure unit tests with no live network. Mock API/HTTP/auth-source functions with `cl-letf`, commonly rebinding `miniflux--request-async`, `miniflux-update-entry-status`, `miniflux-get-entry`, `miniflux-toggle-entry-bookmark`, `auth-source-search`, and `miniflux--request`.
- DB-level tests bind `elfeed-db-entries` to a fresh hash table and create entries with `elfeed-entry--create`.
- Existing coverage emphasizes URL/auth helpers, auth-source fallback, JSON error parsing, counter parsing, async pagination, entry metadata, category tags, unread/star reconciliation, and push-state retry behavior.
- Add or update focused ERT tests for behavioral changes. Prefer branch/invariant coverage over snapshots or default-value assertions.
- Before finishing non-trivial code changes, run byte-compile and the full ERT suite with elfeed on `load-path`.
