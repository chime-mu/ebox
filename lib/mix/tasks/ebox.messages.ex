defmodule Mix.Tasks.Ebox.Messages do
  @shortdoc "Lists e-Boks messages in a folder (default: the inbox)"

  @moduledoc """
  Lists the messages in one e-Boks folder, newest first. Listing leaves read
  state untouched.

      mix ebox.messages [FOLDER] [--mailbox NAME] [--take N]

  `FOLDER` is a folder name or id (default: the inbox). `--mailbox` picks a
  shared mailbox by name (default: your own). For Digital Post, see
  `mix ebox.digitalpost.messages`.
  """

  use Mix.Task

  alias Ebox.{CLI, Eboks}

  @impl true
  def run(args) do
    {opts, rest} = OptionParser.parse!(args, strict: [mailbox: :string, take: :integer])
    CLI.start()
    %{eboks: eb} = CLI.connect_sources!("e-boks")
    mailboxes = Eboks.mailboxes(eb)

    mailbox =
      case opts[:mailbox] do
        nil ->
          hd(mailboxes)

        name ->
          Enum.find(mailboxes, &(String.downcase(&1.name || "") == String.downcase(name))) ||
            Mix.raise(
              "no mailbox #{inspect(name)}; available: " <>
                Enum.map_join(mailboxes, ", ", & &1.name)
            )
      end

    folders = CLI.ok!(Eboks.folders(eb, mailbox))

    folder =
      case rest do
        [] ->
          Enum.find(folders, &(&1.type == "inbox"))

        [wanted | _] ->
          Enum.find(
            folders,
            &(&1.id == wanted or String.downcase(&1.name) == String.downcase(wanted))
          )
      end || Mix.raise("no such folder; available: " <> Enum.map_join(folders, ", ", & &1.name))

    messages =
      case opts[:take] do
        nil -> CLI.ok!(Eboks.all_messages(eb, mailbox, folder.id))
        n -> CLI.ok!(Eboks.messages(eb, mailbox, folder.id, limit: n)).messages
      end

    for m <- messages do
      date = if m.received_at, do: NaiveDateTime.to_date(m.received_at), else: "undated"
      mark = if m.unread, do: "*", else: " "
      Mix.shell().info("#{mark} #{date}  #{m.sender}  –  #{m.name}")
    end

    Mix.shell().info(
      "#{length(messages)} message(s) in #{mailbox.name} / #{folder.name} (* = unread)"
    )
  end
end
