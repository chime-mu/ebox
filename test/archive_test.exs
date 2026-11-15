defmodule Ebox.ArchiveTest do
  use ExUnit.Case, async: false

  alias Ebox.{Device, DigitalPost, FakeDigitalPost, FakeEboksApi}

  setup do
    Req.Test.set_req_test_to_shared()
    dir = Path.join(System.tmp_dir!(), "ebox-archive-test-#{System.unique_integer([:positive])}")
    device = %{Device.generate() | cpr: "0101901234", activated: true}
    :ok = Device.save(device, dir)

    filed = FakeDigitalPost.inbox() <> "-x"

    fake =
      FakeDigitalPost.start(
        device_id: device.id,
        messages: [
          FakeDigitalPost.message(4),
          FakeDigitalPost.message(5, folder: filed, attachment: true)
        ]
      )

    :ok = DigitalPost.save_tokens(FakeDigitalPost.tokens(0), dir)
    System.put_env("EBOX_HOME", dir)
    Mix.shell(Mix.Shell.Process)

    on_exit(fn ->
      System.delete_env("EBOX_HOME")
      Mix.shell(Mix.Shell.IO)
      File.rm_rf!(dir)
    end)

    %{fake: fake, archive: Path.join(dir, "Mail")}
  end

  defp tree(root) do
    root
    |> Path.join("**")
    |> Path.wildcard()
    |> Enum.map(&(Path.relative_to(&1, root) <> if(File.dir?(&1), do: "/", else: "")))
    |> Enum.sort()
  end

  defp lines, do: for({:mix_shell, :info, [line]} <- flush(), do: line)

  defp flush do
    receive do
      message -> [message | flush()]
    after
      0 -> []
    end
  end

  test "mirrors the app: owner / system / folders, every folder, inboxes skipped", %{
    fake: fake,
    archive: archive
  } do
    Mix.Tasks.Ebox.Archive.run([archive, "--skip-inbox"])

    eb = "Søren Ærø/Post fra virksomheder/Bank/Konto_udtog/2025-05-04 Banken A_S - "
    dp = "Søren Ærø/Post fra det offentlige/Skat_2025/2026-10-06 Skattestyrelsen - Brev 5 [msg-5]"

    assert tree(archive) == [
             "Firma ApS/",
             "Firma ApS/Post fra det offentlige/",
             "Firma ApS/Post fra det offentlige/Skat_2025/",
             "Firma ApS/Post fra virksomheder/",
             "Firma ApS/Post fra virksomheder/Diverse/",
             "Firma ApS/Post fra virksomheder/Diverse/2025-05-04 Kreditinfo A_S - Brev E4 [E4].json",
             "Firma ApS/Post fra virksomheder/Diverse/2025-05-04 Kreditinfo A_S - Brev E4 [E4].pdf",
             "Søren Ærø/",
             "Søren Ærø/Post fra det offentlige/",
             "Søren Ærø/Post fra det offentlige/Skat_2025/",
             dp <> " - bilag.pdf",
             dp <> ".json",
             dp <> ".pdf",
             "Søren Ærø/Post fra virksomheder/",
             "Søren Ærø/Post fra virksomheder/Bank/",
             "Søren Ærø/Post fra virksomheder/Bank/Konto_udtog/",
             eb <> ".._.._etc_passwd [E3].json",
             eb <> ".._.._etc_passwd [E3].pdf",
             eb <> "Brev E2 [E2] - Bilag [901].pdf",
             eb <> "Brev E2 [E2] - Bilag [902].pdf",
             eb <> "Brev E2 [E2].json",
             eb <> "Brev E2 [E2].pdf",
             "Søren Ærø/Post fra virksomheder/Slettet post/",
             "Søren Ærø/Post fra virksomheder/Tom/"
           ]

    meta = archive |> Path.join(eb <> "Brev E2 [E2].json") |> File.read!() |> JSON.decode!()

    assert %{
             "source" => "e-boks",
             "mailbox" => "Søren Ærø",
             "folder" => ["Bank", "Konto_udtog"],
             "folderId" => "21",
             "files" => [%{"size" => 40}, %{"id" => "901", "size" => 50}, %{"id" => "902"}]
           } = meta

    # E3 was unread: downloading marked it read, the archive set it back.
    assert FakeEboksApi.get_message(fake, "E3").unread == true
    assert {"own", "E3", %{"unread" => true}} in FakeEboksApi.writes(fake)
    # The inbox was left alone entirely.
    refute Enum.any?(FakeEboksApi.content_reads(fake), &match?({_, "E1", _}, &1))
    assert FakeEboksApi.get_message(fake, "E1").unread == true

    assert "Søren Ærø / Post fra virksomheder: 2 new of 2 message(s) in 4 folder(s), 1 kept unread" in lines()

    Mix.Tasks.Ebox.Archive.run([archive, "--skip-inbox"])
    assert "0 new message(s) in #{archive}" in lines()
  end

  test "verify passes a complete archive and names what is missing or damaged", %{
    archive: archive
  } do
    Mix.Tasks.Ebox.Archive.run([archive, "--skip-inbox"])
    _ = lines()

    Mix.Tasks.Ebox.Verify.run([archive, "--skip-inbox"])
    assert Enum.all?(lines(), &(&1 =~ "0 problem(s), 0 note(s)"))

    bank = Path.join(archive, "Søren Ærø/Post fra virksomheder/Bank/Konto_udtog")
    File.rm!(Path.join(bank, "2025-05-04 Banken A_S - Brev E2 [E2] - Bilag [902].pdf"))
    File.write!(Path.join(bank, "2025-05-04 Banken A_S - Brev E2 [E2].pdf"), "%PDF-short")
    File.rm_rf!(Path.join(archive, "Søren Ærø/Post fra virksomheder/Tom"))
    File.write!(Path.join(bank, "x.pdf.part"), "")

    assert_raise Mix.Error, ~r/^4 problem/, fn ->
      Mix.Tasks.Ebox.Verify.run([archive, "--skip-inbox"])
    end

    out = lines()
    assert Enum.any?(out, &(&1 =~ "problem: missing file:" and &1 =~ "Bilag [902]"))
    assert Enum.any?(out, &(&1 =~ "problem: size 10, the service says 40"))
    assert Enum.any?(out, &(&1 =~ "problem: folder missing: Søren Ærø/Post fra virksomheder/Tom"))
    assert Enum.any?(out, &(&1 =~ "problem: unfinished download"))
  end

  test "without --skip-inbox the inbox is archived and unread mail stays unread", %{
    fake: fake,
    archive: archive
  } do
    Mix.Tasks.Ebox.Archive.run([archive])

    assert File.exists?(
             Path.join(
               archive,
               "Søren Ærø/Post fra virksomheder/Indbakke/2025-05-04 Banken A_S - Brev E1 [E1].pdf"
             )
           )

    assert FakeEboksApi.get_message(fake, "E1").unread == true
    assert {"own", "E1", %{"unread" => true}} in FakeEboksApi.writes(fake)
  end
end
