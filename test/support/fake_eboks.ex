defmodule Ebox.FakeEboks do
  @moduledoc false
  # A stand-in for the e-Boks servers, shaped after what the reference client
  # (Net::Eboks) sends and expects. It checks the login signature against the
  # registered public key and enforces the rotating nonce.

  import Plug.Conn

  @password "s3cret&\"pw"
  def password, do: @password

  def start(device, opts \\ []) do
    {:ok, agent} =
      Agent.start_link(fn ->
        %{
          device: device,
          accepted_hash: opts[:accepted_hash] || :sha,
          nonce: nil,
          counter: 0,
          logins: 0,
          attempts: 0,
          expire_next: false,
          registered: nil
        }
      end)

    Req.Test.stub(Ebox, &call(&1, agent))
    agent
  end

  def get(agent, key), do: Agent.get(agent, &Map.fetch!(&1, key))
  def expire_session(agent), do: Agent.update(agent, &%{&1 | expire_next: true})

  defp call(%{host: "rest.e-boks.dk"} = conn, agent) do
    "/mobile/1/xml.svc/en-gb" <> path = conn.request_path
    mail(conn.method, String.split(path, "/", trim: true), conn, agent)
  end

  defp call(%{host: host} = conn, agent), do: activation(host, conn.request_path, conn, agent)

  ## Mail API

  defp mail("PUT", ["session"], conn, agent) do
    state = Agent.get(agent, & &1)
    [header] = get_req_header(conn, "x-eboks-authenticate")

    [_, device_id, datetime, challenge] =
      Regex.run(~r/^logon deviceid="(.*?)",datetime="(.*?)",challenge="(.*?)"$/, header)

    {:ok, body, conn} = read_body(conn)
    {:ok, doc} = Ebox.XML.parse(body)
    %{attrs: user} = Ebox.XML.find(doc, "User")

    signed = "EBOKS:#{device_id}:P:#{user["identity"]}:DK:#{user["pincode"]}:#{datetime}"
    key = state.device.private_key
    public = {:RSAPublicKey, elem(key, 2), elem(key, 3)}

    valid? =
      device_id == state.device.id and user["pincode"] == @password and
        :public_key.verify(signed, state.accepted_hash, Base.decode64!(challenge), public)

    if valid? do
      Agent.update(agent, &%{&1 | logins: &1.logins + 1})

      conn
      |> rotate(agent)
      |> xml(
        ~s(<Session xmlns="urn:eboks:mobile:1.0.0"><User userId="1234" name="Søren Ærø"/></Session>)
      )
    else
      Agent.update(agent, &%{&1 | attempts: &1.attempts + 1})
      fail(conn, 400, "10130", "Pincode not accepted.")
    end
  end

  defp mail("GET", ["1234" | rest], conn, agent) do
    state = Agent.get(agent, & &1)
    [header] = get_req_header(conn, "x-eboks-authenticate")
    [_, nonce] = Regex.run(~r/nonce="(.*?)",sessionid="sid"/, header)

    cond do
      state.expire_next ->
        Agent.update(agent, &%{&1 | expire_next: false, nonce: nil})
        fail(conn, 403, "10105", "Unauthorized")

      nonce != state.nonce ->
        fail(conn, 403, "10105", "Unauthorized")

      true ->
        conn |> rotate(agent) |> resource(rest, fetch_query_params(conn).query_params)
    end
  end

  defp resource(conn, ["0", "shares"], %{"listType" => "active"}) do
    xml(conn, ~s(<Shares><Share name="Firma ApS" userId="77"/></Shares>))
  end

  defp resource(conn, [_share, "mail", "folders"], _) do
    # Latin-1 on the wire, with a declaration, as the real service has been seen to do.
    body =
      ~s(<?xml version="1.0" encoding="iso-8859-1"?><FolderInfos xmlns="urn:eboks:mobile:1.0.0">) <>
        ~s(<FolderInfo id="10" name="Inbox" unread="1"/>) <>
        ~s(<FolderInfo id="20" name="Arkiv"><FolderInfo id="21" name="Skat & Løn"/></FolderInfo>) <>
        ~s(</FolderInfos>)

    body = String.replace(body, "&", "&amp;")
    xml(conn, :unicode.characters_to_binary(body, :utf8, :latin1))
  end

  defp resource(conn, [_share, "mail", "folder", "10"], %{"skip" => skip, "take" => take}) do
    total = 5
    ids = Enum.slice(1..total, String.to_integer(skip), String.to_integer(take))

    infos =
      Enum.map_join(ids, fn id ->
        ~s(<MessageInfo id="m#{id}" name="Årsopgørelse #{id}" format="PDF" unread="#{id == 1}" ) <>
          ~s(receivedDateTime="2026-03-0#{id}T08:30:00"><Sender id="9">Skat/Told</Sender></MessageInfo>)
      end)

    xml(conn, ~s(<Folder xmlns="urn:eboks:mobile:1.0.0"><Messages>#{infos}</Messages></Folder>))
  end

  defp resource(conn, [_share, "mail", "folder", "10", "message", "m1"], _) do
    xml(
      conn,
      ~s(<Message xmlns="urn:eboks:mobile:1.0.0" id="m1" name="Årsopgørelse 1" format="PDF" ) <>
        ~s(receivedDateTime="2026-03-01T08:30:00"><Sender>Skat/Told</Sender><Attachements>) <>
        ~s(<AttachmentInfo id="a1" name="Bilag" format="PLAIN"/></Attachements></Message>)
    )
  end

  defp resource(conn, [_share, "mail", "folder", "10", "message", id, "content"], _) do
    conn
    |> put_resp_content_type("application/octet-stream")
    |> send_resp(200, "content of #{id}")
  end

  defp resource(conn, [_share, "mail", "folder", "10", "message", _], _) do
    xml(conn, ~s(<Message id="x" name="x" format="PDF"/>))
  end

  defp rotate(conn, agent) do
    nonce =
      Agent.get_and_update(agent, fn state ->
        nonce = "nonce#{state.counter + 1}"
        {nonce, %{state | counter: state.counter + 1, nonce: nonce}}
      end)

    put_resp_header(conn, "x-eboks-authenticate", ~s(sessionid="sid", nonce="#{nonce}"))
  end

  # Error shape and codes as observed from the real service.
  defp fail(conn, status, code, text) do
    conn
    |> put_resp_content_type("application/xml")
    |> send_resp(
      status,
      ~s(<Error xmlns="urn:eboks:mobile:1.0.0"><ErrorCode>#{code}</ErrorCode>) <>
        ~s(<ErrorIdentifier>x</ErrorIdentifier><ErrorText>#{text}</ErrorText></Error>)
    )
  end

  defp xml(conn, body) do
    conn |> put_resp_content_type("application/xml") |> send_resp(200, body)
  end

  ## Activation

  defp activation("digitalpost.dk", "/auth/oauth/token", conn, agent) do
    params = fetch_query_params(conn).query_params
    ["Basic " <> basic] = get_req_header(conn, "authorization")
    "e-boks-mobile:" <> _ = Base.decode64!(basic)
    challenge = Agent.get(agent, & &1[:code_challenge])

    ok? =
      params["grant_type"] == "authorization_code" and params["code"] == "the-code" and
        params["redirect_uri"] == "eboksdk://ngdpoidc/callback" and
        Base.url_encode64(:crypto.hash(:sha256, params["code_verifier"]), padding: false) ==
          challenge

    if ok?, do: Req.Test.json(conn, %{access_token: "dp-token"}), else: send_resp(conn, 400, "")
  end

  defp activation("digitalpostproxy.e-boks.dk", "/loginservice/v2/connect/usertoken", conn, _) do
    ["Bearer dp-token"] = get_req_header(conn, "authorization")
    ["LoginService_UserToken"] = get_req_header(conn, "x-operation-id")
    Req.Test.json(conn, %{userToken: "user-token"})
  end

  defp activation("oauth-dk.e-boks.com", "/1/connect/token", conn, agent) do
    {:ok, body, conn} = read_body(conn)
    form = URI.decode_query(body)
    device = Agent.get(agent, & &1.device)

    %{
      "usertoken" => "user-token",
      "grant_type" => "usertoken",
      "scope" => "mobileapi offline_access"
    } =
      form

    true = form["deviceid"] == device.id
    Req.Test.json(conn, %{access_token: "eb-token"})
  end

  defp activation("mobile-api-dk.e-boks.com", path, conn, agent) do
    ["Bearer eb-token"] = get_req_header(conn, "authorization")
    {:ok, body, conn} = read_body(conn)

    case {conn.method, path} do
      {"POST", "/2/user/mobileaccess/password/verify"} ->
        if URI.decode_query(body) == %{"password" => @password} do
          send_resp(conn, 204, "")
        else
          conn
          |> put_status(400)
          |> Req.Test.json(%{description: %{text: "Wrong password"}})
        end

      {"GET", "/2/user/profile"} ->
        Req.Test.json(conn, %{identity: "0101901234", name: "Søren Ærø"})

      {"PUT", "/2/user/current/device"} ->
        Agent.update(agent, &%{&1 | registered: JSON.decode!(body)})
        send_resp(conn, 204, "")
    end
  end

  def expect_code_challenge(agent, url) do
    %{"code_challenge" => challenge} = URI.decode_query(URI.parse(url).query)
    Agent.update(agent, &Map.put(&1, :code_challenge, challenge))
  end
end
