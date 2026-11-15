defmodule Mix.Tasks.Ebox.Verify do
  @shortdoc "Checks a local mail archive against e-Boks and Digital Post"

  @moduledoc """
  Checks that an archive written by `mix ebox.archive` holds everything the
  services have.

      mix ebox.verify ARCHIVE [--skip-inbox] [--only e-boks|digitalpost]

  Pass `--skip-inbox` if the archive was made with it. For every message the
  services list, it checks that its `.json` and every file are there, not
  empty and of the size the service reports, that `.pdf` files are PDFs, and
  that every folder exists. It notes read state changed since archiving and
  local messages a service no longer lists in that folder. Messages are only
  listed, never opened, so read state is untouched. Exits with an error when a
  problem is found.
  """

  use Mix.Task

  alias Ebox.{Archive, CLI}

  @impl true
  def run(args) do
    {opts, rest} = OptionParser.parse!(args, strict: [skip_inbox: :boolean, only: :string])
    archive = List.first(rest) || Mix.raise("usage: mix ebox.verify ARCHIVE [--skip-inbox]")
    CLI.start()
    conns = CLI.connect_sources!(opts[:only])
    results = Archive.verify(CLI.ok!(Archive.plan(conns, archive, opts)))

    for r <- results do
      for {kind, list} <- [problem: r.problems, note: r.notes], {text, path} <- list do
        Mix.shell().info("  #{kind}: #{text}: #{Path.relative_to(path, archive)}")
      end

      Mix.shell().info(
        "#{r.part.label} / #{Archive.system_dir(r.part.source)}: #{r.messages} message(s), " <>
          "#{r.files} file(s), #{length(r.part.dirs)} folder(s); " <>
          "#{length(r.problems)} problem(s), #{length(r.notes)} note(s)"
      )
    end

    problems = results |> Enum.map(&length(&1.problems)) |> Enum.sum()
    if problems > 0, do: Mix.raise("#{problems} problem(s) in #{archive}")
  end
end
