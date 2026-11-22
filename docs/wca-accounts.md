# WCA accounts

All website, migration, Edge Function and Auth configuration changes stay local
until Abid has hand-tested the update and explicitly approves deployment.

The avatar menu places **Connect WCA account** immediately above **Log out**.
It uses Supabase's identity-linking flow, preserving the signed-in user UUID,
username, submissions and results. Once connected, the item becomes **WCA
account**, showing the linked identity. WCA login is available on both account
surfaces; new users still choose a unique FTOers username.

Signup and username onboarding accept an optional WCA ID. Manually entered IDs
are self-reported; only a `custom:wca` Auth identity can verify one. The leaderboard
shows a person-profile link, with a check mark for connected/verified IDs and an
accessible self-reported label otherwise. WCA accounts without a WCA ID can log
in and connect normally. Connecting never merges two existing FTOers profiles;
if the WCA identity belongs to another profile, the user must sign in to that
profile or contact Abid.

## App registration and credentials

Register a confidential application named FTOers at
https://www.worldcubeassociation.org/oauth/applications with scope `public`.
The redirect URI is the **Callback URL shown in Supabase's custom provider form**
(normally `https://nwcngiivvlprzdfelyad.supabase.co/auth/v1/callback`). The homepage
is not a WCA redirect URI: Supabase's redirect allowlist handles the final return
to the homepage or simulator.

Credentials live outside the repositories in
`~/.config/ftoers/wca.json` (permissions 600):

```json
{"client_id":"...","client_secret":"..."}
```

Preview the provider configuration without changing anything:

```sh
node scripts/configure-wca-provider.mjs
```

The script's `--apply` mode requires a server-side `SUPABASE_SECRET_KEY` and
changes hosted Auth configuration. Do not run it before release approval.
It creates/updates `custom:wca` with `email_optional: true`, scope `public`, PKCE
and custom-claims allowlist `wca_id`, `wca_user_id`. It does not request WCA email,
manage events or write to WCA. Never put the secret in browser config, Git,
terminal arguments or logs.

## Backend activation checklist for an approved release

1. Apply core migration `20261122000003_wca_accounts.sql`. The separate
   `20261122000004_wca_review_profiles.sql` requires the pending investigation and
   review pagination changes; it is not part of the core auth release.
2. Deploy Edge Function `wca-userinfo`, with JWT verification disabled (its incoming
   bearer token is a WCA token; the fixed WCA `/api/v0/me` endpoint authenticates it).
3. Configure the custom OAuth2 provider using the previewed values. Confirm the
   dashboard Callback URL exactly matches the WCA application.
4. Enable **Custom OAuth providers** (`custom_oauth_enabled`) and **Allow manual linking**
   (`security_manual_linking_enabled`) in Supabase Auth. The local config includes
   `enable_manual_linking = true`; changing this file does not change hosted Auth.
5. Test live OAuth signup, sign-out/sign-in, connecting an existing email/Google
   profile, cancelled consent and an already-linked WCA account. Verify the same
   FTOers UUID/results are retained and homepage/simulator share the session.

The adapter forwards tokens only to WCA, retains none and returns flat identity
claims. Immutable numeric WCA account IDs are subjects; optional WCA person IDs
are not login keys. Verified IDs come from protected `auth.identities`, never
user-editable metadata. Removing an identity removes verified status on the next
profile/leaderboard fetch. Existing recordings and submissions are not rewritten
or duplicated. Leaderboards continue to read the older RPC if the new RPC is not
yet installed.

## Local checks

```sh
node --test tests/wca-userinfo.test.mjs
node tests/postgres-wasm.mjs wca-accounts.test.sql
```

In the simulator checkout, `npm run build && node tests/account-dialogs.mjs`
checks account flows with mocked Auth responses on both surfaces. No real email
or OAuth credentials are used. Successful mocked checks do not establish live
OAuth compatibility or replace Abid's hand testing.

References: [WCA API](https://docs.worldcubeassociation.org/knowledge_base/v0_api.html),
[Supabase custom providers](https://supabase.com/docs/guides/auth/custom-oauth-providers),
[identity linking](https://supabase.com/docs/guides/auth/auth-identity-linking).

## Live checks

`node tests/live-wca-accounts.mjs` requires a server-side `SUPABASE_SECRET_KEY`
and explicit authorization to test the hosted project. It creates and deletes a
temporary confirmed test account, checks onboarding and identity-link initiation,
and sends no email or solve/submission. Completing consent with a real WCA
account is a separate human check; this test does not impersonate a WCA user.

Local website testing uses the same hosted backend as the deployed site. The
allowlist includes `http://127.0.0.1:5173/`, `http://localhost:5173/`, and homepage
previews on port 8080. WCA always returns to the Supabase callback; Supabase then
returns to the allowlisted page where sign-in/linking began.

## 22 November 2026 activation

Abid explicitly requested usable WCA authentication for localhost and production.
Core WCA migration `20261122000003`, the `wca-userinfo` function, custom OAuth and
manual linking, and the `custom:wca` provider were activated. Firebase received
an isolated release based on the previously published assets with the WCA
account/leaderboard additions and logo. Unrelated pending simulator/backend
updates were excluded.

Live checks verified client credentials, localhost and production redirects with
PKCE, a temporary account's profile/identity-link initiation and cleanup, the
public WCA leaderboard RPC, and published asset hashes. Completing consent with a
real WCA account still requires its owner.

Because core WCA auth was released ahead of earlier pending engineering
migrations, a later approved full migration release must include those earlier
versions explicitly (for CLI migration push, inspect a dry run with `--include-all`).
Do not skip or mark them applied merely because a higher WCA version is present.
