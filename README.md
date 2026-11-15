# Ebox

An Elixir connector for [e-Boks](https://www.e-boks.dk), the Danish digital
mailbox. It speaks the API of the official mobile app and is read-only: list
folders and messages, download documents and attachments.

This is unofficial and not affiliated with e-Boks. The protocol was learned from
[Net::Eboks](https://github.com/dk/Net-Eboks) by Dmitry Karasik (Perl, BSD
2-clause), which this is a fresh implementation of, not a port of its code.

## Requirements

- Elixir 1.18+ on Erlang/OTP 29.1 or newer (see [Erlang version](#erlang-version))
- A mobile-access password from e-boks.dk (*Menu → Mobiladgang*) and MitID

## One-time activation

e-Boks only accepts logins from devices whose public key is registered on your
account, and registering takes one MitID login:

    mix deps.get
    mix ebox.auth

The task generates a key pair and device id for this machine, prints a login
URL, and asks you to paste back the `eboksdk://ngdpoidc/callback?...` address
the browser is sent to after you approve in MitID (it shows up in the developer
tools' Network tab as the `Location` of the last request). It then registers the
public key and does a test login.

What is stored, in `~/.config/ebox/` with mode `0600`:

- `device_key.pem` – this machine's private key
- `device.json` – device id, your CPR number and name

The password is never stored. Tasks read it from `EBOX_PASSWORD` or prompt for
it. To revoke access, remove the "ebox-elixir" device under *Mobiladgang* on
e-boks.dk and delete the directory.

## Command line

    mix ebox.folders                 # folders in your mailbox
    mix ebox.folders --shares        # mailboxes shared with you
    mix ebox.messages                # messages in Inbox
    mix ebox.messages Arkiv --take 20
    mix ebox.download --to ~/Documents/e-boks

`mix ebox.download` skips documents that are already present, so it can run
from cron to keep a local copy up to date.

## As a library

```elixir
{:ok, box} = Ebox.connect(password: System.fetch_env!("EBOX_PASSWORD"))

{:ok, folders} = Ebox.folders(box)
inbox = Enum.find(folders, &(&1.name == "Inbox"))

{:ok, messages} = Ebox.messages(box, inbox.id, take: 20)

for message <- messages do
  {:ok, message} = Ebox.message(box, message)          # adds attachments
  {:ok, document} = Ebox.content(box, message)
  File.write!("#{message.id}.#{Ebox.Message.extension(message)}", document)

  for attachment <- message.attachments do
    {:ok, data} = Ebox.content(box, message, attachment)
    File.write!("#{attachment.id}.#{Ebox.Message.extension(attachment)}", data)
  end
end
```

`Ebox.connect/1` returns a process that owns the session and logs in again when
the session expires; `Ebox.start_link/1` is the same for a supervision tree.
Errors are `{:error, %Ebox.Error{}}` with the failing step, HTTP status and
e-Boks' own error code and text.

## Erlang version

`rest.e-boks.dk` asks for an optional TLS client certificate and lists the CA
names it accepts. One of those names is malformed (country `NOR`, where the
standard allows two letters), and Erlang/OTP before 29.1 aborts the handshake
on it with `handshake_decode_error`. OTP 29.1 skips names it cannot decode
([erlang/otp#11595](https://github.com/erlang/otp/issues/11595)). `mise.toml`
pins a working version for this project.

## Tests

    mix test

The tests run against `Ebox.FakeEboks`, an in-process stand-in built from what
the reference client sends and expects plus the error responses observed from
the real service.
