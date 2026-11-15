defmodule Ebox.DigitalPostTest do
  use ExUnit.Case, async: false

  alias Ebox.{Auth, Device, DigitalPost, FakeDigitalPost}
  alias Ebox.DigitalPost.Message

  setup do
    Req.Test.set_req_test_to_shared()
    dir = Path.join(System.tmp_dir!(), "ebox-dp-test-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(dir) end)
    %{dir: dir}
  end

  defp stored(dir), do: dir |> Path.join("digitalpost.json") |> File.read!() |> JSON.decode!()

  defp logged_in(dir, opts \\ []) do
    fake = FakeDigitalPost.start(opts)
    :ok = DigitalPost.save_tokens(FakeDigitalPost.tokens(0), dir)
    fake
  end

  defp connect(dir) do
    {:ok, dp} = DigitalPost.connect(dir: dir)
    on_exit(fn -> Process.alive?(dp) && DigitalPost.disconnect(dp) end)
    dp
  end

  describe "login" do
    test "stores the tokens of a MitID login privately", %{dir: dir} do
      fake = FakeDigitalPost.start()
      auth = Auth.start(Device.generate())
      FakeDigitalPost.expect_code_challenge(fake, auth.url)

      refute DigitalPost.logged_in?(dir: dir)
      callback = "eboksdk://ngdpoidc/callback?code=the-code&state=#{auth.state}\n"
      assert :ok = DigitalPost.authorize(auth, callback, dir: dir)

      assert DigitalPost.logged_in?(dir: dir)
      assert %{"refresh_token" => "refresh", "saved_at" => _} = stored(dir)
      assert Bitwise.band(File.stat!(Path.join(dir, "digitalpost.json")).mode, 0o777) == 0o600
      assert Bitwise.band(File.stat!(dir).mode, 0o777) == 0o700
    end

    test "refuses a callback from another login attempt", %{dir: dir} do
      FakeDigitalPost.start()
      auth = Auth.start(Device.generate())

      assert {:error, %Ebox.Error{step: :callback}} =
               DigitalPost.authorize(auth, "eboksdk://ngdpoidc/callback?code=x&state=other",
                 dir: dir
               )

      refute DigitalPost.logged_in?(dir: dir)
    end

    test "without a stored login, says how to log in", %{dir: dir} do
      FakeDigitalPost.start()
      assert {:error, %Ebox.Error{message: message}} = DigitalPost.connect(dir: dir)
      assert message =~ "mix ebox.digitalpost.auth"
    end
  end

  describe "renewal" do
    test "renews without MitID and saves the new access token", %{dir: dir} do
      fake = logged_in(dir)
      assert :ok = DigitalPost.renew(dir: dir)
      assert %{"access_token" => "access-1", "refresh_token" => "refresh"} = stored(dir)
      assert FakeDigitalPost.get(fake, :renewals) == 1
    end

    test "an expired login points to mix ebox.digitalpost.auth", %{dir: dir} do
      fake = logged_in(dir)
      FakeDigitalPost.expire_login(fake)
      assert {:error, %Ebox.Error{step: :renew, message: message}} = DigitalPost.renew(dir: dir)
      assert message =~ "mix ebox.digitalpost.auth"
    end

    test "renews once and retries when the access token is refused", %{dir: dir} do
      fake = logged_in(dir)
      dp = connect(dir)
      renewals = FakeDigitalPost.get(fake, :renewals)

      FakeDigitalPost.revoke_access(fake)
      assert {:ok, [_ | _]} = DigitalPost.folders(dp, FakeDigitalPost.personal())
      assert FakeDigitalPost.get(fake, :renewals) == renewals + 1
    end
  end

  describe "reading mail" do
    test "backs off and retries when rate-limited", %{dir: dir} do
      fake = logged_in(dir)
      dp = connect(dir)
      FakeDigitalPost.throttle(fake, 2)
      assert {:ok, [_ | _]} = DigitalPost.folders(dp, FakeDigitalPost.personal())
    end

    test "lists mailboxes (own first), folders and messages, and downloads files", %{dir: dir} do
      fake = logged_in(dir)
      dp = connect(dir)

      assert [
               %{owner_type: "CITIZEN", owner_name: "Søren Ærø"} = mine,
               %{owner_type: "ORGANISATION"}
             ] =
               DigitalPost.mailboxes(dp)

      assert {:ok, folders} = DigitalPost.folders(dp, mine.id)
      assert %{id: inbox, name: "Indbakke"} = Enum.find(folders, &(&1.type == "INBOX"))

      assert {:ok, [first, second]} = DigitalPost.messages(dp, mine.id, folder: inbox)

      assert %Message{
               id: "msg-1",
               name: "Brev 1",
               sender: "Skattestyrelsen",
               received_at: ~N[2026-10-02 09:30:00],
               read: false,
               reply_by: ~N[2026-12-01 00:00:00],
               mailbox_id: "11111111-1111-1111-1111-111111111111"
             } = first

      assert second.read == true
      assert [letter, attachment] = first.files
      assert %Message.File{document_type: "MAIN", name: "brev.pdf", size: 1234} = letter
      assert %Message.File{document_type: "ATTACHMENT", document_id: "doc-1b"} = attachment

      assert {:ok, "%PDF-1.7 msg-1/doc-1b/file-1b"} = DigitalPost.content(dp, first, attachment)

      # Reading is read-only: no PUT/PATCH/POST/DELETE reached the server.
      assert FakeDigitalPost.get(fake, :writes) == 0
    end

    test "pages through a large mailbox", %{dir: dir} do
      logged_in(dir, messages: Enum.map(1..250, &FakeDigitalPost.message/1))
      dp = connect(dir)

      assert {:ok, messages} = DigitalPost.all_messages(dp, FakeDigitalPost.personal())
      assert length(messages) == 250
      assert messages |> Enum.map(& &1.id) |> Enum.uniq() |> length() == 250
    end

    test "keeps tokens out of process status", %{dir: dir} do
      logged_in(dir)
      dp = connect(dir)
      refute inspect(:sys.get_status(dp)) =~ "access-"
    end
  end
end
