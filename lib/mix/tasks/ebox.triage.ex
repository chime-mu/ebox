defmodule Mix.Tasks.Ebox.Triage do
  @shortdoc "Evaluates new inbox mail with Claude and files routine mail"

  @moduledoc """
  Works through the inboxes of the archive (see `Ebox.Triage`):

      mix ebox.triage ARCHIVE [--evaluate] [--limit N] [--file-routine]

  Without options it only reports what is there. `--evaluate` lets Claude
  evaluate letters that need judging and have no evaluation yet (`claude -p`,
  model `$EBOX_CLAUDE_MODEL`, default sonnet). `--file-routine` files every
  letter that matches a rule, in the service and locally.
  """

  use Mix.Task

  alias Ebox.{CLI, Evaluate, Triage}

  @impl true
  def run(args) do
    {opts, rest} =
      OptionParser.parse!(args,
        strict: [evaluate: :boolean, limit: :integer, file_routine: :boolean]
      )

    archive =
      List.first(rest) ||
        Mix.raise("usage: mix ebox.triage ARCHIVE [--evaluate] [--file-routine]")

    CLI.start()

    if opts[:file_routine] do
      conns = CLI.connect_sources!()

      for {letter, result} <- Triage.file_routine(archive, conns) do
        case result do
          :ok -> :ok
          {:error, e} -> Mix.shell().error("#{letter.title}: #{Exception.message(e)}")
        end
      end
    end

    if opts[:evaluate] do
      Triage.evaluate_pending(archive, [limit: opts[:limit]], fn letter, result ->
        case result do
          {:ok, l} ->
            Mix.shell().info("P#{Evaluate.priority(l)} #{l.sender}: #{l.title}")

          {:error, e} ->
            text = if is_exception(e), do: Exception.message(e), else: inspect(e)
            Mix.shell().error("#{letter && letter.title}: #{text}")
        end
      end)
    end

    o = Triage.overview(archive)

    counts =
      Enum.frequencies_by(
        o.judge -- Enum.reject(o.judge, &Ebox.Letter.evaluation/1),
        &Evaluate.priority/1
      )

    Mix.shell().info(
      "Inboxes: #{length(o.routine)} routine, #{length(o.judge)} to judge " <>
        "(#{o.unevaluated} not evaluated; by priority 1-4: " <>
        Enum.map_join(1..4, " / ", &(counts[&1] || 0)) <> ")"
    )
  end
end
