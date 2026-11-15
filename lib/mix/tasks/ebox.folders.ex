defmodule Mix.Tasks.Ebox.Folders do
  @shortdoc "Lists the mailboxes and folders you can read, in e-Boks and Digital Post"

  @moduledoc """
  Lists every mailbox you can read with its folders, laid out like the e-Boks
  app: per owner, "Post fra virksomheder" (e-Boks), then "Post fra det
  offentlige" (Digital Post).

      mix ebox.folders [--only e-boks|digitalpost]
  """

  use Mix.Task

  alias Ebox.{CLI, DigitalPost, Eboks}

  @impl true
  def run(args) do
    {opts, _} = OptionParser.parse!(args, strict: [only: :string])
    CLI.start()
    conns = CLI.connect_sources!(opts[:only])

    if eb = conns[:eboks] do
      for mailbox <- Eboks.mailboxes(eb) do
        title =
          "#{mailbox.name} – Post fra virksomheder" <>
            if(mailbox.own, do: "", else: " (shared with you)")

        print(title, CLI.ok!(Eboks.folders(eb, mailbox)))
      end
    end

    if dp = conns[:digitalpost] do
      for mailbox <- DigitalPost.mailboxes(dp) do
        print(
          "#{mailbox.owner_name} – Post fra det offentlige",
          CLI.ok!(DigitalPost.folders(dp, mailbox.id))
        )
      end
    end
  end

  defp print(title, folders) do
    by_id = Map.new(folders, &{&1.id, &1})
    depth = fn depth, f -> if p = by_id[f.parent_id], do: 1 + depth.(depth, p), else: 0 end
    Mix.shell().info(title)

    for f <- folders do
      Mix.shell().info(
        "  " <> String.duplicate("  ", depth.(depth, f)) <> "#{f.name}  (#{f.type})"
      )
    end
  end
end
