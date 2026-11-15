defmodule Ebox.Session do
  @moduledoc """
  Functional core of the connector: one logged-in session against the e-Boks
  mobile API (`rest.e-boks.dk/mobile/1/xml.svc`).

  Every request returns an updated session, because the server hands out a new
  nonce with each response. Most callers want the `Ebox` process wrapper instead,
  which threads that state for you.
  """

  alias Ebox.{Device, Error, XML}

  @base_url "https://rest.e-boks.dk/mobile/1/xml.svc/en-gb"

  # The mobile protocol defines a per-request response hash, but the server only
  # checks session id and nonce; every known client sends this constant.
  @response "3a1a51f235a8bd6bbc29b2caef986a1aeb77018d60ffdad9c5e31117e7b6ead3"

  @derive {Inspect, except: [:password, :device]}
  defstruct [:device, :password, :user_id, :name, :session_id, :nonce]

  @type t :: %__MODULE__{}

  @doc """
  Logs in with an activated device and the mobile-access password.

  Which hash the server expects in the login signature is not documented, and
  the reference client's choice depends on the crypto library it was built
  against. So while `device.sig_hash` is still `nil`, SHA-1 is tried first and
  SHA-256 second; the one that worked is in `session.device.sig_hash` and should
  be saved so later logins make a single attempt.
  """
  @spec login(Device.t(), String.t()) :: {:ok, t()} | {:error, Error.t()}
  def login(%Device{cpr: cpr, sig_hash: nil} = device, password)
      when is_binary(cpr) and is_binary(password) do
    case do_login(%{device | sig_hash: :sha}, password) do
      {:error, %Error{status: status}} = first when status in 400..499 ->
        with {:error, _} <- do_login(%{device | sig_hash: :sha256}, password), do: first

      result ->
        result
    end
  end

  def login(%Device{cpr: cpr} = device, password) when is_binary(cpr) and is_binary(password) do
    do_login(device, password)
  end

  def login(%Device{}, _password) do
    {:error, Error.new(:login, "device is not activated yet, run `mix ebox.auth` first")}
  end

  defp do_login(device, password) do
    datetime = Calendar.strftime(DateTime.utc_now(), "%Y-%m-%d %H:%M:%SZ")
    signed = Enum.join(["EBOKS", device.id, "P", device.cpr, "DK", password, datetime], ":")
    challenge = Device.sign(device, signed, device.sig_hash)

    body = """
    <Logon xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" \
    xmlns:xsd="http://www.w3.org/2001/XMLSchema" xmlns="urn:eboks:mobile:1.0.0">
    <App version="0.1.0" os="elixir" osVersion="1" Device="ebox-elixir"/>
    <User identity="#{XML.escape(device.cpr)}" identityType="P" nationality="DK" \
    pincode="#{XML.escape(password)}"/>
    </Logon>
    """

    auth = ~s(logon deviceid="#{device.id}",datetime="#{datetime}",challenge="#{challenge}")
    session = %__MODULE__{device: device, password: password}

    with {:ok, body, session} <-
           send_request(session, :login, :put, "/session", auth,
             body: body,
             headers: [{"content-type", "application/xml"}]
           ),
         {:ok, doc} <- parse(:login, body),
         %{attrs: %{"userId" => user_id} = attrs} <- XML.find(doc, "User") do
      {:ok, %{session | user_id: user_id, name: attrs["name"]}}
    else
      {:error, %Error{}} = error -> error
      _ -> {:error, Error.new(:login, "login response did not contain a user")}
    end
  end

  @doc "Mailboxes other people or companies have shared with you."
  def shares(%__MODULE__{} = session) do
    with {:ok, doc, session} <-
           get_xml(session, :shares, "/#{session.user_id}/0/shares?listType=active") do
      shares =
        for %{attrs: attrs} <- XML.descendants(doc, "Share") do
          %{id: attrs["userId"], name: attrs["name"], attrs: attrs}
        end

      {:ok, shares, session}
    end
  end

  @doc "Folders of a mailbox, flattened; subfolders carry their `parent_id`."
  def folders(%__MODULE__{} = session, share_id \\ "0") do
    with {:ok, doc, session} <-
           get_xml(session, :folders, mail_path(session, share_id, "folders")) do
      {:ok, collect_folders(doc, nil), session}
    end
  end

  defp collect_folders(node, parent_id) do
    Enum.flat_map(XML.children(node, "FolderInfo"), fn %{attrs: attrs} = folder ->
      entry = %{id: attrs["id"], name: attrs["name"], parent_id: parent_id, attrs: attrs}
      [entry | collect_folders(folder, attrs["id"])]
    end)
  end

  @doc """
  One page of messages in a folder.

  Options: `:share` (default `"0"`, your own mailbox), `:skip` (default 0) and
  `:take` (default 100).
  """
  def messages(%__MODULE__{} = session, folder_id, opts \\ []) do
    share_id = to_string(opts[:share] || "0")
    query = "?skip=#{opts[:skip] || 0}&take=#{opts[:take] || 100}"
    path = mail_path(session, share_id, "folder/#{folder_id}") <> query

    with {:ok, doc, session} <- get_xml(session, :messages, path) do
      messages =
        doc
        |> XML.descendants("MessageInfo")
        |> Enum.map(&Ebox.Message.from_xml(&1, share_id, to_string(folder_id)))

      {:ok, messages, session}
    end
  end

  @doc "Full details of a message, including its attachment list."
  def message(%__MODULE__{} = session, %Ebox.Message{} = message) do
    path =
      mail_path(session, message.share_id, "folder/#{message.folder_id}/message/#{message.id}")

    with {:ok, doc, session} <- get_xml(session, :message, path) do
      {:ok, Ebox.Message.from_xml(doc, message.share_id, message.folder_id), session}
    end
  end

  @doc """
  Downloads the document of a message, or one of its attachments, as a binary.
  """
  def content(%__MODULE__{} = session, %Ebox.Message{} = message, attachment \\ nil) do
    content_id = if attachment, do: attachment.id, else: message.id

    path =
      mail_path(
        session,
        message.share_id,
        "folder/#{message.folder_id}/message/#{content_id}/content"
      )

    send_request(session, :content, :get, path, auth_header(session))
  end

  defp mail_path(session, share_id, rest), do: "/#{session.user_id}/#{share_id}/mail/#{rest}"

  defp get_xml(session, step, path) do
    with {:ok, body, session} <- send_request(session, step, :get, path, auth_header(session)),
         {:ok, doc} <- parse(step, body) do
      {:ok, doc, session}
    end
  end

  defp auth_header(session) do
    ~s(deviceid="#{session.device.id}",nonce="#{session.nonce}",) <>
      ~s(sessionid="#{session.session_id}",response="#{@response}")
  end

  defp send_request(session, step, method, path, auth, options \\ []) do
    {headers, options} = Keyword.pop(options, :headers, [])

    request =
      Ebox.HTTP.new(
        [
          method: method,
          url: @base_url <> path,
          decode_body: false,
          headers:
            [
              {"x-eboks-authenticate", auth},
              {"accept", "*/*"},
              {"accept-language", "en-US"}
            ] ++ headers
        ] ++ options
      )

    case Req.request(request) do
      {:ok, %Req.Response{status: status} = resp} when status in 200..299 ->
        {:ok, resp.body, update_tokens(session, resp)}

      {:ok, resp} ->
        {:error, Error.from_response(step, resp)}

      {:error, exception} ->
        {:error, Error.from_exception(step, exception)}
    end
  end

  # x-eboks-authenticate: sessionid="...",nonce="..."
  defp update_tokens(session, resp) do
    tokens =
      resp
      |> Req.Response.get_header("x-eboks-authenticate")
      |> Enum.flat_map(&Regex.scan(~r/(sessionid|nonce)="(.*?)"/, &1, capture: :all_but_first))
      |> Map.new(fn [key, value] -> {key, value} end)

    %{
      session
      | session_id: tokens["sessionid"] || session.session_id,
        nonce: tokens["nonce"] || session.nonce
    }
  end

  defp parse(step, body) do
    case XML.parse(body) do
      {:ok, doc} -> {:ok, doc}
      {:error, _} -> {:error, Error.new(step, "#{step} returned unreadable XML", body: body)}
    end
  end
end
