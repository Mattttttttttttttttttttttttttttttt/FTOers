# FTOers backend checks

The schedule is hosted in the private administrator-owned repository `Abid-speedcuber/ftoers-backend-checks`. Email delivery is gated by the repository variable `ENABLE_EMAIL_CHECKS=true`; leave it disabled until the first email has been inspected.

- Daily at 06:23 UTC (12:23 Bangladesh): read the public leaderboard RPC, which exercises the database without modifying solves or users.
- Monthly on the 1st at 06:41 UTC (12:41 Bangladesh): send one SMTP check to the configured owner only, as authorized. An SMTP login alone does not count toward Brevo's 90-day successful-send requirement.
- Manual runs perform the database read by default. Explicitly select `send_email` to test mail.

The recommended destination is a small **private** GitHub repository owned by the administrator. GitHub automatically disables scheduled workflows in public repositories after 60 days with no repository activity. A private repository avoids that particular inactivity rule; it still depends on Actions availability and the account's included monthly minutes. Supabase pausing is based on low database activity over seven days, so these checks are best-effort, not a guarantee against pausing.

To install, copy `backend_health.py`, `config.json`, and optionally the test into that repository's root. Put `workflow.yml` at `.github/workflows/backend-checks.yml`. Set `SMTP_LOGIN` and `SMTP_KEY` as Actions secrets. After the initial privacy check, set the repository variable `ENABLE_EMAIL_CHECKS` to `true` to activate monthly mail. `config.json` contains a public Supabase browser key, not a service-role or management token. The workflow has read-only repository permissions and does not deploy the website or run migrations. Do not put the SMTP key in Git.

Run `python3 test_backend_health.py` for mock tests. Run `python3 backend_health.py` for a real, read-only database check. A mail test is only appropriate after the sender is verified; inspect the first email's body and raw headers for address exposure before activating monthly mail.


## Direct Supabase keepalive on cron-job.org

The enabled `FTOers — Supabase keepalive` job at
https://console.cron-job.org/jobs/8915576 reads the public single leaderboard
directly. Its schedule is `17 */6 * * *` in `Asia/Dhaka` (00:17, 06:17,
12:17, 18:17 daily). It sends a POST to the configured Supabase URL's
`/rest/v1/rpc/leaderboard`, JSON body `{"kind":"single"}`, `Content-Type:
application/json`, and the public publishable key from `config.json` as the
`apikey` header. It does not use GitHub tokens or privileged database keys.

The cron-job.org test returned HTTP 200 on 2026-11-22. This job is independent
of GitHub's scheduled-workflow inactivity rule. The existing private workflow's
monthly SMTP check remains separate; this direct database request does not
keep the SMTP key active. Supabase describes a few daily database requests as
usually sufficient to avoid pausing, rather than an uptime guarantee.
