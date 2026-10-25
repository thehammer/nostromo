# Google accounts for Fred (Gmail + Google Calendar)

Fred shows one inbox and one Today list. By default both come from a single
Microsoft 365 account through Microsoft Graph. You can add personal Google
accounts (consumer `@gmail.com`) as well. Fred reads mail and calendar from
every configured account and merges them into the same inbox and the same
Today list. There are no per-account sections.

Access is read-only. Nostromo asks Google for `gmail.readonly` and
`calendar.readonly` and never sends, archives, labels or marks anything, and
never RSVPs.

You do this setup once. It takes about 15 minutes.

> **No `[[fred_accounts]]` in `config.toml` means nothing changes.** Fred then
> behaves exactly as before: Microsoft only, through the existing
> `graph_client_id` settings.

## 1. Create a Google Cloud project

Go to <https://console.cloud.google.com/> and create a project, for example
`nostromo-personal`. It costs nothing: Gmail and Calendar reads at this
volume are free.

## 2. Enable the two APIs

In the project, go to **APIs & Services → Library**, then enable:

- **Gmail API**
- **Google Calendar API**

## 3. Configure the OAuth consent screen

Go to **Google Auth Platform** and fill in these pages:

- **Branding:** app name `Nostromo`, with your own email as the user support
  email and the developer contact.
- **Audience:** user type **External**. Add both Gmail addresses as **test
  users**, then click **Publish app** so the publishing status reads
  **In production**.
- **Data access:** add these two scopes:
  - `https://www.googleapis.com/auth/gmail.readonly`
  - `https://www.googleapis.com/auth/calendar.readonly`

**Do not submit the app for verification.** It is only for you:

- If you leave the app in **Testing**, Google expires its refresh tokens after
  7 days, and you would have to sign in again every week.
- When the app is **In production** but unverified, Google shows a "Google
  hasn't verified this app" screen when you sign in. Click **Advanced → Go to
  Nostromo (unsafe)**. This is expected for a personal app. The 100-user cap
  on unverified apps doesn't matter here.

`gmail.readonly` is a *restricted* scope. If Google ever blocks the unverified
production app, switch it back to **Testing** and accept the weekly re-sign-in.
No code change is needed either way.

## 4. Create the OAuth client

Go to **Google Auth Platform → Clients → Create client**, choose application
type **Desktop app**, and then **Download JSON**. Save the file as:

```
~/Library/Application Support/nostromo/google-oauth-client.json
```

Then restrict its permissions:

```sh
chmod 600 ~/Library/Application\ Support/nostromo/google-oauth-client.json
```

The file holds the client secret, so keep it out of `config.toml` and out of
git. It must be a **Desktop app** client. A "Web application" client is
rejected with "use a Desktop app client". Both Google accounts share this one
client.

## 5. Edit `config.toml`

The file is `~/Library/Application Support/nostromo/config.toml` on macOS.
Add one `[[fred_accounts]]` table per account:

```toml
# Optional; this is the default location on macOS.
# google_oauth_client = "~/Library/Application Support/nostromo/google-oauth-client.json"

[[fred_accounts]]
label = "personal"
provider = "google"
email = "me@gmail.com"      # optional: sign-in must match; used as a login hint

[[fred_accounts]]
label = "family"
provider = "google"

# Optional: keep Microsoft 365 in the merged view too (uses graph_client_id etc.)
# [[fred_accounts]]
# label = "work"
# provider = "microsoft"
```

The fields are:

- **`label`** (required): lower-case letters, digits, `-` and `_`, up to 32
  characters, starting with a letter or digit, and unique. Each item's id
  starts with it, and each item and event carries it in an `account` field.
- **`provider`** (required): `"google"` or `"microsoft"`. At most one
  `microsoft` entry is allowed, and it uses the existing `graph_client_id`,
  `graph_tenant` and `graph_token_cache` settings.
- **`email`** (optional, Google only): the address this account must sign in
  as. Google pre-selects it on the sign-in page, and a sign-in as any other
  address is rejected. **Set it.** With two Google accounts in one browser, it
  is easy to approve the wrong one.
- **`token_cache`** (optional, Google only): where the account's token is
  kept. The default is `~/.cache/nostromo/google-<label>-token.json`.

A bad entry never stops the daemon. `nostromd` skips that entry and logs a
warning that names the entry's index and the problem.

Then restart `nostromd`:

```sh
launchctl kickstart -k "gui/$(id -u)/com.hammer.nostromd"
```

## 6. Sign in each account

Until an account is signed in, Fred's panes show a sign-in prompt for it.
Choose one of these:

- **(a) From the Mac app.** In the Fred pane, click **Open Google sign-in**.
  This only works on the Mac running `nostromd` (the Mac Mini), because Google
  redirects back to `127.0.0.1` on that machine. The iPhone app only tells you
  to go to the Mac.
- **(b) From a terminal on the Mac Mini.** `make install` installs the CLI:

  ```sh
  nostromo-google-auth --account personal
  ```

  This opens the browser. Add `--no-browser` to print the URL instead, and
  `--config <path>` to read a different config file. When it finishes, it
  prints `Signed in personal as <email>`. The daemon picks the new token up
  from disk on its next poll, so you don't need to restart it.

Then repeat for the second account (`--account family`). In the browser, make
sure you pick the matching Google account. If you set `email` and pick the
wrong one, Nostromo rejects the sign-in and saves nothing.

The sign-in link expires after 10 minutes, and a fresh one appears on Fred's
next poll.

## 7. When you'll need to sign in again

Google revokes the token, and Fred shows the sign-in prompt again, when:

- you change the Google account's password;
- you remove Nostromo's access at <https://myaccount.google.com/permissions>;
- the token goes unused for 6 months;
- the app is in **Testing** status, which happens every 7 days (see step 3).

## 8. Token files

Each Google account's token is kept in its own file, by default
`~/.cache/nostromo/google-<label>-token.json`. The file has mode `0600`, and
its directory has mode `0700`. Delete the file to force that account to sign
in again.

## Notes

- **The unread count is in threads.** For Gmail accounts, Fred counts unread
  *conversations* in the inbox, which is the number Gmail itself shows. It can
  be lower than the number of unread rows in the list.
- **The calendar is re-read on every poll.** Fred reads today's events from
  each account's primary calendar every 30 seconds, the same way it reads the
  Microsoft calendar. Other calendars are not included.
- **A meeting you're invited to on both accounts appears once**, from the
  account listed first in `config.toml`.
- **If one account fails, the other keeps working.** Fred keeps showing the
  healthy account's mail and events, marks the view stale, and puts the
  failing account's label at the start of the error message.
