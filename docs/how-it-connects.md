# How Ebox connects

This document explains how Ebox reaches Danish digital mail: which systems
exist, how one MitID login becomes unattended access to all of them, and which
requests it makes. It is written for anyone who wants to build on it, in
Elixir or another language. Everything here was observed against the
production services in 2026. None of it is an official, supported interface
except the Digital Post API itself, and any of it may change.

## 1. The landscape: two systems, two kinds of owner

Danes get digital mail in two separate systems, which the e-Boks app and
website show side by side:

| | Sent by | Run by | In the e-Boks app |
|---|---|---|---|
| **e-Boks** | private companies: banks, utilities, employers | e-Boks A/S | "Post fra virksomheder" |
| **Digital Post** (NgDP) | public authorities: Skat, municipalities, agencies | the state (Digitaliseringsstyrelsen) | "Post fra det offentlige" |

e-Boks, mit.dk and borger.dk are only *viewers* of Digital Post. The letters
live in the state's system, and all viewers show the same mailbox.

Both systems have mailboxes for **persons** (CPR number) and for
**companies** (CVR number). When you log in with MitID you choose which one you
act as ("profile"). So a person who runs a company has up to four mailboxes:

| | Digital Post | e-Boks |
|---|---|---|
| Person | the citizen mailbox | the private e-Boks |
| Company | the organisation mailbox | e-Boks Erhverv |

How Ebox reaches each:

- **Digital Post, person and company**: one Digital Post login as the person
  sees the person's mailbox and every organisation mailbox the person has been
  given access to (for example as owner or administrator).
- **e-Boks, person**: the person's e-Boks, through a device registered on
  that account.
- **e-Boks, company**: e-Boks Erhverv is a separate account, which a personal
  login cannot see. The company *shares* it with the person's CPR number
  (company profile on e-boks.dk: *Indstillinger → Adgange → Giv andre
  adgang*, rights "Administration"). Once the person accepts it, which
  happens on their next web login, it is a shared mailbox of the person's
  e-Boks and reachable like their own.

Historically, public mail used to arrive in e-Boks. When the new Digital Post
started (2022), public mail from about 2010 onwards was moved into Digital
Post with the folder structure. Older public letters may still be in e-Boks,
and company e-Boks accounts may still hold copies of public letters that are
also in Digital Post.

## 2. Activation: one MitID login, once

Everything hangs on one MitID login done through the e-Boks app's own login
flow. Ebox performs that flow itself (`Ebox.Auth`, `mix ebox.auth`):

```
 browser                    Ebox                          services
    │                        │
    │   1. authorize URL     │   OAuth 2 + PKCE, client "e-boks-mobile"
    │◄───────────────────────│   gateway.digitalpost.dk/auth/oauth/authorize
    │   MitID login ─────────┼──────────────────────────► NemLog-in / MitID
    │   redirect eboksdk://ngdpoidc/callback?code=…
    │──── pasted by user ───►│
    │                        │ 2. code → Digital Post tokens
    │                        │    POST digitalpost.dk/auth/oauth/token
    │                        │    (authorization_code, code_verifier)
    │                        │    → access token (20 min) + refresh token
    │                        │ 3. Digital Post token → e-Boks user token
    │                        │    POST digitalpostproxy.e-boks.dk/loginservice/v2/connect/usertoken
    │                        │ 4. user token → e-Boks token
    │                        │    POST oauth-dk.e-boks.com/1/connect/token
    │                        │    grant_type=usertoken, scope="mobileapi offline_access", deviceid
    │                        │ 5. with the e-Boks token (mobile-api-dk.e-boks.com/2):
    │                        │    POST user/mobileaccess/password/verify   (mobile password, once)
    │                        │    GET  user/profile                        (name, CPR)
    │                        │    PUT  user/current/device                 (device id + RSA public key)
```

Details worth knowing:

- The redirect URI `eboksdk://ngdpoidc/callback` is the app's custom scheme.
  A desktop browser cannot open it and stops there, which is why the user
  copies the address from the developer tools (the `Location` header of the
  last request). The code in it expires within minutes.
- The client ids and secrets are those of the e-Boks mobile app. They
  identify the app, not the user, and are the same for everybody; they are in
  `lib/ebox/auth.ex`.
- Step 3 is a POST without a body that must still carry `Content-Length: 0`.
  The server answers 411 otherwise.
- What is kept: the Digital Post tokens (`digitalpost.json`) and the device
  (`device.json`, `device_key.pem`). The mobile-access password is used once
  in step 5 and never stored.

## 3. Every day: no MitID, no password

```
digitalpost.json (refresh token)
   │  POST digitalpost.dk/auth/oauth/token  grant_type=refresh_token
   ▼
Digital Post access token (20 min) ──────────► gateway.digitalpost.dk/apis/v1   (Digital Post)
   │  usertoken + oauth (steps 3–4 above, with the device id)
   ▼
e-Boks token (300 s) ────────────────────────► mobile-api-dk.e-boks.com/2       (e-Boks)
```

- The Digital Post refresh token **does not rotate**: renewing returns a new
  access token and leaves the refresh token as it was. How long an unused
  refresh token survives is not known; it has been seen to survive at least
  eight hours unused.
  Running `mix ebox.digitalpost.renew` regularly keeps it in use.
- The e-Boks token lives 5 minutes. Ebox simply repeats steps 3–4 when it is
  about to expire. The response also carries an e-Boks refresh token, which
  Ebox does not use.
- So **one stored login gives access to every mailbox in section 1.** If it
  ever stops working, one MitID login (`mix ebox.digitalpost.auth`) restores
  it, and the device registration stays valid.

`Ebox.DigitalPost` and `Ebox.Eboks` are processes that hold these tokens and
renew them by themselves. `Ebox.Eboks` takes its Digital Post token from an
`Ebox.DigitalPost` connection (`DigitalPost.access_token/1`).

## 4. Digital Post API

Base: `https://gateway.digitalpost.dk/apis/v1`, with `Authorization: Bearer`
and the Digital Post access token. It is described in the Agency for Digital
Government's OpenAPI document
([test.digitalpost.dk/api/current/json](https://test.digitalpost.dk/api/current/json)).

| Request | Use |
|---|---|
| `GET /mailboxes/` | Mailboxes: `ownerType` `CITIZEN` or `ORGANISATION`, `ownerName` |
| `GET /mailboxes/{m}/folders/` | Folders: `folderType` (`INBOX`, `DRAFTS`, `SENT`, `DELETED`, `USER_DEFINED`), `parentFolderId` |
| `GET /mailboxes/{m}/messages/?page=0&size=100&sortFields=receivedDateTime:desc[&folderId=…]` | Messages, 0-based pages |
| `GET /mailboxes/{m}/messages/{id}` | One message, with its `version` |
| `GET /mailboxes/{m}/messages/{id}/documents/{d}/files/{f}/content` | A file (letter or attachment) |
| `PATCH /mailboxes/{m}/messages/{id}` | Change `read`, `folderId` (move), `flag`, `note`; needs `If-Match: <version>` |

- A message holds documents (the letter, then attachments), each with files.
  Useful fields: `label` (title), `sender.label`, `receivedDateTime`, `read`,
  `replyByDateTime` (reply deadline), `legallyNotified`. Messages you sent
  yourself have no `receivedDateTime`; use `createdDateTime`.
- **Reading has no side effects.** Listing, fetching and downloading leave
  messages unread and do not set `legallyNotified`.
- `PATCH` was verified for `read` and `folderId`. Every change increments
  `version` (also sent as the `ETag`). `Ebox.DigitalPost.update/4` fetches
  the current version and sends it as `If-Match`.
- Bulk downloads are rate-limited with HTTP 429. Ebox backs off and retries.

## 5. e-Boks API

Base: `https://mobile-api-dk.e-boks.com/2`, with `Authorization: Bearer` and
the e-Boks token. This is the JSON API the current e-Boks app uses. It is not
documented; the routes below come from the app (section 7) and were each
tried against production.

| Request | Use |
|---|---|
| `GET user/profile` | Your `name` and CPR (`identity`) |
| `GET mail/shares` | Mailboxes shared with you: `userId`, `name`, `permission`, `status` (`Accepted`…) |
| `GET mail/folders` | Folders, nested: `id`, `name`, `type` (`inbox`, `drafts`, `sentitems`, `deleteditems`, `folder`), `folders` (children), `parent` |
| `GET mail/folders/{f}/messages?offset=0&limit=100` | Messages: `items[]` and `metadata.total` |
| `GET mail/folders/{f}/messages/{id}` | One message, with `attachments[]` |
| `GET mail/folders/{f}/messages/{id}/content` | The letter |
| `GET mail/folders/{f}/messages/{id}/attachment/{a}/content` | An attachment |
| `POST mail/folders/{f}/messages/{id}` | Change it, JSON body (`MessagePatch`): `unread`, `folderId` (move), `flag`, `note`, `archive`. Answers 204 |

- **Shared mailboxes**: add `?userId=<share userId>` to any `mail/...`
  request, including writes. Without it, requests go to your own mailbox.
- Message fields: `subject`, `sender.name`, `received`, `unread`,
  `numberOfAttachments`, `content` (`fileExtension`, `fileSize`, `mimeType`).
  Attachments have the same shape.
- **Downloading content marks the message read**; listing and fetching the
  message details do not. `POST … {"unread": true}` changes it back. Ebox's
  archive does exactly that for letters that were unread.
- Moving to the inbox works through the API, although the website's move menu
  does not offer it.
- The app also has `POST mail/folders` (`name`, `parentFolderId`, `userId`),
  `PATCH` and `DELETE mail/folders/{id}`, and
  `DELETE mail/folders/{f}/messages/{id}`. These were not tried.

## 6. The e-Boks website

e-boks.dk (`/privat/` and, for companies, `/erhverv/`) uses its own API
(`/privat/api_eb/...`) with a session from a MitID login, so it cannot run
unattended. It shows the same data, though, and was useful for checking:
`POST api_eb/documents/move` and `POST api_eb/documents/property/readstatus`
do what the mobile API's `POST mail/folders/{f}/messages/{id}` does. Its folder
ids are base64 of `userId¤share¤folderId¤`, the same numbers the mobile API
uses. Its "Post fra det offentlige" tab is Digital Post through
`digitalpostproxy.e-boks.dk`.

## 7. How this was found

- **Digital Post**: from its published OpenAPI document, and by trying it.
- **The login flow**: from the e-Boks app's behaviour and from
  [Net::Eboks](https://github.com/dk/Net-Eboks), which documented an older
  login for the same app.
- **The e-Boks JSON API**: the Android app (`com.eboks.activities`) declares
  its API with Retrofit annotations, which are readable as data in the app's
  `.dex` files without running any of its code. That gave every route with its
  HTTP method and parameters (for example `@POST("mail/folders/{folderId}/messages/{messageId}")`
  with a `MessagePatch` body). Each one was then tried on a single old letter,
  and the letter was put back afterwards.
- **The website**: by watching its requests in a browser while moving a
  letter and marking it unread.

Dead ends, so nobody has to try them again:

- `rest.e-boks.dk/mobile/1/xml.svc` (the older XML API of the app) works, but
  needs the mobile-access password at every login and has no write calls in
  any known client. Ebox used it at first and dropped it.
- `gateway.mit.dk/view/client` (used by older mit.dk clients) is gone (503).
- `post.mit.dk/internal-api` is a cookie session that expires about 30 minutes
  after a MitID login, and opening a message there marks it read.

## 8. Being a good citizen

- This is your own mail, read with the same login and the same requests as
  the official app. Ebox does not do anything the app cannot.
- Keep request rates modest. Digital Post rate-limits bulk downloads (429),
  and Ebox backs off.
- The stored login is as powerful as your mailbox. Keep `~/.config/ebox/`
  private, and remove the device under *Mobiladgang* on e-boks.dk when you no
  longer use it.
