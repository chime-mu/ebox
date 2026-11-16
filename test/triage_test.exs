defmodule Ebox.TriageTest do
  use ExUnit.Case, async: false

  alias Ebox.{
    Device,
    DigitalPost,
    Evaluate,
    FakeDigitalPost,
    FakeEboksApi,
    Filing,
    Letter,
    Reminders,
    Rules,
    Triage
  }

  setup do
    Req.Test.set_req_test_to_shared()
    dir = Path.join(System.tmp_dir!(), "ebox-triage-test-#{System.unique_integer([:positive])}")
    device = %{Device.generate() | cpr: "0101901234", activated: true}
    :ok = Device.save(device, dir)
    filed = FakeDigitalPost.inbox() <> "-x"

    statements =
      for {id, day} <- [{"S1", "01"}, {"S2", "02"}, {"S3", "03"}],
          do:
            FakeEboksApi.message(id,
              folder: 21,
              subject: "Kontoudskrift nr. #{day}  for juni",
              received: "2025-06-#{day}T10:00:00"
            )

    fake =
      FakeDigitalPost.start(
        device_id: device.id,
        messages: [
          FakeDigitalPost.message(4, reply_by: "2026-11-20T00:00:00Z"),
          FakeDigitalPost.message(5, folder: filed)
        ],
        eboks_messages:
          statements ++
            [
              FakeEboksApi.message("N1", subject: "Kontoudskrift nr. 9 for maj", unread: true),
              FakeEboksApi.message("N2", subject: "Personligt brev")
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

    archive = Path.join(dir, "Mail")
    Mix.Tasks.Ebox.Archive.run([archive])
    {:ok, dp} = DigitalPost.connect()
    {:ok, eb} = Ebox.Eboks.connect(digitalpost: dp)
    %{fake: fake, archive: archive, conns: %{digitalpost: dp, eboks: eb}}
  end

  defp letter(archive, id), do: Enum.find(Letter.all(archive), &(&1.id == id))

  test "subjects are normalised: numbers, month names and spacing" do
    assert Rules.pattern("Kontoudskrift nr. 5  for Juni 2025") == "kontoudskrift nr # for #"
    assert Rules.pattern("Lønseddel - August 2024") == "lønseddel #"
  end

  test "rules are learned from filed letters and pick out routine inbox mail", %{
    archive: archive
  } do
    Mix.Tasks.Ebox.Rules.run([archive])

    assert [%{"sender" => "Banken A/S", "subject" => "kontoudskrift nr # for #"} = rule] =
             Rules.load(archive)

    assert rule["folder"] == ["Bank", "Konto_udtog"]

    # A learned rule knows the folder, but the letter is only routine once
    # Claude found nothing to do in it.
    o = Triage.overview(archive)
    assert o.routine == []
    assert o.judge |> Enum.map(& &1.id) |> Enum.sort() == ["N1", "N2", "msg-4"]
    n1 = letter(archive, "N1")
    assert Triage.suggested_folder(o, n1) == ["Bank", "Konto_udtog"]

    nothing = fn _ ->
      {:ok, ~s({"summary": "S", "important": false, "respondBy": null, "action": null})}
    end

    {:ok, _} = Evaluate.evaluate(n1, [], runner: nothing)
    assert [{%Letter{id: "N1"}, _}] = Triage.overview(archive).routine

    # The same letter with something to do is for the user to judge.
    pay = fn _ -> {:ok, ~s({"summary": "S", "important": true, "action": "Pay"})} end
    {:ok, _} = Evaluate.evaluate(letter(archive, "N1"), [], runner: pay)
    assert Triage.overview(archive).routine == []

    # A rule the user made files without asking.
    Rules.add(archive, letter(archive, "N2"), ["Tom"])
    o = Triage.overview(archive)
    assert [{%Letter{id: "N2"}, %{"origin" => "user"}}] = o.routine
    assert o.unevaluated == 1
  end

  test "filing moves the letter in e-Boks and locally, and leaves read state", %{
    fake: fake,
    archive: archive,
    conns: conns
  } do
    n1 = letter(archive, "N1")
    assert {:ok, filed} = Filing.file(conns, n1, ["Bank", "Konto_udtog"], "rule")

    assert {"own", "N1", %{"folderId" => 21}} in FakeEboksApi.writes(fake)
    assert FakeEboksApi.get_message(fake, "N1").unread == true
    assert filed.folder == ["Bank", "Konto_udtog"]
    assert filed.json_path =~ "/Post fra virksomheder/Bank/Konto_udtog/"
    assert Enum.all?(Letter.file_paths(filed), &File.exists?/1)
    refute File.exists?(n1.json_path)
    assert filed.meta["filed"]["from"] == ["Indbakke"]

    # The archive agrees with the service afterwards.
    Mix.Tasks.Ebox.Verify.run([archive])

    assert Enum.all?(
             for({:mix_shell, :info, [l]} <- flush(), do: l),
             &(&1 =~ "0 problem(s)" or not (&1 =~ "problem"))
           )

    # Filing it again from the stale copy is refused: it is no longer there.
    assert {:error, %Ebox.Error{message: msg}} =
             Filing.file(conns, n1, ["Tom"], "user")

    assert msg =~ "no longer in Indbakke"
  end

  test "filing moves the letter in Digital Post with its version", %{
    fake: fake,
    archive: archive,
    conns: conns
  } do
    m4 = letter(archive, "msg-4")
    assert {:ok, filed} = Filing.file(conns, m4, ["Skat_2025"], "user")

    moved = Enum.find(FakeDigitalPost.get(fake, :messages), &(&1.id == "msg-4"))
    assert moved.folderId == FakeDigitalPost.inbox() <> "-x"
    assert moved.version == 2
    assert moved.read == false
    assert filed.json_path =~ "/Post fra det offentlige/Skat_2025/"
    assert filed.folder_id == FakeDigitalPost.inbox() <> "-x"
  end

  test "unknown folder is refused before anything is changed", %{archive: archive, conns: conns} do
    assert {:error, %Ebox.Error{message: "no folder Nope in this mailbox"}} =
             Filing.file(conns, letter(archive, "N2"), ["Nope"], "user")
  end

  test "evaluation is stored and gives the priority", %{archive: archive} do
    n2 = letter(archive, "N2")

    runner = fn prompt ->
      assert prompt =~ "Title: Personligt brev"
      assert prompt =~ "- Bank/Konto_udtog"
      refute prompt =~ "- Indbakke"

      {:ok,
       ~s(Here you go:\n{"summary": "S", "important": true, "importance": "money", "respondBy": "2026-11-20", "respondByBasis": "payment due", "action": "Pay", "folder": ["Bank"], "recurring": false, "extra": 1})}
    end

    assert {:ok, l} = Evaluate.evaluate(n2, Triage.local_folders(n2), runner: runner)
    assert %{"important" => true, "action" => "Pay", "model" => _} = Letter.evaluation(l)
    refute Map.has_key?(Letter.evaluation(l), "extra")

    assert Evaluate.priority(l, ~D[2026-11-15]) == 1
    assert Evaluate.priority(l, ~D[2026-10-01]) == 2
    assert Evaluate.priority(l, ~D[2026-12-15]) == 1
    assert Evaluate.priority(l, ~D[2027-01-15]) == 2

    # Digital Post's own reply deadline counts without any evaluation.
    m4 = letter(archive, "msg-4")
    assert Evaluate.respond_by(m4) == ~D[2026-11-20]
    assert Evaluate.priority(m4, ~D[2026-11-15]) == 3

    assert {:error, %Ebox.Error{step: :evaluate}} =
             Evaluate.evaluate(n2, [], runner: fn _ -> {:ok, "no idea"} end)
  end

  test "a reminder takes the action, the respond-by date and a link", %{archive: archive} do
    n2 = letter(archive, "N2")

    {:ok, n2} =
      Evaluate.evaluate(n2, [],
        runner: fn _ ->
          {:ok,
           ~s({"summary": "S", "important": true, "respondBy": "2026-12-01", "action": "Pay the bill"})}
        end
      )

    me = self()

    run = fn args ->
      send(me, {:osascript, args})
      :ok
    end

    assert {:ok, l} = Reminders.add(n2, "http://127.0.0.1:4100/#l-x", runner: run)
    assert_received {:osascript, ["Post", "Pay the bill", body, "2026", "12", "1"]}
    assert body =~ "Banken A/S: Personligt brev"
    assert body =~ "http://127.0.0.1:4100/#l-x"
    assert l.meta["reminder"]["due"] == "2026-12-01"
  end

  test "the web app shows the inbox by priority and refuses changes without its secret", %{
    archive: archive
  } do
    :persistent_term.put(Ebox.Web, %{archive: archive, port: 4100, secret: "s3cret"})
    {:ok, _} = start_supervised(%{id: :jobs, start: {Ebox.Web.Jobs, :start_link, []}})

    conn = Plug.Test.conn(:get, "http://127.0.0.1/") |> Ebox.Web.call([])
    assert conn.status == 200
    assert conn.resp_body =~ "Personligt brev"
    assert conn.resp_body =~ "respond by 2026-11-20"

    conn = Plug.Test.conn(:get, "http://evil.example/") |> Ebox.Web.call([])
    assert conn.status == 403

    key = letter(archive, "N2").key

    conn =
      Plug.Test.conn(:post, "http://127.0.0.1/letter/#{key}/reminder", "t=wrong")
      |> form()
      |> Ebox.Web.call([])

    assert conn.status == 403

    conn = Plug.Test.conn(:get, "http://127.0.0.1/letter/#{key}/file/0") |> Ebox.Web.call([])
    assert conn.status == 200
    assert conn.resp_body =~ "%PDF"

    assert Plug.Test.conn(:get, "http://127.0.0.1/letter/#{key}/file/5")
           |> Ebox.Web.call([])
           |> Map.get(:status) == 404
  end

  defp form(conn),
    do: Plug.Conn.put_req_header(conn, "content-type", "application/x-www-form-urlencoded")

  defp flush do
    receive do
      m -> [m | flush()]
    after
      0 -> []
    end
  end
end
