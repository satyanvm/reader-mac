# Reader for macOS

The Mac app (SwiftUI + AppKit, PDFKit, Vision, SQLite). Same features and the same reading-position model as the Android app, so the two sync. The design is in [reader-android/docs/position-sync.md](https://github.com/satyanvm/reader-android/blob/main/docs/position-sync.md).

Requires macOS 14+. Builds with the Command Line Tools alone (no Xcode) and has no third-party dependencies.

## Build, test, run

```bash
swift test
```

```bash
scripts/build-app.sh
```

```bash
open build/Reader.app
```

Tests use Swift Testing, because XCTest only ships with Xcode. If a build stops with "plugin for module 'TestingMacros' not found", run it again: the Command Line Tools' macro plugin occasionally fails under parallel compilation.

`build-app.sh` makes `build/Reader.app`, ad-hoc signed, registered for PDF and EPUB so books can be opened from Finder. The library lives in `~/Library/Application Support/Reader` (`READER_SUPPORT_DIR` overrides it).

To sync, run the server in [reader-android/server](https://github.com/satyanvm/reader-android/tree/main/server) and sign in under Reader → Settings… → Account (email and password, or Google; the emailed code is only asked for when the server has `EMAIL_CODES` on). Without an account, positions are only kept on this Mac and go up once you sign in.

`build-app.sh` takes `READER_SYNC_SERVER` (the server the app signs in to, default the deployed Worker, https://reader-sync.satyanarayanv2050.workers.dev; `http://127.0.0.1:8787` for a local server) and `READER_GOOGLE_CLIENT_ID` (enables Continue with Google). Continue with Apple is hidden for now (the code is still in `IdentityProviders.swift`); bringing it back needs the app signed by an Apple Developer team with the Sign in with Apple capability. `READER_BUNDLE_ID` and `READER_APP_NAME` build a side-by-side dev copy.

## Layout

| Path | What |
|---|---|
| `Sources/ReaderCore/Model` | `ReadingPosition`, `Stamp`, `HybridClock`, `PositionJSON` (the wire format) |
| `Sources/ReaderCore/Data` | SQLite (WAL, `synchronous=FULL`) with Android's schema, `ReadingPositionRepository` (the conflict policy), `DocumentRepository` (import + SHA-256 ids) |
| `Sources/ReaderCore/Sync` | `SyncApi`, `HttpSyncApi`, `SyncEngine`, `SyncScheduler` (retry with backoff, every 15 min, on reconnect) |
| `Sources/ReaderCore/Reader` | `ReaderController` (restore state machine), `PositionSaver` (500 ms debounce, 3 s max wait), `PageLayout`, `Scheduler` (virtual time in tests) |
| `Sources/ReaderCore/Text` | `PdfLineExtractor` (PDFKit lines + fonts), `Ocr` (Vision), `Reflow`, `PageAssembly`, `TextDocument` (per-page pipeline + disk cache), `EpubBook`, `ZipArchive`, `LenientHTML` |
| `Sources/ReaderCore/Telemetry` | `RestoreTelemetry`, logged under category `ReaderRestore` (`UNEXPECTED_RESET` as a fault) |
| `Sources/Reader` | The app: library, reader windows, Settings (sync sign-in, `SyncAccount`), `PagesView` (original pages, pinch zoom), `FlowingTextView` (TextKit), menus, `SelfTest` |

Everything in `ReaderCore` mirrors a file in the Android app and makes the same decisions. Positions are `Float` fractions, as on Android, so they round-trip bit for bit; `Stamp` breaks ties by UTF-16 order like Kotlin's `String.compareTo`.

## Mac specifics

- One window. It opens on the library; a book opens on top of it, and the back arrow (⌘[ or ⇧⌘L) returns to the library.
- Signed in, the library is the account's: a book added on another device downloads here, and removing a book removes it everywhere (`LibrarySync`, server `/v1/library`). Signing in goes straight to the library.
- Themes: White, Sepia (the default), Dark and Black, in flowing text and original pages.
- One page or two side by side (toolbar, or ⌥⌘1 / ⌥⌘2): original pages in pairs, and flowing text read page by page as an open book. Two pages need a window at least 760 pt wide (700 for original pages).
- Keys: space / ⇧space page through the window, ← → previous/next page (chapter in EPUBs), ↑ ↓ scroll, ⌘+ ⌘− ⌘0 zoom (text size in flowing text), ⌘1 / ⌘2 original pages / flowing text, ⌥⌘↑ ⌥⌘↓ previous/next page, ⌘F find.
- Trackpad pinch zooms original pages.
- Flowing text turns a window at a time by default, like Play Books, with the page curling over like paper (a cross-fade with Reduce Motion). A trackpad swipe drags the page with your fingers, finishing the turn on a flick or once it's past about a third and falling back otherwise; a scroll-wheel notch, space, the arrow keys or page up/down turn one page, and a line cut by the bottom edge is held back to start the next page. Text Settings → Layout (or View → Text Layout) switches to one continuous scroll; the choice applies to every book on this Mac.
- Saves also flush on window close, quit, deactivation and sleep. Nothing depends on that: the debounced writes alone keep the saved position within half a second of where the reader stopped.
- In flowing text, only scrolling the reader causes is saved. Text above the window grows as pages finish building, and any movement that causes is undone rather than recorded.

## Acceptance scenarios → tests

| # | Scenario | Covered by |
|---|---|---|
| 1 | Close and reopen resumes at page 187 | `ReaderControllerTests`; `scripts/acceptance.sh` |
| 2–3 | App restart, reboot | `SyncScenariosTests` (real SQLite file closed and reopened, clock reseeded); `scripts/acceptance.sh` kills the app with SIGKILL, so no quit handler runs |
| 4 | Another signed-in device | `SyncScenariosTests`, `ReaderControllerTests` (new device waits briefly for the server; refresh when the app becomes active), `InteropTests` (decodes Android's JSON bit for bit); `scripts/sync-e2e.sh` |
| 5 | Offline, then reconnect | `SyncScenariosTests`; `scripts/sync-e2e.sh` (server stopped, reading continues, server restarted) |
| 6 | Open before sync finishes | `ReaderControllerTests` (slow sync, server too slow, scroll reports during loading) |
| 7 | Delayed / out-of-order responses | `SyncScenariosTests`, `ReaderControllerTests` |
| 8 | Long PDFs, zoom, window sizes | `PageLayoutTests`; `scripts/acceptance.sh` (resize, zoom, flowing text, text size on a 500-page PDF and an EPUB) |

`scripts/sync-e2e.sh <book>` runs the real server with two libraries as two Macs: A reads, B opens the book for the first time, B reads on while the server is down, B reconnects, A reopens. Every run ends in SIGKILL.

`scripts/acceptance.sh <book> [page]` drives the real app with a scratch library: it reads to the page, kills the app, relaunches it twice and checks every relayout, logging measured and saved positions as JSON lines. The app's `SelfTest` hook only runs when `READER_SELFTEST` is set.
