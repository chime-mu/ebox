defmodule EboxTest do
  use ExUnit.Case, async: false

  alias Ebox.{Auth, Device, FakeEboks, Message}

  setup do
    Req.Test.set_req_test_to_shared()
    device = %{Device.generate() | cpr: "0101901234", activated: true}
    %{device: device}
  end

  defp connect(device, opts \\ []) do
    fake = FakeEboks.start(device, opts)
    {:ok, box} = Ebox.connect(password: FakeEboks.password(), device: device)
    on_exit(fn -> Process.alive?(box) && Ebox.disconnect(box) end)
    {box, fake}
  end

  describe "device" do
    test "survives a save/load round trip with private file modes", %{device: device} do
      dir = Path.join(System.tmp_dir!(), "ebox-test-#{System.unique_integer([:positive])}")
      on_exit(fn -> File.rm_rf!(dir) end)

      assert Device.load(dir) == {:error, :not_found}
      :ok = Device.save(%{device | sig_hash: :sha256, name: "N"}, dir)
      assert {:ok, loaded} = Device.load(dir)
      assert loaded == %{device | sig_hash: :sha256, name: "N"}

      for file <- ["device.json", "device_key.pem"] do
        assert Bitwise.band(File.stat!(Path.join(dir, file)).mode, 0o777) == 0o600
      end
    end

    test "public key is a base64 SubjectPublicKeyInfo matching the private key", %{device: device} do
      der = Base.decode64!(Device.public_key(device))
      pem = :public_key.pem_encode([{:SubjectPublicKeyInfo, der, :not_encrypted}])
      [entry] = :public_key.pem_decode(pem)
      public = :public_key.pem_entry_decode(entry)

      signature = Base.decode64!(Device.sign(device, "hello", :sha256))
      assert :public_key.verify("hello", :sha256, signature, public)

      assert device.id =~
               ~r/^[0-9A-F]{8}-[0-9A-F]{4}-4[0-9A-F]{3}-[89AB][0-9A-F]{3}-[0-9A-F]{12}$/
    end
  end

  describe "mail" do
    test "logs in with a signed challenge", %{device: device} do
      {box, _} = connect(device)
      assert %{name: "Søren Ærø", user_id: "1234"} = Ebox.whoami(box)
    end

    test "discovers which signature hash the server accepts", %{device: device} do
      {box, _} = connect(device)
      assert Ebox.whoami(box).device.sig_hash == :sha

      {box, fake} = connect(device, accepted_hash: :sha256)
      assert Ebox.whoami(box).device.sig_hash == :sha256
      assert FakeEboks.get(fake, :attempts) == 1
    end

    test "wrong password is an error carrying the server's reason", %{device: device} do
      fake = FakeEboks.start(device)

      assert {:error, %Ebox.Error{step: :login, status: 400, code: "10130", message: message}} =
               Ebox.connect(password: "nope", device: %{device | sig_hash: :sha})

      assert message =~ "Pincode not accepted."
      # A settled hash means one attempt per login, so typos do not count double.
      assert FakeEboks.get(fake, :attempts) == 1
    end

    test "refuses a device that was never activated" do
      assert {:error, %Ebox.Error{message: message}} =
               Ebox.connect(password: "x", device: Device.generate())

      assert message =~ "mix ebox.auth"
    end

    test "lists shares and nested folders, decoding Latin-1", %{device: device} do
      {box, _} = connect(device)
      assert {:ok, [%{id: "77", name: "Firma ApS"}]} = Ebox.shares(box)

      assert {:ok, folders} = Ebox.folders(box)

      assert [{"10", "Inbox", nil}, {"20", "Arkiv", nil}, {"21", "Skat & Løn", "20"}] ==
               Enum.map(folders, &{&1.id, &1.name, &1.parent_id})
    end

    test "lists messages page by page across rotating nonces", %{device: device} do
      {box, _} = connect(device)

      assert {:ok, [first, second]} = Ebox.messages(box, "10", take: 2)
      assert {:ok, [third]} = Ebox.messages(box, "10", skip: 2, take: 1)
      assert Enum.map([first, second, third], & &1.id) == ["m1", "m2", "m3"]

      assert %Message{
               name: "Årsopgørelse 1",
               sender: "Skat/Told",
               format: "PDF",
               unread: true,
               received_at: ~N[2026-03-01 08:30:00],
               folder_id: "10",
               share_id: "0"
             } = first

      assert {:ok, all} = Ebox.all_messages(box, "10")
      assert length(all) == 5
    end

    test "fetches details, document and attachments", %{device: device} do
      {box, _} = connect(device)
      {:ok, [message | _]} = Ebox.messages(box, "10")

      assert {:ok, %Message{attachments: [attachment]}} = Ebox.message(box, message)
      assert %Message.Attachment{id: "a1", name: "Bilag"} = attachment
      assert Message.extension(attachment) == "txt"
      assert Message.mime_type(message) == "application/pdf"

      assert Ebox.content(box, message) == {:ok, "content of m1"}
      assert Ebox.content(box, message, attachment) == {:ok, "content of a1"}
    end

    test "logs in again when the session has expired", %{device: device} do
      {box, fake} = connect(device)
      assert {:ok, _} = Ebox.folders(box)

      FakeEboks.expire_session(fake)
      assert {:ok, [_, _, _]} = Ebox.folders(box)
      assert FakeEboks.get(fake, :logins) == 2
    end

    test "the password does not leak through inspection", %{device: device} do
      {box, _} = connect(device)
      refute inspect(:sys.get_status(box)) =~ "s3cret"
      refute inspect(:sys.get_state(box)) =~ "s3cret"
    end
  end

  describe "activation" do
    test "runs the MitID token chain and registers the public key" do
      device = Device.generate()
      fake = FakeEboks.start(device)
      auth = Auth.start(device)
      FakeEboks.expect_code_challenge(fake, auth.url)

      query = URI.decode_query(URI.parse(auth.url).query)
      assert auth.url =~ "https://gateway.digitalpost.dk/auth/oauth/authorize?"
      assert query["redirect_uri"] == "eboksdk://ngdpoidc/callback"
      assert query["deviceId"] == device.id
      assert query["state"] == auth.state

      callback = "eboksdk://ngdpoidc/callback?code=the-code&state=#{auth.state}\n"
      assert {:ok, code} = Auth.parse_callback(auth, callback)

      assert {:ok, activated} = Auth.activate(auth, code, device, FakeEboks.password())
      assert %Device{cpr: "0101901234", name: "Søren Ærø", activated: true} = activated

      assert FakeEboks.get(fake, :registered) == %{
               "id" => device.id,
               "key" => Device.public_key(device),
               "name" => "ebox-elixir",
               "os" => "elixir"
             }

      # The freshly activated device can log in.
      assert {:ok, box} = Ebox.connect(password: FakeEboks.password(), device: activated)
      Ebox.disconnect(box)
    end

    test "reports the server's reason when the password is wrong" do
      device = Device.generate()
      fake = FakeEboks.start(device)
      auth = Auth.start(device)
      FakeEboks.expect_code_challenge(fake, auth.url)

      assert {:error, %Ebox.Error{step: :verify_password, message: message}} =
               Auth.activate(auth, "the-code", device, "wrong")

      assert message =~ "Wrong password"
      assert FakeEboks.get(fake, :registered) == nil
    end

    test "parse_callback accepts a bare code and rejects mismatches" do
      auth = Auth.start(Device.generate())
      assert Auth.parse_callback(auth, "  abc123 ") == {:ok, "abc123"}

      assert {:error, %{message: m1}} =
               Auth.parse_callback(auth, "eboksdk://ngdpoidc/callback?code=x&state=other")

      assert m1 =~ "different login attempt"

      assert {:error, %{message: m2}} =
               Auth.parse_callback(auth, "eboksdk://ngdpoidc/callback?error=access_denied")

      assert m2 =~ "access_denied"
      assert {:error, _} = Auth.parse_callback(auth, "")
      assert {:error, _} = Auth.parse_callback(auth, "https://example.com/nothing")
    end
  end

  test "download filenames cannot escape the target directory" do
    message = %Message{
      id: "../m1",
      name: "../../etc/passwd",
      sender: "A/S: Evil\\Corp",
      format: "PDF",
      received_at: ~N[2026-03-01 08:30:00]
    }

    name = Mix.Tasks.Ebox.Download.filename(message, message)
    assert name == "2026-03-01 A_S_ Evil_Corp - .._.._etc_passwd [_m1].pdf"
    refute name =~ "/"
  end
end
