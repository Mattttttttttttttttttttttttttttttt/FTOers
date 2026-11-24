# FTOers network

Firebase Hosting serves the homepage and subwebsites from one origin. One Supabase project provides shared accounts, usernames, temporary recording links and moderated 3×3 simulator leaderboards. Each account-enabled tool carries a checked-in copy of the common client in its own public/shared directory. Tools use URLs relative to their own site.

## First production deployment — 20 November 2026

**The owner lifted the deployment hold and authorized the first release on 20 November 2026.** Production is https://ftoers.web.app, with the simulator at `/virtual/`, algorithm finder browser build at `/fto-alg-finder/web/`, and optimal block solver at `/FB/`. The release was built with `./update-subwebsites.sh --lock` from the selected local revisions and published to Firebase Hosting. Private pre-release database/Auth snapshots are stored under `~/.local/state/ftoers/backups/`, outside the repository. Immutable staged public files and their hashes are under ignored `.release/` directories.

The Free-plan Supabase project `nwcngiivvlprzdfelyad` is created and linked. All six migrations through `20261121000002`, Auth URLs/email-confirmation settings, and the username-login Edge Function are applied. Google OAuth and Brevo SMTP are configured. Google consent-screen branding still requires verification/publication in Google Auth Platform; it is separate from the website deployment.

**Migration `20261119000002_recording_references.sql` is applied.** It converts repeated recording payloads in recent attempts, PB evidence and short links into references to one shared payload. Its upgrade test checks preservation of existing links and evidence. Existing links and evidence were preserved during the production upgrade.

**Migration `20261120000000_storage_limits.sql` is applied.** It depends on the recording-reference migration and adds the daily short-link quota, database size guards and admin storage metrics. The daily quota and database write guards are active in production.

The installed CLI is `/home/abid/Documents/GitHub/FTO/EshoObodanRakhi/main/node_modules/.bin/supabase`. Private database credentials and the Google OAuth JSON are stored in owner-only files under `~/.config/ftoers/`, outside Git. `public/shared/config.js` contains only the public project URL and browser key.

## Local preview

From this repository, run `npm run preview`, then open `http://127.0.0.1:8080/`. The `/virtual/` mount points to the simulator submodule's `dist/`; `/fto-alg-finder/` uses its existing public build. Homepage and simulator sign-in share a browser session because they use the same origin.

Simulator source changes are present in both the sibling `FTO-simulator` checkout and `submodules/virtual`. Build with `npm run build` in the simulator, then keep the hosting checkout's source/build synchronized. Commit the simulator in its own repository and update the parent gitlink before using `update-subwebsites.sh`; do not let its remote-update operation overwrite local integration work.

The homepage is static. `npm ci` and `npm run build:shared` rebuild the vendored Supabase SDK if necessary. The SDK's MIT license is in `public/shared/SUPABASE-LICENSE`.

### Updating subwebsites and shared files

Select one or several sites with flags: `./update-subwebsites.sh --virtual --FB`. Flags are case-insensitive; `--fb` also works. Only selected sites are fetched, built, synced, and mounted. An FB-only or virtual-only update never loads Emscripten or rebuilds the algorithm finder. Use `./update-subwebsites.sh --FB --lock` to build the current FB checkout without fetching, or add `--plan` to preview actions. Positional IDs remain supported.

Run `./update-subwebsites.sh --plan` to inspect the work without changing anything. Run `./update-subwebsites.sh --lock virtual` to sync shared account files and rebuild only the current simulator checkout without fetching Git changes. `--lock` alone builds all current submodules; normal runs update configured submodules first. `--skip-install` reuses already installed dependencies. The script works from any current directory and never deploys, stages, commits or pushes.

`public/shared/` owns only account.js, account.css, config.js, the vendored SDK and its license. Simulator leaderboards and their styles live in the simulator's src/. In submodules.json, a consumer opts into shared files with `"shared": "public/shared"` relative to its build directory. Before building, the script copies the canonical files into that directory. These are real, checked-in files, not symlinks to a parent repo. Commit refreshed copies and their `.ftoers-shared.json` manifest in the consumer repo so a friend can clone and develop it independently. Local modifications cause a sync error before managed files are overwritten. To refresh a separate working checkout, run `node scripts/sync-shared.mjs /path/to/simulator/public/shared` from this repo. The alg finder currently has no account client, so it does not receive unused account files.

The FB solver is live at **https://ftoers.web.app/FB/** (first deployed 23 November 2026). Its source is public and the app is entirely static; no backend changes are required.

The FB entry builds the public [FTO-FB repository](https://github.com/Abid-speedcuber/FTO-FB) with Vite and mounts its `dist/` at `public/FB/`. Its relative asset paths support this subdirectory, including the solver worker. Generated mount paths are ignored; the submodule revision and configuration are tracked. Solver tables are saved locally in IndexedDB and require no account/backend integration.

The alg finder entry installs dependencies in main/, runs `bash ../build.sh --web`, and mounts the entire generated public/ directory. This retains the download landing page and its /web/ browser app. The script checks both HTML entry points and the JS/WASM pair before mounting; it does not silently host an incomplete browser build. Activate Emscripten 4.0.20 and install Rust nightly with rust-src as described in the alg finder's main/WEB.md before running that build. Its output is ignored by Git and must be built on each machine. Firebase isolation headers for /fto-alg-finder/web/** are included locally; Firebase does not read the alg finder's _headers file.

Generic npm sites can override `command` (an argument array), `output` (relative to path, default dist) and `required` (output files, default index.html). Legacy Node build-script entries retain BUILD_OUT_DIR support. Real directories at mount destinations are protected from replacement.

## Accounts and navigation

- Both sites have a right-aligned round avatar. Google profile pictures are used when available, with a username initial fallback and a guest icon.
- In the simulator, the avatar menu contains Settings, About us and Log out for signed-in users, or Sign in, Settings and About us for guests.
- Account forms use the homepage's blue palette or the simulator's green palette. The old signed-in account modal is removed.
- Password fields have independent show/hide controls. Signup and new-password forms require matching passwords. Signup and recovery emails offer a code as well as the existing link: read the code on any device and enter it in the browser running FTOers. Pending verification stores only its email and flow kind in sessionStorage, never passwords or codes; Resend code respects Supabase’s rate limits. On localhost, the phone cannot open the PC’s loopback address.
- Settings and About open the existing simulator dialogs. On the homepage, the avatar menu contains only Sign in or Log out; About us sits in the header and credits Abid and Matt, with their existing WCA and GitHub links.
- The leaderboard is opened through the simulator's trophy button. It does not appear on the homepage.
- Administrators get **Review solves** in the simulator avatar menu. There is no standalone admin page. Evidence plays in the existing simulator replay viewer, beside the review panel. Backend authorization still protects every review RPC; hiding the menu is not the access control.
- Verified `abid.ibn.ashraf@gmail.com` is the bootstrap administrator. Additional trusted admins can be assigned by a database operator in `public.admins`; users cannot grant themselves access.

The shared storage key is `ftoers.auth.v1`. Firebase's alternate hostname, localhost and future custom domains are separate browser origins and do not share localStorage sessions. Cross-domain sign-in would need an explicit design.

## Recording retention and ranking

The local IndexedDB album retains the last 12 attempts per supported puzzle (2×2, 3×3 and 4×4), and pins single-PB, ao5-PB and ao12-PB recordings. Overlapping average windows refer to the same recording row. Older transient recordings are removed; manually saved and PB-pinned recordings remain. Existing albums are preserved, deletion tombstones are respected, and backups include rolling-window membership. Abandoned attempts retain DNF recordings through the point where they stopped. Older discarded DNF recordings cannot be recovered. Saved ao5/ao12 groups reference the same recording rows as recent/PB entries.

The normalized backend migration uses one payload object per solve, with references from recent attempts, candidate PB evidence and temporary links. Trusted solve attribution takes precedence over imported share metadata. Cleanup releases a payload only after its last reference disappears.

Evidence comparisons in the backend and simulator review panel allow up to 0.000001 ms (one nanosecond) of floating-point/JSON serialization noise. Regression fixtures use real high-resolution solve values, covering single/ao5/ao12 and rejecting actual alterations or missing/pause/undo evidence. The precision migration `20261121000002` is applied.

The skipped-scramble migration `20261121000000` and pause/connection-retry migration `20261121000001` are applied. Only new signed-in, online 3×3 attempts enter the leaderboard sequence. Local historical PBs are not backfilled. The server calculates single/ao5/ao12 values, with one fastest and slowest result trimmed from averages. Undo and abandonment are DNFs for leaderboard purposes. Replacing an unstarted scramble with triple Escape or Reset adds a hidden DNF to the same online sequence, without adding a local time. One DNF can be trimmed from an average; two make the window ineligible. A failed skip request breaks the sequence, including for a solve already queued behind it. Every candidate PB requires administrator approval. A modified client is not cryptographically trustworthy; administrators must inspect evidence before approving it.

Account changes, reloads and switching puzzle sizes break the sequence. A pause after timing starts, including automatic tab/blur/dialog pauses, is permanently a leaderboard DNF but leaves the local time/replay available. The server checks both the pause flag and legacy pause events; average evidence rejects paused non-DNF recordings. Detected connection interruptions shorter than five seconds preserve eligibility and the sequence, without stopping the timer. At five seconds the active solve becomes ineligible and new averages start a new sequence. Finishing during the grace window waits for reconnection. Lost start/finish/skip responses retry the same receipt ID; server-side receipts prevent duplicate attempts, DNFs, recordings and candidates. Start retries compensate for at most five seconds of request delay. Approved result metadata stays; only current top-ten singles retain permanent public replay evidence. Average evidence is private to administrators and is pruned after review. Invalid evidence can be rejected but cannot be approved through the review UI.

Temporary links require an account and support complete 3×3 recordings up to 2 MB. Their SHA-256 identity is computed server-side from solve content. Re-sharing, re-importing or sharing from another account returns the same URL and existing row, without moving an active expiry or using another upload slot. Deliberately recreating an expired share uses the same URL for a fresh 30-day lifetime. Reads enforce expiry even before cleanup runs.

There is a **500,000-byte per-account daily short-link quota**, a 20-active-link per-account cap, a 1,000-link project cap, and a conservative 100 MB recording payload budget. The daily quota uses `octet_length(replay::text)` of PostgreSQL JSONB (UTF-8 bytes), resets at **00:00 UTC** (06:00 Bangladesh), and charges only successful new links. Reusing an active link from any account costs zero bytes, keeps its expiry, and works even at capacity. Deleting/expiring links does not refund today’s quota. Recreating an expired link starts a new 30-day lifetime and consumes quota again. A quota ledger has one private row per account; it rolls over in place instead of keeping an upload log.

App writes also stop conservatively at **350 MB total PostgreSQL database size**, including a reserve for incoming rows/index/page overhead. All current app tables have write guards; deletes and shrinking updates remain available so cleanup can run. Existing short links and public replays remain readable. The 100 MB payload cap is serialized across recording writes. Admins can inspect actual database/payload byte counts via the private `storage_status()` RPC. These limits cannot provide an absolute 500 MB guarantee: managed Auth activity, WAL/database overhead, external writers, and any future tables also need monitoring. Supabase Free currently has a 500 MB database allowance and a separate 1 GB file-storage allowance; recording objects use the database. Pending evidence expires after 30 days; inactive attempt rows expire after two days. Hourly cleanup removes expired/unreferenced data. Monitor the Supabase usage dashboard before opening signups broadly.

All application tables use RLS, with direct browser table access revoked. Narrowly granted RPCs enforce ownership and admin permissions. Username login resolves email internally in the Edge Function and rate-limits requests; it never returns email addresses. The service-role key stays server-side.

## Defaults

New profiles show Statistics instead of Splits and use 60% inspection-projection opacity. Explicitly saved display preferences are preserved. The favicon uses a tightly cropped export independent of the main logo's layout padding. The homepage heading's negative letter spacing has been reduced.

## Verification

- `npm test`: static asset, syntax, public-key integrity and update/sync integration checks.
- `npm run test:db:wasm`: all migrations and 53 access, average, deduplication, expiry and retention assertions in embedded PostgreSQL. Auth fixtures and cron scheduling are stubbed.
- `npm run test:upgrade`: migrates populated legacy tables and checks existing links, evidence, shared payloads, reference-safe cleanup and trusted attribution.
- In the simulator: `node tests/polish-browser.mjs` checks avatar menus, site palettes, in-place review/replay, approval/rejection, default settings, real IndexedDB retention and backup restore.
- `node tests/network-browser.mjs` checks sharing and solver attribution in production output.
- `node tests/account-dialogs.mjs` checks homepage/simulator password visibility/matching, signup and recovery email codes, invalid codes/resends, verification persistence, PKCE recovery callbacks, password updates, onboarding, Google redirects and mobile layouts against mocked Auth endpoints. It sends no real email.
- `tests/live-email-codes.mjs` is an opt-in hosted Auth check using a service-role key in Node only: it generates signup/recovery codes for one disposable account without sending email, verifies them in separate clients, changes the test password, checks sign-in and deletes the account. Check that password-change notification emails are disabled before running it.
- `node tests/network.test.js`, `node tests/recording-retention.test.js`, `node tests/inspection-projection.test.js`, `node tests/recording-sharing.test.js` and `node tests/solve-recording.test.js` cover core behavior.
- Existing browser tests use the avatar-menu settings action. `npx playwright test` requires the simulator's Vite server and Chrome.

Before the new migration, 49 SQL assertions passed against hosted PostgreSQL. Current normalized-schema tests run locally only. The previous full unit suite had three failures in unchanged keyboard/puzzle test files; those were outside this polish work.

The opt-in simulator `tests/live-network.mjs` uses `FTOERS_SMOKE_SERVICE_KEY` in Node only and creates/deletes one disposable confirmed Auth account. Never expose this key in the frontend. Automated checks do not replace hand testing.

## Brevo SMTP setup

Brevo SMTP and the FTOers confirmation/recovery templates are configured in the hosted project. Supabase’s account-email limit is 30 per hour across the project, with a 60-second per-recipient interval. The first owner-only SMTP test arrived, and the owner confirmed it exposed no street address or postal code. The private [backend-checks repository](https://github.com/Abid-speedcuber/ftoers-backend-checks) contains daily database checks and a monthly SMTP schedule. The owner approved monthly mail after inspecting the test; `ENABLE_EMAIL_CHECKS=true` is now enabled. The database check runs daily at 12:23 Bangladesh time, and the SMTP email runs on the 1st of each month at 12:41 Bangladesh time. No website deployment or database migration was performed.

The checked-in confirmation/recovery email templates are in `supabase/templates/`. They contain the FTOers wordmark and Supabase's per-request `ConfirmationURL`, with no postal address or externally hosted image. Their hosted copies are only updated when the SMTP setup helper is applied.

Verify the FTOers sender in Brevo, create a standard SMTP key, and fill `smtp_login`, `smtp_key`, and `sender_email` in the owner-only `~/.config/ftoers/smtp.json` file (permissions 600, outside Git). The SMTP login is the value shown on Brevo's SMTP page; it can differ from the account email. Use an SMTP key, not an API key.

Run `python3 scripts/configure-smtp.py` to validate local fields/templates without a connection. `python3 scripts/configure-smtp.py --apply` first checks a TLS-protected Brevo SMTP login, then configures Supabase's SMTP sender and confirmation/recovery templates using the existing CLI keyring token. It sends no email and performs no website deployment or database migration. After configuration, send the initial test only to the administrator and inspect its body and raw headers for address exposure before using it for other users.

## Remaining setup and hand testing

1. Hand-test real confirmation and recovery email delivery through Supabase. The initial SMTP privacy check and monthly-cron activation are complete.
2. Hand-test avatar menus, Google/email/username login, cross-tab sign-out, recovery, and both directions of homepage/simulator sign-in.
3. Finish real 3×3 solves and verify single/ao5/ao12 PB retention, overlapping windows, undo-as-DNF behavior, offline gaps and account changes.
4. Verify short-link deduplication and 4×4 text/JSON sharing.
5. Review evidence as the administrator within the simulator; approve/reject and watch top-ten singles anonymously.
6. Review the draft privacy and terms text before publication. Keep the deployment hold until polishing and hand testing are complete.

Google brand verification is separate from OAuth setup and has not been submitted. The local `/privacy/` and `/terms/` pages are drafts. An upload-ready transparent logo is `public/logo-google-120.png`. Once approved pages are public, configure Google Auth Platform → Branding with `FTOers`, that PNG and the public homepage/privacy/terms URLs, complete requested ownership checks, and submit through Verification Center. Do not submit inaccessible draft URLs or deploy prematurely to satisfy verification.

The alg finder browser build requires Emscripten **4.0.20**. The updater checks `emcc` on `PATH`, then SDKs in `$EMSDK`, `$XDG_DATA_HOME/ftoers/emsdk`, `$XDG_DATA_HOME/emsdk` (default data directory: `~/.local/share`), `~/emsdk`, and `~/.emsdk`. It loads the matching SDK only for that site’s install/build processes. Set `FTOERS_EMSDK_ENV=/path/to/emsdk/emsdk_env.sh` for another SDK location. The script checks the SDK before installing npm dependencies and never installs or activates SDKs itself. `--plan` works without an SDK. Rust nightly and `rust-src` are also required by the alg finder.

Storage-limit verification: `node tests/storage-limits.mjs`; complete schema/RPC checks: `node tests/postgres-wasm.mjs`. These use local PostgreSQL WASM and do not contact Supabase.

**Migration `20261120000001_manual_leaderboard.sql` is applied.** It follows the recording-reference and storage-limit migrations. Online attempts produce a private `draft` for each latest eligible single/ao5/ao12 result that improves the solver’s approved leaderboard entry (or supplies their first entry). Older unsubmitted or pending times do not define eligibility. Only the owner’s explicit `submit_leaderboard` call moves a candidate into pending review; repeated clicks are idempotent. A newer explicit submission replaces the previous pending result for that solver/category, even if slower than that pending result; it must still beat the currently approved leaderboard entry. Both comparison times are returned to the UI so replacement is visible before clicking. Old automatically pending rows become private drafts; approved results stay public. Only one draft per metric is retained, old draft videos expire after 30 days, and bounded draft metadata stays without blocking later leaderboard improvements. Pending submissions receive 30 days from their explicit submission date. New clients use `record_online_attempt` and never fall back to an older auto-submitting RPC. `my_leaderboard_candidates` restores available choices after reload. `review_queue` includes submission dates; average evidence includes undo/abandonment reasons. Test with `npm run test:manual-leaderboard`.

**Migration `20261120000002_submission_notifications.sql` is applied.** It adds private approval/rejection notifications with server-side read state, capped at 50/account and 90 days. The existing hourly cleanup also prunes this history. Reviewer text is now labelled as a message to the solver; historical internal notes are not backfilled. The manual-submission migration also checks recording evidence for every non-DNF average member, including trimmed solves, and rechecks it at explicit submission. The client requires `evidence_complete: true` before presenting a submit action. Verify with `npm run test:notifications`.

Live first-release checks passed: homepage username onboarding, shared homepage/simulator sessions, explicit/idempotent leaderboard submission, short-link deduplication/public playback, private review access, rejection notifications/read state, cross-tab sign-out, policy pages and the isolated algorithm-finder browser build. One disposable account and its synthetic recording were removed afterward; no test email was sent or synthetic result approved. The backend used about 14 MB at release, well below the configured storage guards.

## Pending local changes: admin recovery and notification layout

Migration `20261121000003_admin_recovery.sql` is local only; do not apply it without owner approval after hand testing. It adds admin-only inspection/recovery RPCs and auditable recovery metadata. Definite undo/pause/DNF/identity problems block recovery; missing provenance and older pause flags require explicit acknowledgement. The administrator must review the existing player and keyboard layout and supply a reason. Confirmations reuse payloads and are idempotent, preserve old rejection notifications, and do not fabricate online attempts.

The simulator now uses a separate bell/notifications dialog and leaderboard-rules modal. Recovery is accessed from Review solves. The new recovery RPCs will not work against the hosted backend until this pending migration is approved and applied. Local database tests exercise the entire workflow; browser tests use an isolated mock backend without production writes.

## Pending local changes: investigation holds and connection status

Migration `20261121000004_investigation_holds.sql` is local only. It adds a private investigating state, mandatory solver-facing rejection/hold explanations, bounded and idempotent hold notifications, final decisions after investigation, and 30-day cleanup for held evidence. New submissions preserve ongoing investigations. Admin recovery explicitly warns about an existing investigation. A backward-compatible notification endpoint prevents older clients from rendering a held notice as a rejection. No hosted schema or website changes have been made for this update.

The simulator adds a green/gray connection dot beside the avatar without server-side presence writes or additional polling. Notification copy uses full sentences and displays the administrator’s exact message.

## Share previews

The homepage, Simulator, First Block, and both Alg Finder entry pages include static Open Graph and Twitter metadata. Their absolute `og:image` URLs point to 1200×630 PNGs with the app’s logo and title, so link crawlers do not need JavaScript. Editable SVG compositions are kept alongside each PNG.

In the sibling-project workspace, regenerate the images with `node scripts/generate-share-previews.mjs` from this repository. The generator uses the Simulator’s installed Playwright dependency and existing logos; it does not build WASM or deploy anything. Verify all entry points with `node --test tests/share-previews.test.mjs`. Source changes in the neighboring app repositories are picked up through the normal subwebsite update/release workflow.
