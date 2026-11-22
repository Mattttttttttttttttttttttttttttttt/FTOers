# Profiles and account merging (local update)

The profile website update remains local. Abid approved and released the
username/account-merging backend on 22 November 2026; see activation notes below.
Any website release still needs its own hand testing and explicit approval. The preceding WCA/logo work
was committed separately in simulator `b7f53d3` and FTOers `9b94ddf`.

The avatar menu starts with **Profile**, which opens account details, connected sign-in methods,
optional self-reported WCA ID editing and **Merge accounts**. Connect Google/WCA
are inside the profile modal. Existing site Settings/About actions stay in their
existing menu positions. Log out is inside Profile rather than the avatar menu.

The profile header shows the account avatar beside its name/email. Its Change
username button opens an inline editor. `rename_username` updates only the
canonical profile, checks the existing case-insensitive unique index and allows
repeated/case-only renames without a cooldown. A failed duplicate change leaves
the old username intact. Existing results retain their IDs and recordings retain
their historical names; leaderboard rows show the current profile name. Backend
activation includes migration `20261122000006_username_changes.sql`.

## User flow

1. Sign into FTOers and open Profile → Merge accounts.
2. Verify the current account, then the other account. Each verification uses a
   separate popup and its own session-storage namespace; the main login is not
   overwritten. Google, WCA and email/password verification are supported.
3. Review both profiles and choose the username/profile to retain. An OAuth
   account without a chosen username can be absorbed, but cannot be chosen as
   the retained profile. Different connected WCA accounts require admin help.
4. Check the confirmation box and merge. Preview tickets expire after five
   minutes and are bound to the actor and both independently verified accounts.
5. Sign in again with either method. Both resolve to the retained profile.

The real backend must support this update before verification starts. Against
an older backend the profile modal remains usable and Merge accounts explains
that its backend update is pending. It does not start OAuth or silently merge.

## Ownership and data

Supabase Auth users and identities are retained unchanged. `account_members`
resolves their authenticated UUIDs to one canonical profile. `account_uid()` is
the app authorization boundary; existing RPCs are updated in the migration.
**New app RPCs must use `public.account_uid()` rather than raw `auth.uid()`.**
Only the resolver and reauthentication detection intentionally read the raw ID.

The service-only merge functions require IDs derived from verified Auth tokens.
The Edge Function verifies all three tokens through Auth and requires recent
AMR authentication (not merely a freshly refreshed access token) for both
proofs. Tokens are never stored in database merge requests, browser local
storage, request logs or error responses. Popup proof tokens remain in memory
in the opener and in isolated session storage only until acknowledged.

Confirmation serializes merges and locks the profiles. Data is moved in one
transaction; a changed preview, expired ticket or conflicting account aborts
before ownership changes. Repeating a completed ticket returns its original
result. Merge previews are rate-limited and expire; cleanup removes old requests.

- Approved results and rejected/held review history retain their states/notes.
  Public rankings naturally select the best approved result for the one profile.
- Latest pending submission per category remains pending. Other pending offers
  become `superseded`, without a fabricated rejection or deletion of evidence.
- Unsubmitted drafts are cleared. Historical attempt sequences are separated;
  merging cannot create an uninterrupted average from two different histories.
- Recording payloads, hashes, keyboard references and link URLs/expiries stay
  intact. Recovery recognizes a recorded legacy solver ID as a merged member.
  Normal recording/notification retention policies still apply.
- Same-day sharing usage is summed, saturating at the existing 500 kB cap. A
  merge never supplies a new allowance or extends active link expiry.
- Local albums are not uploaded or copied. They remain on their original device.
- Old usernames stay reserved for legacy username login; username/password login
  can resolve an email/password identity belonging to a merged member.
- Confirmed administrator access survives choosing either owned profile.

Every pre-merge session ID is blocked in the transaction. The resolver also
requires a live Auth session for merged members, so an already signed-out JWT
cannot gain merged access. Token refresh preserves session IDs and cannot evade
this block. Best-effort global Auth sign-out is extra cleanup; it is not the
security boundary. New sign-in creates a new session ID and restores access.

For account deletion, administrators must identify **all** Auth user IDs in the
canonical profile's membership before removing the account, so an alternate
sign-in is not accidentally left behind. Do not delete a single alias assuming
it deletes the entire merged profile. No self-service unmerge is provided.

## Later approved activation

Apply `20261122000005_account_merging.sql` with its existing schema dependencies;
deploy `merge-accounts` and the updated `username-login` functions. The merge
function has gateway JWT verification disabled because it performs explicit
verification of the current token and both proof tokens itself. Its service
credentials stay server-side.

Add the exact popup callback URLs from local `supabase/config.toml` to the hosted
Supabase Auth redirect allowlist, for homepage `/shared/merge-callback.html` and
simulator `/virtual/shared/merge-callback.html` on the deployed domains and local
preview origins. These are **Supabase** return URLs. WCA/Google still use the same
Supabase `/auth/v1/callback`; their application callback registration is unchanged.

Publish the new shared modules/HTML through the existing shared sync script.
Then hand-test real Google/WCA proof and both choices using disposable accounts
first, verify both logins see the same data, and confirm an old session is denied.
Do not merge a real user's profiles as a deployment smoke test.

## Focused checks

Backend: `npm run test:merging` and the existing database regression check.
Simulator: `playwright test tests/browser/profile-merge.spec.js --workers=1`
and the built `tests/account-dialogs.mjs` checks. Browser OAuth responses in
these tests are mocked; real consent and hosted configuration remain hand tests.

## Backend activation: 22 November 2026

Abid explicitly approved the username/account-merging backend release. Only
migrations `20261122000005` and `20261122000006`, the `merge-accounts` function,
the updated `username-login` function, and exact Auth return allowlist entries
were released. Firebase Hosting was not deployed. The local profile UI can now
use the live backend. Production profile UI and its static popup callback pages
remain part of the separate frontend release.

A disposable-account live check verified rename uniqueness, both fresh sign-ins
resolving to one merged profile, session blocking, quota aggregation and merged
username/password login. Test accounts/data were deleted; no emails, solves or
leaderboard submissions were generated. This does not impersonate Google/WCA
users or replace their real OAuth consent hand test.

**Important for the pending engineering release:** when applying the older
unreleased migrations with `--include-all`, apply
`20261122000007_merge_compatibility_after_pending_updates.sql` last. It restores
canonical ownership resolution in RPC definitions installed by those older
migrations and normalizes legacy recovery attribution. Migration 07 is left
pending deliberately; applying it before the older definitions would not protect
their future replacement. A normal fresh full migration run includes it last.

The merge release also includes `20261122000008_merge_archive_retention.sql`: the
existing hourly merge cleanup expires recording references in superseded pending
submissions after 30 days, preserves their result metadata, and collects only
unreferenced payloads. This cleanup stays effective when older pruning routines
are later installed. The pending investigation migration's status constraint also
allows `superseded`, so it can upgrade a database that already has merged
accounts. That pending review migration was not deployed in this release.

The database harness accepts `FTOERS_MIGRATION_VERSIONS` as an ordered comma-
separated version list. The real release order (production baseline → merge/
rename/retention → older pending engineering updates → compatibility migration)
passed 41 ownership/retention assertions, including a new online attempt made
through a merged alias.

## Verification and network failure UI

A returned popup proof means **Signed in**, not that the merge service has
accepted the pair. Completed sign-ins collapse to an identity card with a Change
button. Only a successful server preview marks the pair verified for merging.
Network failures keep the sign-in proofs in memory and offer Retry account
check; expired proofs require a new sign-in. A lost confirmation response is
reported as an unknown outcome and requires checking the profile after a fresh
sign-in, rather than claiming no merge happened or encouraging a second merge.

Browser tests cover these failures, plus a real browser test of localhost
sign-ins and the live preview endpoint using disposable accounts (no merge
confirmation). The reported transient `Failed to fetch` was not reproduced from
127.0.0.1:5173 or localhost:5173; the affected page's exact origin is needed if it
persists. No backend configuration was changed for this UI fix.
