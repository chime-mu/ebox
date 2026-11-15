defmodule Mix.Tasks.Ebox.Archive do
  @shortdoc "Downloads all your mail into a local archive laid out like the e-Boks app"

  @moduledoc """
  Downloads every mailbox you can read, from e-Boks and from Digital Post, into
  one archive laid out like the e-Boks app (see `Ebox.Archive`):

      mix ebox.archive ARCHIVE [--skip-inbox] [--only e-boks|digitalpost]

      ARCHIVE/Your Name/Post fra virksomheder/Bank/Kontoudskrift/...
      ARCHIVE/Your Name/Post fra det offentlige/Skat/...
      ARCHIVE/Company ApS/...

  Every folder is created, also empty ones. Messages already archived are
  skipped, so the task can run repeatedly. `--skip-inbox` leaves out the
  inboxes. Read state is left as it was. Needs only the stored login of
  `mix ebox.auth`; no password.
  """

  use Mix.Task

  alias Ebox.{Archive, CLI}

  @impl true
  def run(args) do
    {opts, rest} = OptionParser.parse!(args, strict: [skip_inbox: :boolean, only: :string])
    archive = List.first(rest) || Mix.raise("usage: mix ebox.archive ARCHIVE [--skip-inbox]")
    CLI.start()
    conns = CLI.connect_sources!(opts[:only])
    parts = CLI.ok!(Archive.plan(conns, archive, opts))

    totals =
      Archive.download(conns, parts, fn part, stats ->
        Mix.shell().info(
          "#{part.label} / #{Archive.system_dir(part.source)}: " <>
            "#{stats.new} new of #{stats.messages} message(s) in #{length(part.dirs)} folder(s)" <>
            if(stats.unread_restored > 0, do: ", #{stats.unread_restored} kept unread", else: "")
        )
      end)

    Mix.shell().info("#{totals.new} new message(s) in #{archive}")
  end
end
