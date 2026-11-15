defmodule Mix.Tasks.Ebox.Download do
  @shortdoc "Downloads e-Boks documents to a directory"

  @moduledoc """
  Downloads every document in a folder (default: Inbox), with attachments.

      mix ebox.download [FOLDER] [--to DIR] [--share ID]

  Files are named `DATE SENDER - TITLE [ID].ext` and written to `DIR` (default
  `./ebox-mail`). Documents already present are skipped, so the task can be run
  repeatedly to pick up new mail.
  """

  use Mix.Task

  alias Ebox.{CLI, Message}

  @impl true
  def run(args) do
    {opts, rest} = OptionParser.parse!(args, strict: [to: :string, share: :string])
    CLI.start()
    dir = opts[:to] || "ebox-mail"
    File.mkdir_p!(dir)

    box = CLI.connect!()
    folder = CLI.folder!(box, List.first(rest) || "Inbox", opts)
    messages = CLI.ok!(Ebox.all_messages(box, folder.id, opts))

    new =
      Enum.count(messages, fn message ->
        path = Path.join(dir, filename(message, message))

        if File.exists?(path) do
          false
        else
          download(box, dir, message, path)
          true
        end
      end)

    Mix.shell().info("#{new} new of #{length(messages)} message(s) from #{folder.name} in #{dir}")
  end

  defp download(box, dir, message, path) do
    # Attachments first: the main document marks the message as done on the next run.
    for attachment <- CLI.ok!(Ebox.message(box, message)).attachments do
      write(Path.join(dir, filename(message, attachment)), Ebox.content(box, message, attachment))
    end

    write(path, Ebox.content(box, message))
  end

  defp write(path, result) do
    partial = path <> ".part"
    File.write!(partial, CLI.ok!(result))
    File.rename!(partial, path)
    Mix.shell().info(Path.basename(path))
  end

  @doc false
  def filename(%Message{} = message, item) do
    date = if message.received_at, do: NaiveDateTime.to_date(message.received_at), else: "undated"

    title =
      if item == message, do: message.name, else: "#{message.name} - #{item.name}"

    base = clean("#{date} #{message.sender || "unknown"} - #{title}")
    "#{base} [#{clean(item.id)}].#{Message.extension(item)}"
  end

  # Server-supplied text must not be able to leave the target directory.
  defp clean(text) do
    text
    |> to_string()
    |> String.replace(~r/[\/\\:\x00-\x1f]+/u, "_")
    |> String.trim()
    |> String.trim_leading(".")
    |> String.slice(0, 150)
  end
end
