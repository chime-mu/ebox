defmodule Mix.Tasks.Ebox.Digitalpost.Messages do
  @shortdoc "Lists Digital Post messages (mail from public authorities)"

  @moduledoc """
  Lists messages in your Digital Post mailboxes.

      mix ebox.digitalpost.messages [--mailbox N] [--folder NAME] [--take N]

  Without options, lists the inbox of every mailbox you can read: your own
  first, then those of organisations you represent. `--mailbox` picks one by
  its number in that order (1 = your own). `*` marks unread messages, `!` a
  reply deadline. Needs a login from `mix ebox.auth` or `mix ebox.digitalpost.auth`.
  """

  use Mix.Task

  alias Ebox.{CLI, DigitalPost}

  @impl true
  def run(args) do
    {opts, _} =
      OptionParser.parse!(args, strict: [mailbox: :integer, folder: :string, take: :integer])

    CLI.start()
    dp = CLI.ok!(DigitalPost.connect())

    for {mailbox, n} <- selected(dp, opts[:mailbox]) do
      folders = CLI.ok!(DigitalPost.folders(dp, mailbox.id))
      folder = find_folder!(folders, opts[:folder] || "INBOX")

      messages =
        if opts[:take],
          do: CLI.ok!(DigitalPost.messages(dp, mailbox.id, folder: folder.id, size: opts[:take])),
          else: CLI.ok!(DigitalPost.all_messages(dp, mailbox.id, folder: folder.id))

      Mix.shell().info(
        "== #{n}. #{mailbox_label(mailbox)}, #{folder.name}: #{length(messages)} message(s)"
      )

      for m <- messages do
        date = if m.received_at, do: NaiveDateTime.to_date(m.received_at), else: "?"
        flags = if(m.read == false, do: "*", else: " ") <> if(m.reply_by, do: "!", else: " ")
        reply = if m.reply_by, do: " (reply by #{NaiveDateTime.to_date(m.reply_by)})", else: ""
        Mix.shell().info("#{flags} #{date}  #{m.sender || "?"}: #{m.name}#{reply}")
      end
    end
  end

  @doc false
  def selected(dp, nil), do: Enum.with_index(DigitalPost.mailboxes(dp), 1)

  def selected(dp, n) do
    all = Enum.with_index(DigitalPost.mailboxes(dp), 1)

    [
      Enum.find(all, fn {_, i} -> i == n end) ||
        Mix.raise("no mailbox #{n}; there are #{length(all)}")
    ]
  end

  @doc false
  def mailbox_label(%{owner_type: "CITIZEN"} = m), do: m.owner_name || "Personal"
  def mailbox_label(m), do: m.owner_name || "Organisation #{String.slice(m.id, 0, 8)}"

  @doc false
  def find_folder!(folders, wanted) do
    down = String.downcase(wanted)

    Enum.find(folders, &(String.downcase(&1.type || "") == down)) ||
      Enum.find(folders, &(String.downcase(&1.name || "") == down or &1.id == wanted)) ||
      Mix.raise(
        "no folder #{inspect(wanted)}; available: " <> Enum.map_join(folders, ", ", & &1.name)
      )
  end
end
