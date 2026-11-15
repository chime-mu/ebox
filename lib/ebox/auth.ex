defmodule Ebox.Auth do
  @moduledoc """
  One-time device activation with MitID.

  e-Boks only lets a device log in after its public key has been registered on
  your account, and registering requires a MitID login. The flow is:

    1. `start/1` builds a Digital Post login URL (OAuth with PKCE).
    2. You open it in a browser and approve with MitID. The login ends in a
       redirect to `eboksdk://ngdpoidc/callback?code=...`, which only the mobile
       app can open, so you copy that URL from the browser instead.
    3. `activate/4` trades the code for tokens, checks your mobile-access
       password, reads your CPR number from your profile and uploads the
       device's public key.

  The Digital Post tokens from step 3 are stored (`Ebox.DigitalPost`), and from
  then on `eboks_token/2` turns them into e-Boks tokens for the registered
  device, without MitID or password, until you remove the device under
  *Menu → Mobiladgang* on e-boks.dk. `mix ebox.auth` drives all of this
  interactively. See `docs/how-it-connects.md` for the whole picture.
  """

  alias Ebox.{Device, Error}

  @redirect_uri "eboksdk://ngdpoidc/callback"
  @authorize_url "https://gateway.digitalpost.dk/auth/oauth/authorize"
  @token_url "https://digitalpost.dk/auth/oauth/token"
  @usertoken_url "https://digitalpostproxy.e-boks.dk/loginservice/v2/connect/usertoken"
  @eboks_token_url "https://oauth-dk.e-boks.com/1/connect/token"
  @mobile_api "https://mobile-api-dk.e-boks.com/2"

  # Client credentials of the official e-Boks mobile app. They identify the app,
  # not you, and are the same for everybody.
  @digitalpost_client "e-boks-mobile"
  @digitalpost_secret "y0vKRKoVvqO%N3HBDK0T5bbzqo_eZsI0"
  @eboks_client "MobileApp-Short-Custom-id"
  @eboks_secret "QmaENW6MeYwwjzF5"

  defstruct [:url, :state, :code_verifier]

  @type t :: %__MODULE__{url: String.t(), state: String.t(), code_verifier: String.t()}

  @doc "Starts a login attempt: returns the URL to open plus the secrets to finish it."
  @spec start(Device.t()) :: t()
  def start(%Device{} = device) do
    state = random(24)
    code_verifier = random(64)
    code_challenge = Base.url_encode64(:crypto.hash(:sha256, code_verifier), padding: false)

    query =
      URI.encode_query(
        idp: "nemloginEboksRealm",
        client_id: @digitalpost_client,
        response_type: "code",
        scope: "openid",
        state: state,
        code_challenge: code_challenge,
        code_challenge_method: "S256",
        response_mode: "query",
        nonce: random(64),
        redirect_uri: @redirect_uri,
        deviceName: "ebox-elixir",
        deviceId: device.id
      )

    %__MODULE__{url: @authorize_url <> "?" <> query, state: state, code_verifier: code_verifier}
  end

  @doc """
  Extracts the authorization code from what the user pasted: the full
  `eboksdk://...` callback URL, or just the code itself.
  """
  @spec parse_callback(t(), String.t()) :: {:ok, String.t()} | {:error, Error.t()}
  def parse_callback(%__MODULE__{state: state}, input) do
    input = String.trim(input)

    case URI.parse(input) do
      %URI{query: query} when is_binary(query) ->
        case URI.decode_query(query) do
          %{"error" => error} = params ->
            {:error,
             Error.new(:callback, "login was refused: #{params["error_description"] || error}")}

          %{"code" => _, "state" => other} when other != state ->
            {:error, Error.new(:callback, "that callback belongs to a different login attempt")}

          %{"code" => code} ->
            {:ok, code}

          _ ->
            {:error, Error.new(:callback, "no code found in the pasted URL")}
        end

      _ when input != "" ->
        if String.contains?(input, [" ", "/"]),
          do: {:error, Error.new(:callback, "no code found in the pasted text")},
          else: {:ok, input}

      _ ->
        {:error, Error.new(:callback, "nothing was pasted")}
    end
  end

  @doc """
  Finishes activation. Returns the device with `cpr`, `name` and
  `activated: true` set, plus the Digital Post tokens the MitID login yielded,
  which `Ebox.DigitalPost` uses to read mail from public authorities. The caller
  is responsible for `Ebox.Device.save/1` and `Ebox.DigitalPost.save_tokens/2`.
  """
  @spec activate(t(), String.t(), Device.t(), String.t()) ::
          {:ok, Device.t(), map()} | {:error, Error.t()}
  def activate(%__MODULE__{} = auth, code, %Device{} = device, password) do
    with {:ok, %{"access_token" => digitalpost_token} = digitalpost} <- exchange_code(auth, code),
         {:ok, %{"access_token" => token}} <- eboks_token(digitalpost_token, device),
         {:ok, _} <-
           post(:verify_password, @mobile_api <> "/user/mobileaccess/password/verify",
             form: [password: password],
             auth: {:bearer, token}
           ),
         {:ok, %{"identity" => cpr} = profile} <-
           request(:profile, :get, @mobile_api <> "/user/profile", auth: {:bearer, token}),
         {:ok, _} <-
           request(:register_device, :put, @mobile_api <> "/user/current/device",
             auth: {:bearer, token},
             json: %{
               id: device.id,
               key: Device.public_key(device),
               name: "ebox-elixir",
               os: "elixir"
             }
           ) do
      {:ok, %{device | cpr: cpr, name: profile["name"], activated: true}, digitalpost}
    else
      {:error, %Error{}} = error ->
        error

      {:ok, unexpected} ->
        {:error,
         Error.new(:activate, "e-Boks answered in an unexpected format during activation",
           body: unexpected
         )}
    end
  end

  @doc """
  Trades a Digital Post access token for an e-Boks mobile API token (via an
  e-Boks user token). No MitID is involved, so a stored Digital Post login is
  enough to reach the mobile API (`#{@mobile_api}`).
  """
  @spec eboks_token(String.t(), Device.t()) :: {:ok, map()} | {:error, Error.t()}
  def eboks_token(digitalpost_token, %Device{} = device) do
    with {:ok, %{"userToken" => user_token}} <-
           post(:user_token, @usertoken_url,
             # The request has no content, but the server answers 411 to a POST
             # without Content-Length, and Req only sends one when there is a body.
             body: "",
             auth: {:bearer, digitalpost_token},
             headers: [
               {"content-length", "0"},
               {"x-operation-id", "LoginService_UserToken"},
               {"content-type", "application/json-patch+json"}
             ]
           ) do
      post(:eboks_token, @eboks_token_url,
        form: [
          usertoken: user_token,
          grant_type: "usertoken",
          scope: "mobileapi offline_access",
          client_id: @eboks_client,
          client_secret: @eboks_secret,
          deviceid: device.id
        ]
      )
    end
  end

  @doc false
  def mobile_api, do: @mobile_api

  @doc """
  Trades the code from a MitID login (`start/1`) for Digital Post tokens: an
  access token valid for 20 minutes and a refresh token to renew it.
  """
  @spec exchange_code(t(), String.t()) :: {:ok, map()} | {:error, Error.t()}
  def exchange_code(%__MODULE__{} = auth, code) do
    post(:digitalpost_token, @token_url,
      params: [
        grant_type: "authorization_code",
        redirect_uri: @redirect_uri,
        client_id: @digitalpost_client,
        code: code,
        code_verifier: auth.code_verifier
      ],
      auth: digitalpost_client_auth()
    )
  end

  @doc false
  # The token endpoint and client credentials, shared with Ebox.DigitalPost.
  def digitalpost_token_url, do: @token_url
  def digitalpost_client_id, do: @digitalpost_client
  def digitalpost_client_auth, do: {:basic, @digitalpost_client <> ":" <> @digitalpost_secret}

  defp post(step, url, options), do: request(step, :post, url, options)

  defp request(step, method, url, options) do
    case Req.request(Ebox.HTTP.new([method: method, url: url] ++ options)) do
      {:ok, %Req.Response{status: status, body: body}} when status in 200..299 -> {:ok, body}
      {:ok, resp} -> {:error, Error.from_response(step, resp)}
      {:error, exception} -> {:error, Error.from_exception(step, exception)}
    end
  end

  defp random(bytes), do: Base.url_encode64(:crypto.strong_rand_bytes(bytes), padding: false)
end
