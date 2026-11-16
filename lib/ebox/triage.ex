defmodule Ebox.Triage do
  @moduledoc """
  What is in the inboxes and what to do with it.

  - **Routine** letters are filed into their folder without asking. A letter
    is routine when a rule the user made matches it, or when a learned rule
    matches it *and* Claude found nothing to do (not important, no respond-by
    date, no action). Learned rules only know where letters were filed in
    the past, not whether they needed doing something first.
  - Every other letter is for the recipient to judge, ordered by priority
    (`Ebox.Evaluate.priority/2`): 1 urgent and important, 2 important,
    3 urgent, 4 neither. Claude's evaluation supplies importance and the
    respond-by date; a matching rule supplies the folder.
  """

  alias Ebox.{Evaluate, Filing, Letter, Rules}

  @doc """
  The inboxes now: `%{routine: [{letter, rule}], judge: [letter],
  unevaluated: n, rules: %{key => rule}}`, `judge` sorted by priority, then
  respond-by date, then newest first. `rules` holds the matching rule of
  letters to judge, for their folder.
  """
  def overview(archive, today \\ Date.utc_today()) do
    rules = Rules.load(archive)
    matched = for l <- Letter.inbox(archive), do: {l, Rules.match(rules, l)}
    {routine, judge} = Enum.split_with(matched, fn {l, rule} -> routine?(l, rule) end)

    judge_rules = for {l, rule} <- judge, rule, into: %{}, do: {l.key, rule}

    judge =
      judge
      |> Enum.map(&elem(&1, 0))
      |> Enum.sort_by(fn l ->
        due = Evaluate.respond_by(l)

        {Evaluate.priority(l, today), if(due, do: Date.to_gregorian_days(due), else: :infinity),
         -Date.to_gregorian_days(l.received_at || ~D[1970-01-01])}
      end)

    %{
      routine: Enum.sort_by(routine, fn {l, _} -> {l.mailbox, l.source, l.received_at} end, :asc),
      judge: judge,
      unevaluated: Enum.count(judge, &(Letter.evaluation(&1) == nil)),
      rules: judge_rules
    }
  end

  @doc "Whether a letter with this matching rule (or nil) can be filed without asking."
  def routine?(_letter, nil), do: false
  def routine?(_letter, %{"origin" => "user"}), do: true

  def routine?(letter, _learned) do
    case Letter.evaluation(letter) do
      nil ->
        false

      eval ->
        eval["important"] != true and eval["action"] in [nil, ""] and
          Evaluate.respond_by(letter) == nil
    end
  end

  @doc "The folder to suggest: the matching rule's, else Claude's."
  def suggested_folder(overview, letter),
    do:
      (overview.rules[letter.key] || %{})["folder"] ||
        (Letter.evaluation(letter) || %{})["folder"]

  @doc """
  The folder paths of a letter's mailbox, from the local archive (which holds
  every folder of the service, also empty ones). The inbox is left out.
  """
  def local_folders(%Letter{} = letter), do: folders_at(system_root(letter))

  @doc """
  What filing one letter needs: `%{rule: matching rule or nil, folders:
  local_folders/1, suggested: folder path or nil}`.
  """
  def context(archive, %Letter{} = letter) do
    rule = Rules.match(Rules.load(archive), letter)

    %{
      rule: rule,
      folders: local_folders(letter),
      suggested: (rule || %{})["folder"] || (Letter.evaluation(letter) || %{})["folder"]
    }
  end

  defp folders_at(root) do
    root
    |> Path.join("**")
    |> Path.wildcard()
    |> Enum.filter(&File.dir?/1)
    |> Enum.map(&Path.split(Path.relative_to(&1, root)))
    |> Enum.reject(&(hd(&1) == Letter.inbox_name()))
    |> Enum.sort()
  end

  defp system_root(%Letter{json_path: path, folder: folder}),
    do: path |> Path.dirname() |> Path.split() |> Enum.drop(-length(folder)) |> Path.join()

  @doc "Files every routine letter by its rule. Returns `[{letter, :ok | {:error, e}}]`."
  def file_routine(archive, conns) do
    for {letter, rule} <- overview(archive).routine do
      case Filing.file(conns, letter, rule["folder"], "rule") do
        {:ok, _} -> {letter, :ok}
        error -> {letter, error}
      end
    end
  end

  @doc """
  Evaluates the letters to judge that have no evaluation yet, a few at a
  time. Calls `progress.(letter, result)` after each. Options as for
  `Ebox.Evaluate.evaluate/3`, plus `:limit`.
  """
  def evaluate_pending(archive, opts \\ [], progress \\ fn _, _ -> :ok end) do
    pending = overview(archive).judge |> Enum.filter(&(Letter.evaluation(&1) == nil))
    pending = if opts[:limit], do: Enum.take(pending, opts[:limit]), else: pending

    pending
    |> Task.async_stream(
      fn letter -> {letter, Evaluate.evaluate(letter, local_folders(letter), opts)} end,
      max_concurrency: opts[:concurrency] || 4,
      timeout: 300_000,
      on_timeout: :kill_task,
      ordered: false
    )
    |> Enum.map(fn
      {:ok, {letter, result}} ->
        progress.(letter, result)
        {letter, result}

      {:exit, reason} ->
        progress.(nil, {:error, reason})
        {nil, {:error, reason}}
    end)
  end
end
