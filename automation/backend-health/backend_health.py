#!/usr/bin/env python3
"""FTOers scheduled database read and opt-in SMTP check. No server credentials needed for the read."""
import argparse
from datetime import datetime, timezone
from email.message import EmailMessage
from email.utils import formataddr, make_msgid
import json
import os
from pathlib import Path
import smtplib
import ssl
import time
import urllib.error
import urllib.request

CONFIG_PATH = Path(__file__).with_name('config.json')

def check_database(config, opener=urllib.request.urlopen, sleep=time.sleep):
    request = urllib.request.Request(config['supabase_url'] + '/rest/v1/rpc/leaderboard',
        data=b'{"kind":"single"}', method='POST',
        headers={'apikey': config['supabase_publishable_key'], 'Content-Type': 'application/json'})
    for attempt in range(3):
        try:
            with opener(request, timeout=20) as response:
                rows = json.load(response)
            if not isinstance(rows, list):
                raise ValueError('Unexpected database health response.')
            print('Supabase: public leaderboard database read succeeded.')
            return
        except (urllib.error.URLError, TimeoutError, ValueError):
            if attempt == 2:
                raise RuntimeError('Supabase database read failed after three attempts. Check the project dashboard.') from None
            sleep(2 ** attempt)

def send_email(config, env=os.environ, smtp_factory=smtplib.SMTP):
    login, key = env.get('SMTP_LOGIN', '').strip(), env.get('SMTP_KEY', '').strip()
    if not login or not key:
        raise ValueError('Set SMTP_LOGIN and SMTP_KEY as private runner secrets.')
    # Recipient is checked in and fixed to the owner. Environment inputs cannot
    # turn this scheduled task into a sender to other users.
    recipient, sender = config['recipient'], config['sender_email']
    message = EmailMessage()
    message['From'] = formataddr(('FTOers', sender))
    message['To'] = recipient
    message['Subject'] = 'FTOers monthly email check'
    message['Date'] = datetime.now(timezone.utc).strftime('%a, %d %b %Y %H:%M:%S +0000')
    message['Message-ID'] = make_msgid(domain='ftoers.web.app')
    message.set_content('This is the monthly email check you requested for FTOers.\n\nA successful send verifies the SMTP connection and keeps this Brevo SMTP key active. No action is needed.\n')
    message.add_alternative('<!doctype html><html><body style="font-family:Arial,sans-serif;color:#182231"><h2>FTOers</h2><p>This is the monthly email check you requested.</p><p>A successful send verifies the SMTP connection and keeps this Brevo SMTP key active.</p><p>No action is needed.</p></body></html>', subtype='html')
    # Do not automatically retry an SMTP send: an ambiguous timeout after DATA
    # could otherwise send a second copy. Failed Actions runs notify the owner.
    with smtp_factory('smtp-relay.brevo.com', 587, timeout=30) as smtp:
        smtp.ehlo()
        smtp.starttls(context=ssl.create_default_context())
        smtp.ehlo()
        smtp.login(login, key)
        refused = smtp.send_message(message, from_addr=sender, to_addrs=[recipient])
        if refused:
            raise RuntimeError('SMTP recipient was refused.')
    print('Brevo: the owner-only monthly check email was accepted by the SMTP server.')

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--send-email', action='store_true', help='Send the owner-only check instead of a database read.')
    args = parser.parse_args()
    config = json.loads(CONFIG_PATH.read_text())
    if args.send_email:
        send_email(config)
    else:
        check_database(config)

if __name__ == '__main__':
    try:
        main()
    except (RuntimeError, ValueError, OSError, smtplib.SMTPException):
        # SMTP server errors can contain addresses; keep credentials and raw
        # provider responses out of Actions logs.
        print('Backend check failed. Inspect the service dashboard; credentials and provider response are omitted.')
        raise SystemExit(1)
