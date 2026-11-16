defmodule Ebox.Rules do
  @moduledoc """
  Rules for routine mail: letters that arrive in a fixed rhythm (account
  statements, payment overviews...) and only need to be put in their folder.

  A rule names a system, a mailbox, a sender and a subject pattern, and the
  folder such letters go to. They live in `ARCHIVE/.ebox/rules.json`:

      {"rules": [
        {"source": "e-boks", "mailbox": "Your Name", "sender": "Bank A/S",
         "subject": "kontoudskrift nr # for kontonr #",
         "folder": ["Bank", "Kontoudskrift"], "origin": "learned", "seen": 36},
        {"source": "e-boks", "mailbox": "Your Name", "sender": "Bank A/S",
         "subject": "*", "folder": ["Bank"], "origin": "user"}
      ]}

  The subject pattern is the subject as `pattern/1` normalises it: lower case,
  numbers and month names replaced by `#`, punctuation dropped, spacing
  collapsed. `"*"` matches
  any subject from that sender. The first matching rule wins; rules the user
  made come before learned ones.

  A user-made rule files matching letters without asking. A learned rule only
  says where such letters went in the past; `Ebox.Triage` files by it only
  when Claude finds nothing to do in the letter.

  `learn/1` derives rules from how letters were filed in the past: a sender
  and subject pattern seen at least #{3} times, filed in one folder at least
  70% of the time.
  """

  alias Ebox.Letter

  @min_seen 3
  @min_share 0.7

  @months ~w(januar februar marts april maj juni juli august september oktober november december
             jan feb mar apr jun jul aug sep sept okt nov dec)
  @month_re Regex.compile!("\\b(" <> Enum.join(@months, "|") <> ")\\b", "u")

  @doc "Where the rules are stored."
  def path(archive), do: Path.join([archive, ".ebox", "rules.json"])

  @doc "The subject of a letter, normalised for matching."
  def pattern(subject) do
    (subject || "")
    |> String.downcase()
    |> String.replace(@month_re, "#")
    |> String.replace(~r/\d[\d.,\/:\-]*/u, "#")
    |> String.replace(~r/[^\p{L}\p{N}#\s]+/u, " ")
    |> String.replace(~r/#(\s*#)+/u, "#")
    |> String.replace(~r/\s+/u, " ")
    |> String.trim()
  end

  defp norm(text), do: (text || "") |> String.downcase() |> String.trim()

  @doc "The stored rules (an empty list if there are none yet)."
  def load(archive) do
    case File.read(path(archive)) do
      {:ok, json} -> JSON.decode!(json)["rules"] || []
      {:error, :enoent} -> []
    end
  end

  @doc "Stores rules, user-made first."
  def save(archive, rules) do
    File.mkdir_p!(Path.dirname(path(archive)))
    rules = Enum.sort_by(rules, &if(&1["origin"] == "user", do: 0, else: 1))
    partial = path(archive) <> ".part"
    File.write!(partial, JSON.encode!(%{"rules" => rules}))
    File.rename!(partial, path(archive))
  end

  @doc "The first rule matching a letter, or nil."
  def match(rules, %Letter{} = letter) do
    subject = pattern(letter.title)

    Enum.find(rules, fn r ->
      r["source"] == letter.source and r["mailbox"] == letter.mailbox and
        norm(r["sender"]) == norm(letter.sender) and r["subject"] in ["*", subject]
    end)
  end

  @doc """
  Rules learned from the filed letters (everything outside the inboxes).
  Returns `{rules, stats}`, where stats says how many filed letters the rules
  would have put where they are.
  """
  def learn(letters) do
    filed = Enum.reject(letters, &Letter.in_inbox?/1)

    groups =
      Enum.group_by(filed, &{&1.source, &1.mailbox, norm(&1.sender), pattern(&1.title)})

    rules =
      for {{source, mailbox, _, subject}, group} <- groups,
          length(group) >= @min_seen,
          {folder, n} = group |> Enum.frequencies_by(& &1.folder) |> Enum.max_by(&elem(&1, 1)),
          n / length(group) >= @min_share do
        %{
          "source" => source,
          "mailbox" => mailbox,
          "sender" => hd(group).sender,
          "subject" => subject,
          "folder" => folder,
          "origin" => "learned",
          "seen" => length(group)
        }
      end
      |> Enum.sort_by(&{&1["mailbox"], &1["source"], &1["sender"], -&1["seen"]})

    right = Enum.count(filed, &(match(rules, &1)["folder"] == &1.folder))
    {rules, %{filed: length(filed), covered: Enum.count(filed, &match(rules, &1)), right: right}}
  end

  @doc "Replaces the learned rules, keeping those the user made."
  def relearn(archive) do
    {learned, stats} = learn(Letter.all(archive))
    user = Enum.filter(load(archive), &(&1["origin"] == "user"))
    save(archive, user ++ learned)
    {length(user), length(learned), stats}
  end

  @doc """
  Adds a user rule: letters like this one (same sender and subject pattern, or
  any subject with `any_subject: true`) go to `folder`.
  """
  def add(archive, %Letter{} = letter, folder, opts \\ []) do
    rule = %{
      "source" => letter.source,
      "mailbox" => letter.mailbox,
      "sender" => letter.sender,
      "subject" => if(opts[:any_subject], do: "*", else: pattern(letter.title)),
      "folder" => folder,
      "origin" => "user",
      "made" => Date.utc_today() |> Date.to_iso8601()
    }

    same =
      &(Map.take(&1, ~w(source mailbox sender subject)) ==
          Map.take(rule, ~w(source mailbox sender subject)))

    save(archive, [rule | Enum.reject(load(archive), same)])
    rule
  end

  @doc "Removes the rule at a position of `load/1`."
  def delete(archive, index) do
    save(archive, List.delete_at(load(archive), index))
  end
end
