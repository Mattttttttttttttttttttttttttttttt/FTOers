#!/usr/bin/env python3
"""Validate private Brevo SMTP credentials and configure hosted Supabase Auth.
No deployments, migrations or email sends. Use --apply after the sender is verified.
"""
import argparse
import json
import os
from pathlib import Path
import smtplib
import ssl
import stat
import subprocess
import urllib.error
import urllib.request

REF = 'nwcngiivvlprzdfelyad'
ROOT = Path(__file__).resolve().parent.parent

def settings(path):
    info = path.stat()
    if info.st_uid != os.getuid() or stat.S_IMODE(info.st_mode) & 0o077:
        raise ValueError('The SMTP credentials file must belong to you and have permissions 600.')
    data = json.loads(path.read_text())
    for key in ['smtp_login', 'smtp_key', 'sender_email']:
        if not isinstance(data.get(key), str) or not data[key].strip():
            raise ValueError('Fill smtp_login, smtp_key and sender_email in the private SMTP file first.')
    if '@' not in data['smtp_login'] or '@' not in data['sender_email']:
        raise ValueError('SMTP login and sender email must be the addresses shown in Brevo.')
    if data['smtp_key'].startswith('xkeysib-'):
        raise ValueError('Use a Brevo SMTP key, not a Brevo API key.')
    return {key: value.strip() if isinstance(value, str) else value for key, value in data.items()}

def templates():
    values = {'mailer_subjects_confirmation': 'Confirm your FTOers account', 'mailer_subjects_recovery': 'Reset your FTOers password'}
    for kind in ['confirmation', 'recovery']:
        html = (ROOT / 'supabase/templates' / (kind + '.html')).read_text()
        if html.count('{{ .ConfirmationURL }}') != 1 or html.count('{{ .Token }}') != 1:
            raise ValueError('Each Auth template must contain exactly one ConfirmationURL link and one Token code.')
        values['mailer_templates_' + kind + '_content'] = html
    return values

def api(token, payload=None):
    request = urllib.request.Request('https://api.supabase.com/v1/projects/' + REF + '/config/auth',
        data=json.dumps(payload).encode() if payload is not None else None,
        headers={'Authorization': 'Bearer ' + token, 'Content-Type': 'application/json'},
        method='PATCH' if payload is not None else 'GET')
    try:
        with urllib.request.urlopen(request, timeout=40) as response:
            return json.load(response)
    except urllib.error.HTTPError as error:
        raise ValueError('Supabase Auth configuration returned HTTP ' + str(error.code) + '. Response omitted to protect secrets.') from None

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--file', type=Path, default=Path.home() / '.config/ftoers/smtp.json')
    parser.add_argument('--apply', action='store_true')
    args = parser.parse_args()
    data = settings(args.file)
    payload = templates()
    if not args.apply:
        print('Private SMTP fields and both Auth templates are valid. No remote changes or email sends.')
        return
    # Authenticate before changing Supabase; this opens TLS but sends no email.
    try:
        with smtplib.SMTP('smtp-relay.brevo.com', 587, timeout=25) as smtp:
            smtp.ehlo()
            smtp.starttls(context=ssl.create_default_context())
            smtp.ehlo()
            smtp.login(data['smtp_login'], data['smtp_key'])
    except (smtplib.SMTPException, OSError):
        raise ValueError('Brevo SMTP login/TLS verification failed. No Supabase settings changed.') from None
    token = os.environ.get('SUPABASE_ACCESS_TOKEN') or subprocess.check_output(
        ['secret-tool', 'lookup', 'service', 'Supabase CLI', 'username', 'supabase'], text=True).strip()
    if not token:
        raise ValueError('No Supabase CLI access token is available.')
    before = api(token)
    payload.update(smtp_host='smtp-relay.brevo.com', smtp_port='587', smtp_user=data['smtp_login'],
        smtp_pass=data['smtp_key'], smtp_admin_email=data['sender_email'], smtp_sender_name=data.get('sender_name') or 'FTOers',
        rate_limit_email_sent=30, smtp_max_frequency=60)
    result = api(token, payload)
    if any(str(result.get(key)) != str(payload[key]) for key in ['smtp_host', 'smtp_port', 'smtp_user', 'smtp_admin_email', 'smtp_sender_name']):
        raise ValueError('Supabase returned unexpected SMTP settings; inspect the dashboard before sending a test.')
    after = api(token)
    if before.get('mailer_autoconfirm') != after.get('mailer_autoconfirm') or before.get('uri_allow_list') != after.get('uri_allow_list'):
        raise ValueError('Unexpected change to confirmation or redirect settings; inspect the dashboard.')
    print('Brevo SMTP authenticated. FTOers sender and confirmation/recovery templates configured in Supabase.')
    print('No email sent. No website deployment or database migration performed.')

if __name__ == '__main__':
    try:
        main()
    except (ValueError, OSError, subprocess.SubprocessError):
        # Never print exception payloads or tracebacks that might contain credentials.
        import sys
        error = sys.exc_info()[1]
        print(str(error) if isinstance(error, ValueError) else 'SMTP setup could not complete. Check the private file, keyring and connection.')
        raise SystemExit(1)
