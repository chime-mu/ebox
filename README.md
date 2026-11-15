# Ebox

Your Danish digital mail on your own machine. Ebox reads both systems Danes get
mail in, for you and for companies you represent, and keeps a local archive
laid out like the e-Boks app:

- **e-Boks**, "Post fra virksomheder": banks, utilities, employers, insurers…
- **Digital Post**, "Post fra det offentlige": Skat, your municipality and
  other public authorities, which e-Boks, mit.dk and borger.dk only display.

After a one-time activation with MitID it runs unattended: no MitID and no
password, so it can run from cron or launchd.

It is written in Elixir and can be used from the command line or as a library.
It is unofficial and not affiliated with e-Boks A/S or the Agency for Digital
Government. [How it connects](docs/how-it-connects.md) explains every request
it makes and how they were found.

## What you get

```
~/Mail/
  Your Name/
    Post fra virksomheder/
      Indbakke/
      Bank/
        Kontoudskrift/
          2025-05-04 Bank A_S - Kontoudskrift nr. 5 [ID].pdf
          2025-05-04 Bank A_S - Kontoudskrift nr. 5 [ID].json
      …every folder you have, also empty ones
    Post fra det offentlige/
      Skat/
        2025-03-14 Skattestyrelsen - Årsopgørelse 2024 [ID].pdf
        2025-03-14 Skattestyrelsen - Årsopgørelse 2024 [ID] - bilag.pdf
        2025-03-14 Skattestyrelsen - Årsopgørelse 2024 [ID].json
  Company ApS/
    Post fra virksomheder/   (if the company's e-Boks is shared with you)
    Post fra det offentlige/ (if you represent the company in Digital Post)
```

Each letter is stored as its files (the letter, then attachments) next to a
`.json` holding what the service knows about it: sender, dates, reply
deadline, read state, the folder it came from and the size of every file.

Reading your mail with Ebox does not change it. Digital Post is read without
side effects. e-Boks marks a letter read when it is downloaded, so Ebox marks
letters that were unread as unread again right afterwards.

## Quick start

You need Elixir 1.18 or newer, MitID, and the mobile-access password from
e-boks.dk (*Menu → Mobiladgang*; you need it once).

    git clone https://github.com/chime-mu/ebox.git && cd ebox
    mix deps.get
    mix ebox.auth                       # one time: MitID in a browser, see below
    mix ebox.archive ~/Mail             # download everything
    mix ebox.verify ~/Mail              # check the archive against the services

`mix ebox.archive` skips what it already has, so run it as often as you like.
`--skip-inbox` leaves out the inboxes.

### Activation (`mix ebox.auth`)

The task prints a login address. Open it in a browser with the developer
tools' Network tab open ("Preserve log" on) and log in with MitID. The login
ends with a redirect to an address starting with `eboksdk://ngdpoidc/callback`,
which only the e-Boks app can open, so the browser stops there. Copy that
address (the `Location` of the last request) and paste it into the terminal.
The code in it is short-lived, so be quick. The task then registers this
machine as a device on your e-Boks account and stores the login.

## Commands

| Command | What it does |
|---|---|
| `mix ebox.auth` | One-time activation with MitID (registers this machine) |
| `mix ebox.archive DIR [--skip-inbox] [--only e-boks\|digitalpost]` | Downloads all mailboxes into `DIR` |
| `mix ebox.verify DIR [--skip-inbox] [--only …]` | Checks every message, file, size and folder; exits non-zero on problems |
| `mix ebox.folders [--only …]` | Lists your mailboxes and folders in both systems |
| `mix ebox.messages [FOLDER] [--mailbox NAME] [--take N]` | Lists e-Boks messages in a folder (default: inbox) |
| `mix ebox.digitalpost.messages [--mailbox N]` | Lists Digital Post inboxes |
| `mix ebox.digitalpost.renew` | Renews the stored login without reading mail |
| `mix ebox.digitalpost.auth` | Logs in to Digital Post again with MitID, keeping the device |

## Company mail

A company has mail in both systems, just like a person:

- **Digital Post**: if you represent the company (for example as owner), its
  mailbox shows up next to yours automatically.
- **e-Boks** (e-Boks Erhverv): log in to e-boks.dk with MitID choosing the
  company profile, go to *Indstillinger → Adgange → Giv andre adgang*, and give
  your own CPR number access, with "Administration" rights. Then log in once to
  your private e-Boks on the web, where the share is accepted. From then on
  the company's mailbox is listed next to yours.

## As a library

```elixir
{:ok, dp} = Ebox.DigitalPost.connect()            # renews the stored login
{:ok, eb} = Ebox.Eboks.connect(digitalpost: dp)   # e-Boks token from the same login

# e-Boks: your mailbox first, then mailboxes shared with you
[mine | _shared] = Ebox.Eboks.mailboxes(eb)
{:ok, folders} = Ebox.Eboks.folders(eb, mine)
inbox = Enum.find(folders, &(&1.type == "inbox"))
{:ok, messages} = Ebox.Eboks.all_messages(eb, mine, inbox.id)

for message <- messages do
  {:ok, message} = Ebox.Eboks.message(eb, mine, message)     # adds attachments
  for file <- message.files do
    {:ok, data} = Ebox.Eboks.content(eb, mine, message, file) # marks it read…
    File.write!("#{message.id}-#{file.id}.#{Ebox.Eboks.Message.extension(file)}", data)
  end
  if message.unread, do: Ebox.Eboks.update(eb, mine, message, %{unread: true}) # …so undo that
end

# Digital Post: your mailbox first, then companies you represent
[citizen | _orgs] = Ebox.DigitalPost.mailboxes(dp)
{:ok, letters} = Ebox.DigitalPost.all_messages(dp, citizen.id)
{:ok, pdf} = Ebox.DigitalPost.content(dp, hd(letters), hd(hd(letters).files))

# Or all of it at once, as on the command line
conns = %{digitalpost: dp, eboks: eb}
{:ok, parts} = Ebox.Archive.plan(conns, "/path/to/Mail")
Ebox.Archive.download(conns, parts)
```

Errors are `{:error, %Ebox.Error{}}` with the failing step, the HTTP status and
the service's own message. Connections renew their tokens by themselves.

## What is stored, and how to revoke it

In `~/.config/ebox/` (or `$EBOX_HOME`), directory mode `0700`, files `0600`:

- `device_key.pem`, `device.json`: this machine's device key and id, your CPR
  number and name.
- `digitalpost.json`: the Digital Post login (a refresh token). **Whoever has
  this file and the device files can read your mail in both systems.** Treat
  the directory like a password.

The mobile-access password is never stored. To revoke access, remove the
"ebox-elixir" device under *Mobiladgang* on e-boks.dk and delete the directory.

The login renews itself as long as it is used. How long an unused login
survives is not known; if `mix ebox.digitalpost.renew` ever fails, run
`mix ebox.digitalpost.auth` (MitID) again.

## Tests

    mix test

The tests run against in-process fakes of the services (`test/support/`),
shaped after the published Digital Post API description, the routes in the
e-Boks app and responses observed from production. They never touch the
network.

## Credits

The original e-Boks login and mail protocol were learned from
[Net::Eboks](https://github.com/dk/Net-Eboks) by Dmitry Karasik. Digital Post is
read through the Agency for Digital Government's documented API.
