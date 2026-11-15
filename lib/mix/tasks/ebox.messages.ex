defmodule Mix.Tasks.Ebox.Messages do
  @shortdoc "Lists messages in an e-Boks folder"

  @moduledoc """
  Lists the messages in a folder (default: Inbox).

      mix ebox.messages [FOLDER] [--share ID] [--take N]

  `FOLDER` is a folder name or id from `mix ebox.folders`. Without `--take`
  every message is listed.
  """

  use Mix.Task

  alias Ebox.CLI

  @impl true
  def run(args) do
    {opts, rest} = OptionParser.parse!(args, strict: [share: :string, take: :integer])
    CLI.start()
    box = CLI.connect!()
    folder = CLI.folder!(box, List.first(rest) || "Inbox", opts)

    messages =
      if opts[:take],
        do: CLI.ok!(Ebox.messages(box, folder.id, opts)),
        else: CLI.ok!(Ebox.all_messages(box, folder.id, opts))

    for message <- messages do
      date = if message.received_at, do: NaiveDateTime.to_date(message.received_at), else: "?"
      flag = if message.unread, do: "*", else: " "

      Mix.shell().info(
        "#{flag} #{date}  #{message.id}  #{message.sender || "?"}: #{message.name} (#{message.format})"
      )
    end

    Mix.shell().info("#{length(messages)} message(s) in #{folder.name}")
  end
end
