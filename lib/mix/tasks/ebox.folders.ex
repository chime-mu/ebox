defmodule Mix.Tasks.Ebox.Folders do
  @shortdoc "Lists e-Boks folders and shared mailboxes"

  @moduledoc """
  Lists your folders, or those of a shared mailbox.

      mix ebox.folders [--share ID]
      mix ebox.folders --shares      # list shared mailboxes instead
  """

  use Mix.Task

  alias Ebox.CLI

  @impl true
  def run(args) do
    {opts, _} = OptionParser.parse!(args, strict: [share: :string, shares: :boolean])
    CLI.start()
    box = CLI.connect!()

    if opts[:shares] do
      for share <- CLI.ok!(Ebox.shares(box)), do: Mix.shell().info("#{share.id}\t#{share.name}")
    else
      for folder <- CLI.ok!(Ebox.folders(box, opts)) do
        indent = if folder.parent_id, do: "  ", else: ""
        Mix.shell().info("#{folder.id}\t#{indent}#{folder.name}")
      end
    end
  end
end
