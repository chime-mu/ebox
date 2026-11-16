defmodule Mix.Tasks.Ebox.Web do
  @shortdoc "Starts the local web app over your inboxes"

  @moduledoc """
  Starts the local web app (see `Ebox.Web`) on http://127.0.0.1:4100/:

      mix ebox.web ARCHIVE [--port N]
  """

  use Mix.Task

  @impl true
  def run(args) do
    {opts, rest} = OptionParser.parse!(args, strict: [port: :integer])
    archive = List.first(rest) || Mix.raise("usage: mix ebox.web ARCHIVE [--port N]")
    Ebox.CLI.start()
    {:ok, _} = Ebox.Web.start(archive: archive, port: opts[:port])
    Mix.shell().info("Ebox: #{Ebox.Web.url()}")
    Process.sleep(:infinity)
  end
end
