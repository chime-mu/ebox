defmodule Mix.Tasks.Ebox.Rules do
  @shortdoc "Learns routine-mail rules from how your letters are filed"

  @moduledoc """
  Learns rules for routine mail from the filed letters in the archive and
  stores them in `ARCHIVE/.ebox/rules.json` (see `Ebox.Rules`). Rules you made
  yourself are kept; learned ones are replaced.

      mix ebox.rules ARCHIVE
  """

  use Mix.Task

  @impl true
  def run(args) do
    archive = List.first(args) || Mix.raise("usage: mix ebox.rules ARCHIVE")
    {user, learned, stats} = Ebox.Rules.relearn(archive)

    Mix.shell().info(
      "#{learned} learned rule(s), #{user} of your own, in #{Ebox.Rules.path(archive)}\n" <>
        "Of #{stats.filed} filed letters, the rules match #{stats.covered} and put " <>
        "#{stats.right} where they are now."
    )
  end
end
