# FTOers network

Firebase Hosting serves the homepage and subwebsites from one origin. One Supabase project provides shared accounts, usernames, temporary recording links and moderated 3×3 simulator leaderboards. Each account-enabled tool carries a checked-in copy of the common client in its own public/shared directory. Tools use URLs relative to their own site.

## Deployment hold and current state

**Do not deploy until hand testing and polishing are complete.** Firebase Hosting has not been updated during this work.

The Free-plan Supabase project `nwcngiivvlprzdfelyad` is created and linked. Migrations `20261119000000` and `20261119000001`, Auth URLs/email-confirmation settings, and the username-login Edge Function were applied before the deployment hold. Google OAuth is enabled; the owner confirmed that Google sign-in works. SMTP sender credentials are still pending.

**Migration `20261119000002_recording_references.sql` is prepared and tested locally but has NOT been applied to Supabase.** It converts repeated recording payloads in recent attempts, PB evidence and short links into references to one shared payload. Its upgrade test checks preservation of existing links and evidence. The API response format remains compatible with the current hosted schema, so the local UI can be hand-tested before that migration is applied.

The installed CLI is `/home/abid/Documents/GitHub/FTO/EshoObodanRakhi/main/node_modules/.bin/supabase`. Private database credentials and the Google OAuth JSON are stored in owner-only files under `~/.config/ftoers/`, outside Git. `public/shared/config.js` contains only the public project URL and browser key.

## Local preview

From this repository, run `npm run preview`, then open `http://127.0.0.1:8080/`. The `/virtual/` mount points to the simulator submodule's `dist/`; `/fto-alg-finder/` uses its existing public build. Homepage and simulator sign-in share a browser session because they use the same origin.

Simulator source changes are present in both the sibling `FTO-simulator` checkout and `submodules/virtual`. Build with `npm run build` in the simulator, then keep the hosting checkout's source/build synchronized. Commit the simulator in its own repository and update the parent gitlink before using `update-subwebsites.sh`; do not let its remote-update operation overwrite local integration work.

The homepage is static. `npm ci` and `npm run build:shared` rebuild the vendored Supabase SDK if necessary. The SDK's MIT license is in `public/shared/SUPABASE-LICENSE`.

### Updating subwebsites and shared files

Run `./update-subwebsites.sh --plan` to inspect the work without changing anything. Run `./update-subwebsites.sh --lock virtual` to sync shared account files and rebuild only the current simulator checkout without fetching Git changes. `--lock` alone builds all current submodules; normal runs update configured submodules first. `--skip-install` reuses already installed dependencies. The script works from any current directory and never deploys, stages, commits or pushes.

`public/shared/` owns only account.js, account.css, config.js, the vendored SDK and its license. Simulator leaderboards and their styles live in the simulator's src/. In submodules.json, a consumer opts into shared files with `"shared": "public/shared"` relative to its build directory. Before building, the script copies the canonical files into that directory. These are real, checked-in files, not symlinks to a parent repo. Commit refreshed copies and their `.ftoers-shared.json` manifest in the consumer repo so a friend can clone and develop it independently. Local modifications cause a sync error before managed files are overwritten. To refresh a separate working checkout, run `node scripts/sync-shared.mjs /path/to/simulator/public/shared` from this repo. The alg finder currently has no account client, so it does not receive unused account files.

The alg finder entry installs dependencies in main/, runs `bash ../build.sh --web`, and mounts the entire generated public/ directory. This retains the download landing page and its /web/ browser app. The script checks both HTML entry points and the JS/WASM pair before mounting; it does not silently host an incomplete browser build. Activate Emscripten 4.0.20 and install Rust nightly with rust-src as described in the alg finder's main/WEB.md before running that build. Its output is ignored by Git and must be built on each machine. Firebase isolation headers for /fto-alg-finder/web/** are included locally; Firebase does not read the alg finder's _headers file.

Generic npm sites can override `command` (an argument array), `output` (relative to path, default dist) and `required` (output files, default index.html). Legacy Node build-script entries retain BUILD_OUT_DIR support. Real directories at mount destinations are protected from replacement.

## Accounts and navigation

- Both sites have a right-aligned round avatar. Google profile pictures are used when available, with a username initial fallback and a guest icon.
- In the simulator, the avatar menu contains Settings, About us and Log out for signed-in users, or Sign in, Settings and About us for guests.
- Account forms use the homepage's blue palette or the simulator's green palette. The old signed-in account modal is removed.
- Settings and About open the existing simulator dialogs. On the homepage, the avatar menu contains only Sign in or Log out; About us sits in the header and credits Abid and Matt, with their existing WCA and GitHub links.
- The leaderboard is opened through the simulator's trophy button. It does not appear on the homepage.
- Administrators get **Review solves** in the simulator avatar menu. There is no standalone admin page. Evidence plays in the existing simulator replay viewer, beside the review panel. Backend authorization still protects every review RPC; hiding the menu is not the access control.
- Verified `abid.ibn.ashraf@gmail.com` is the bootstrap administrator. Additional trusted admins can be assigned by a database operator in `public.admins`; users cannot grant themselves access.

The shared storage key is `ftoers.auth.v1`. Firebase's alternate hostname, localhost and future custom domains are separate browser origins and do not share localStorage sessions. Cross-domain sign-in would need an explicit design.

## Recording retention and ranking

The local IndexedDB album retains the last 12 attempts per supported puzzle (2×2, 3×3 and 4×4), and pins single-PB, ao5-PB and ao12-PB recordings. Overlapping average windows refer to the same recording row. Older transient recordings are removed; manually saved and PB-pinned recordings remain. Existing albums are preserved, deletion tombstones are respected, and backups include rolling-window membership. A DNF occupies an average slot even though it has no complete replay.

The normalized backend migration uses one payload object per solve, with references from recent attempts, candidate PB evidence and temporary links. Trusted solve attribution takes precedence over imported share metadata. Cleanup releases a payload only after its last reference disappears.

Only new signed-in, online 3×3 attempts enter the leaderboard sequence. Local historical PBs are not backfilled. The server calculates single/ao5/ao12 values, with one fastest and slowest result trimmed from averages. Undo and abandonment are DNFs for leaderboard purposes. Every candidate PB requires administrator approval. A modified client is not cryptographically trustworthy; administrators must inspect evidence before approving it.

Offline gaps, account changes, reloads and switching puzzle sizes break the sequence. Approved result metadata stays; only current top-ten singles retain permanent public replay evidence. Average evidence is private to administrators and is pruned after review. Invalid evidence can be rejected but cannot be approved through the review UI.

Temporary links require an account and support complete 3×3 recordings up to 2 MB. Their SHA-256 identity is computed server-side from solve content. Re-sharing, re-importing or sharing from another account returns the same URL and existing row, without moving an active expiry or using another upload slot. Deliberately recreating an expired share uses the same URL for a fresh 30-day lifetime. Reads enforce expiry even before cleanup runs.

There is a 20-active-link per-account cap, a 1,000-link project cap, and a conservative 100 MB recording payload budget. Pending evidence expires after 30 days; inactive attempt rows expire after two days. Hourly cleanup removes expired/unreferenced data. Monitor actual Supabase usage; these application limits do not guarantee a provider quota.

All application tables use RLS, with direct browser table access revoked. Narrowly granted RPCs enforce ownership and admin permissions. Username login resolves email internally in the Edge Function and rate-limits requests; it never returns email addresses. The service-role key stays server-side.

## Defaults

New profiles show Statistics instead of Splits and use 60% inspection-projection opacity. Explicitly saved display preferences are preserved. The favicon uses a tightly cropped export independent of the main logo's layout padding. The homepage heading's negative letter spacing has been reduced.

## Verification

- `npm test`: static asset, syntax, public-key integrity and update/sync integration checks.
- `npm run test:db:wasm`: all migrations and 53 access, average, deduplication, expiry and retention assertions in embedded PostgreSQL. Auth fixtures and cron scheduling are stubbed.
- `npm run test:upgrade`: migrates populated legacy tables and checks existing links, evidence, shared payloads, reference-safe cleanup and trusted attribution.
- In the simulator: `node tests/polish-browser.mjs` checks avatar menus, site palettes, in-place review/replay, approval/rejection, default settings, real IndexedDB retention and backup restore.
- `node tests/network-browser.mjs` checks sharing and solver attribution in production output.
- `node tests/network.test.js`, `node tests/recording-retention.test.js`, `node tests/inspection-projection.test.js`, `node tests/recording-sharing.test.js` and `node tests/solve-recording.test.js` cover core behavior.
- Existing browser tests use the avatar-menu settings action. `npx playwright test` requires the simulator's Vite server and Chrome.

Before the new migration, 49 SQL assertions passed against hosted PostgreSQL. Current normalized-schema tests run locally only. The previous full unit suite had three failures in unchanged keyboard/puzzle test files; those were outside this polish work.

The opt-in simulator `tests/live-network.mjs` uses `FTOERS_SMOKE_SERVICE_KEY` in Node only and creates/deletes one disposable confirmed Auth account. Never expose this key in the frontend. Automated checks do not replace hand testing.

## Remaining setup and hand testing

1. Configure SMTP credentials in Supabase for public confirmation and password-reset emails. The built-in sender is restricted to project-team addresses. See [Supabase SMTP documentation](https://supabase.com/docs/guides/auth/auth-smtp).
2. Hand-test avatar menus, Google/email/username login, cross-tab sign-out, recovery, and both directions of homepage/simulator sign-in.
3. Finish real 3×3 solves and verify single/ao5/ao12 PB retention, overlapping windows, undo-as-DNF behavior, offline gaps and account changes.
4. Verify short-link deduplication and 4×4 text/JSON sharing.
5. Review evidence as the administrator within the simulator; approve/reject and watch top-ten singles anonymously.
6. Review the draft privacy and terms text before publication. Keep the deployment hold until polishing and hand testing are complete.

Google brand verification is separate from OAuth setup and has not been submitted. The local `/privacy/` and `/terms/` pages are drafts. An upload-ready transparent logo is `public/logo-google-120.png`. Once approved pages are public, configure Google Auth Platform → Branding with `FTOers`, that PNG and the public homepage/privacy/terms URLs, complete requested ownership checks, and submit through Verification Center. Do not submit inaccessible draft URLs or deploy prematurely to satisfy verification.
