defmodule Mix.Tasks.Ebox.Digitalpost.Auth do
  @shortdoc "Logs in to Digital Post (mail from public authorities) with MitID"

  @moduledoc """
  Stores a fresh Digital Post login without registering an e-Boks device.
  `mix ebox.auth` already does this as part of activation; use this task when
  the Digital Post login has expired.

      mix ebox.digitalpost.auth

  It prints a login URL; open it in a browser with the developer tools'
  Network tab open, approve with MitID, and paste the final
  `eboksdk://ngdpoidc/callback?...` URL back here.
  """

  use Mix.Task

  alias Ebox.{Auth, CLI, Device, DigitalPost}

  @impl true
  def run(_args) do
    CLI.start()
    device = with({:ok, device} <- Device.load(), do: device, else: (_ -> Device.generate()))
    auth = Auth.start(device)

    Mix.shell().info("""

    Open this address in a browser with the developer tools' Network tab open
    (tick "Preserve log") and log in with MitID:

    #{auth.url}

    After you approve, the browser stops at an address starting with
    eboksdk://ngdpoidc/callback (the Location of the last request). Copy it and
    paste it here promptly; the code in it is short-lived.
    """)

    callback = "Paste the eboksdk:// address: " |> IO.gets() |> to_string()

    with {:error, error} <- DigitalPost.authorize(auth, callback),
         do: Mix.raise(Exception.message(error))

    dp = CLI.ok!(DigitalPost.connect())

    names =
      Enum.map_join(DigitalPost.mailboxes(dp), ", ", &"#{&1.owner_name || &1.owner_type}")

    Mix.shell().info("Logged in to Digital Post. Mailboxes: #{names}")
  end
end
