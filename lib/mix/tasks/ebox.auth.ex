defmodule Mix.Tasks.Ebox.Auth do
  @shortdoc "Activates this machine as an e-Boks device using MitID (one time)"

  @moduledoc """
  Registers this machine as a device on your e-Boks account.

      mix ebox.auth

  You need the mobile-access password from e-boks.dk (*Menu → Mobiladgang*) and
  your MitID. The task prints a login URL; open it in a browser with the
  developer tools' Network tab open, approve with MitID, and paste the final
  `eboksdk://ngdpoidc/callback?...` URL back here.

  A new key pair and device id are generated on first run and stored in
  `#{Ebox.Device.dir()}`. Pass `--new-device` to discard an existing one.
  """

  use Mix.Task

  alias Ebox.{Auth, CLI, Device}

  @impl true
  def run(args) do
    {opts, _} = OptionParser.parse!(args, strict: [new_device: :boolean])
    CLI.start()

    device =
      with false <- opts[:new_device] == true, {:ok, device} <- Device.load() do
        device
      else
        _ -> Device.generate()
      end

    password = CLI.password()
    auth = Auth.start(device)

    Mix.shell().info("""

    1. Open a browser window, open its developer tools (F12) and select the
       Network tab. Tick "Preserve log" / "Persist logs".
    2. Go to this address and log in with MitID:

    #{auth.url}

    3. After you approve, the page tries to jump to an address starting with
       eboksdk://ngdpoidc/callback and the browser stops there. Find that
       address — it is the Location header of the last request ("ssoack"), and
       some browsers also show it in the address bar or console — and copy it.
       The code in it is short-lived, so paste it promptly.
    """)

    code =
      "Paste the eboksdk:// address: "
      |> IO.gets()
      |> to_string()
      |> then(&Auth.parse_callback(auth, &1))
      |> CLI.ok!()

    device = CLI.ok!(Auth.activate(auth, code, device, password))
    Device.save(device)
    Mix.shell().info("Device #{device.id} registered for #{device.name || "your account"}.")

    case Ebox.connect(password: password, device: device) do
      {:ok, box} ->
        Device.save(Ebox.whoami(box).device)
        folders = CLI.ok!(Ebox.folders(box))
        Mix.shell().info("Login works. Folders: " <> Enum.map_join(folders, ", ", & &1.name))

      {:error, error} ->
        Mix.raise(
          "Device was registered, but the test login failed: " <> Exception.message(error)
        )
    end
  end
end
