defmodule Ebox.FakeActivation do
  @moduledoc false
  # A stand-in for the services `Ebox.Auth.activate/4` talks to during the
  # one-time device activation: the Digital Post token endpoint, e-Boks' user
  # token and OAuth endpoints, and the few mobile API calls activation makes.

  import Plug.Conn

  @password "s3cret&\"pw"
  def password, do: @password

  def start(device) do
    {:ok, agent} = Agent.start_link(fn -> %{device: device, registered: nil} end)
    Req.Test.stub(Ebox, &activation(&1.host, &1.request_path, &1, agent))
    agent
  end

  def get(agent, key), do: Agent.get(agent, &Map.fetch!(&1, key))

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

    if ok?,
      do:
        Req.Test.json(conn, %{
          access_token: "dp-token",
          refresh_token: "dp-refresh",
          expires_in: 1199
        }),
      else: send_resp(conn, 400, "")
  end

  defp activation("digitalpostproxy.e-boks.dk", "/loginservice/v2/connect/usertoken", conn, _) do
    ["Bearer dp-token"] = get_req_header(conn, "authorization")
    ["LoginService_UserToken"] = get_req_header(conn, "x-operation-id")

    # The real service answers 411 Length Required to a POST without a body.
    case get_req_header(conn, "content-length") do
      [_] -> Req.Test.json(conn, %{userToken: "user-token"})
      [] -> send_resp(conn, 411, "Length Required")
    end
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
