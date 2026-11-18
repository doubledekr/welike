#!/usr/bin/env python3
"""Builds the Supabase auth emails in emails/ from one layout.
Each file is pasted into Supabase: Authentication > Emails > Templates (subject listed in emails/README.md).
Run: python3 scripts/make_emails.py"""
import pathlib

ROOT = pathlib.Path(__file__).resolve().parent.parent / 'emails'
SANS = "Inter,-apple-system,BlinkMacSystemFont,'Segoe UI',Helvetica,Arial,sans-serif"


def page(title, preheader, heading, lead, middle, fine):
    return f'''<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="color-scheme" content="dark">
<meta name="supported-color-schemes" content="dark">
<title>{title}</title>
<link href="https://fonts.googleapis.com/css2?family=Instrument+Serif&family=Inter:wght@400;700&display=swap" rel="stylesheet">
</head>
<body style="margin:0;padding:0;background-color:#100d12;">
<div style="display:none;max-height:0;overflow:hidden;opacity:0;">{preheader}</div>
<table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0" bgcolor="#100d12" style="background-color:#100d12;">
<tr><td align="center" style="padding:40px 16px;">
<table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0" style="max-width:440px;">
<tr><td align="center" style="padding:0 0 18px;">
<img src="https://letstogether.app/email-logo.gif" width="300" height="214" alt="Let’s Together" style="display:block;border:0;width:300px;max-width:100%;height:auto;">
</td></tr>
<tr><td align="center" bgcolor="#1b1620" style="background-color:#1b1620;border-radius:24px;padding:36px 28px 32px;">
<p style="margin:0 0 6px;font-family:'Instrument Serif',Georgia,'Times New Roman',serif;font-size:34px;line-height:1.15;color:#ffffff;">{heading}</p>
<p style="margin:0 0 26px;font-family:{SANS};font-size:15px;line-height:1.5;color:#c9bec6;">{lead}</p>
{middle}
<p style="margin:24px 0 0;font-family:{SANS};font-size:13.5px;line-height:1.5;color:#9a8f97;">{fine}</p>
</td></tr>
<tr><td align="center" style="padding:22px 0 0;font-family:{SANS};font-size:12px;color:#7d727a;">letstogether.app</td></tr>
</table>
</td></tr>
</table>
</body>
</html>
'''


CODE = '''<table role="presentation" cellpadding="0" cellspacing="0" border="0" align="center">
<tr><td align="center" bgcolor="#2a1d26" style="background-color:#2a1d26;border-radius:16px;padding:16px 16px 16px 26px;">
<span style="font-family:'SF Mono',Menlo,Consolas,'Courier New',monospace;font-size:34px;font-weight:700;letter-spacing:10px;color:#ffb08a;">{{ .Token }}</span>
</td></tr>
</table>'''


def button(label):
    return f'''<table role="presentation" cellpadding="0" cellspacing="0" border="0" align="center">
<tr><td align="center" bgcolor="#ff5a6e" style="background-color:#ff5a6e;border-radius:14px;">
<a href="{{{{ .ConfirmationURL }}}}" style="display:inline-block;padding:15px 30px;font-family:{SANS};font-size:16px;font-weight:700;color:#ffffff;text-decoration:none;">{label}</a>
</td></tr>
</table>'''


def notice():
    return ''


IGNORE = 'If you didn’t ask for this, you can ignore this email. Nobody can sign in without the code.'
WORRY = 'If this wasn’t you, tell us at letstogether.app/hello and we’ll help you secure your account.'

E = {
    # Codes: what the app actually uses
    'sign-in-code': ('Your Let’s Together code', 'Your sign-in code is {{ .Token }}. It works for 10 minutes.',
                     'Your sign-in code', 'Type this into Let’s Together to sign in.', CODE,
                     'It works for 10 minutes. ' + IGNORE),
    'confirm-sign-up': ('Your Let’s Together code', 'Your code is {{ .Token }}. It works for 10 minutes.',
                        'Welcome to Let’s Together', 'Type this code into the app to save your account.', CODE,
                        'It works for 10 minutes. ' + IGNORE),
    'change-email': ('Confirm your new email', 'Your code is {{ .Token }}.',
                     'Confirm your new email', 'Type this code into Let’s Together to switch your account to this address.', CODE,
                     'If you didn’t ask to change your email, ignore this and nothing will change.'),
    'reauthentication': ('Your Let’s Together code', 'Your code is {{ .Token }}.',
                         'Is this you?', 'Type this code into Let’s Together to confirm it’s you.', CODE,
                         IGNORE),
    # Links: not used by the app today, set so nothing ever goes out unbranded
    'invite-user': ('You’re invited to Let’s Together', 'Someone saved you a spot on Let’s Together.',
                    'You’re invited', 'Let’s Together is a swipe app for deciding what to do together. Tap below to join.', button('Join Let’s Together'),
                    'If you weren’t expecting this, you can ignore it.'),
    'reset-password': ('Sign back in to Let’s Together', 'Tap to sign back in.',
                       'Sign back in', 'Tap below to get back into your account.', button('Sign in'),
                       'If you didn’t ask for this, you can ignore this email.'),
    # Security notices
    'notice-email-changed': ('Your Let’s Together email changed', 'The email on your account was changed.',
                             'Your email was changed', 'The email address on your Let’s Together account was just changed.', notice(), WORRY),
    'notice-signin-linked': ('A sign-in was added to your account', 'A new way to sign in was added.',
                             'New sign-in added', 'Apple or Google sign-in was just added to your Let’s Together account.', notice(), WORRY),
    'notice-signin-removed': ('A sign-in was removed from your account', 'A way to sign in was removed.',
                              'Sign-in removed', 'A way to sign in was just removed from your Let’s Together account.', notice(), WORRY),
}

if __name__ == '__main__':
    ROOT.mkdir(exist_ok=True)
    for name, (subject, pre, h, lead, mid, fine) in E.items():
        (ROOT / f'{name}.html').write_text(page(subject, pre, h, lead, mid, fine))
    print('wrote', len(E), 'emails')
