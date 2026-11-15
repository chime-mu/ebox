defmodule Ebox.AuthTest do
  use ExUnit.Case, async: false

  alias Ebox.{Auth, Device, FakeActivation}

  setup do
    Req.Test.set_req_test_to_shared()
    device = %{Device.generate() | cpr: "0101901234", activated: true}
    %{device: device}
  end

  describe "device" do
    test "survives a save/load round trip with private file modes", %{device: device} do
      dir = Path.join(System.tmp_dir!(), "ebox-test-#{System.unique_integer([:positive])}")
      on_exit(fn -> File.rm_rf!(dir) end)

      assert Device.load(dir) == {:error, :not_found}
      :ok = Device.save(%{device | name: "N"}, dir)
      assert {:ok, loaded} = Device.load(dir)
      assert loaded == %{device | name: "N"}

      for file <- ["device.json", "device_key.pem"] do
        assert Bitwise.band(File.stat!(Path.join(dir, file)).mode, 0o777) == 0o600
      end
    end

    test "public key is a base64 SubjectPublicKeyInfo matching the private key", %{device: device} do
      der = Base.decode64!(Device.public_key(device))
      pem = :public_key.pem_encode([{:SubjectPublicKeyInfo, der, :not_encrypted}])
      [entry] = :public_key.pem_decode(pem)
      public = :public_key.pem_entry_decode(entry)

      signature = :public_key.sign("hello", :sha256, device.private_key)
      assert :public_key.verify("hello", :sha256, signature, public)

      assert device.id =~
               ~r/^[0-9A-F]{8}-[0-9A-F]{4}-4[0-9A-F]{3}-[89AB][0-9A-F]{3}-[0-9A-F]{12}$/
    end
  end

  describe "activation" do
    test "runs the MitID token chain and registers the public key" do
      device = Device.generate()
      fake = FakeActivation.start(device)
      auth = Auth.start(device)
      FakeActivation.expect_code_challenge(fake, auth.url)

      query = URI.decode_query(URI.parse(auth.url).query)
      assert auth.url =~ "https://gateway.digitalpost.dk/auth/oauth/authorize?"
      assert query["redirect_uri"] == "eboksdk://ngdpoidc/callback"
      assert query["deviceId"] == device.id
      assert query["state"] == auth.state

      callback = "eboksdk://ngdpoidc/callback?code=the-code&state=#{auth.state}\n"
      assert {:ok, code} = Auth.parse_callback(auth, callback)

      assert {:ok, activated, digital_post} =
               Auth.activate(auth, code, device, FakeActivation.password())

      assert %{"access_token" => "dp-token", "refresh_token" => "dp-refresh"} = digital_post
      assert %Device{cpr: "0101901234", name: "Søren Ærø", activated: true} = activated

      assert FakeActivation.get(fake, :registered) == %{
               "id" => device.id,
               "key" => Device.public_key(device),
               "name" => "ebox-elixir",
               "os" => "elixir"
             }
    end

    test "reports the server's reason when the password is wrong" do
      device = Device.generate()
      fake = FakeActivation.start(device)
      auth = Auth.start(device)
      FakeActivation.expect_code_challenge(fake, auth.url)

      assert {:error, %Ebox.Error{step: :verify_password, message: message}} =
               Auth.activate(auth, "the-code", device, "wrong")

      assert message =~ "Wrong password"
      assert FakeActivation.get(fake, :registered) == nil
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
end
