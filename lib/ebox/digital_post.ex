defmodule Ebox.DigitalPost do
  @moduledoc ~S"""
  Access to Digital Post: mail from public authorities ("Offentlig
  post") in your own mailbox and in mailboxes of companies you represent.

  This mail is not stored by e-Boks but in the state's central Digital Post
  system, which e-Boks, mit.dk and borger.dk display. The e-Boks mail API
  (`Ebox`) does not reach it. This module uses Digital Post's own REST API for
  view clients at `gateway.digitalpost.dk/apis/v1`, documented in the Agency for
  Digital Government's OpenAPI description, with the same login the e-Boks
  mobile app uses.

      {:ok, dp} = Ebox.DigitalPost.connect()
      [mine | _] = Ebox.DigitalPost.mailboxes(dp)
      {:ok, folders} = Ebox.DigitalPost.folders(dp, mine.id)
      inbox = Enum.find(folders, &(&1.type == "INBOX"))
      {:ok, [message | _]} = Ebox.DigitalPost.messages(dp, mine.id, folder: inbox.id)
      [file | _] = message.files
      {:ok, pdf} = Ebox.DigitalPost.content(dp, message, file)

  Reading never changes anything: messages stay unread, and nothing is marked
  as legally notified. `update/3` is the one call that changes a message
  (move it to another folder, mark it read or unread).

  ## Login

  The MitID login of `mix ebox.auth` yields Digital Post tokens as well
  (`mix ebox.digitalpost.auth` repeats just that part). They are stored in
  `digitalpost.json` next to the e-Boks device files, with mode `0600`: a
  20-minute access token and a refresh token that renews it without MitID.
  Whoever holds that file can read your Digital Post, so treat it like a
  password. To revoke it, delete the file.
  """

  use GenServer

  alias Ebox.{Auth, Device, Error}
  alias Ebox.DigitalPost.Message

  @api "https://gateway.digitalpost.dk/apis/v1"
  # Access tokens live 20 minutes; renew well before that.
  @renew_after 15 * 60
  @timeout 60_000
  @page_size 100

  @type dp :: GenServer.server()
  @type mailbox :: %{
          id: String.t(),
          owner_type: String.t(),
          owner_name: String.t() | nil,
          attrs: map()
        }
  @type folder :: %{
          id: String.t(),
          name: String.t(),
          type: String.t(),
          parent_id: String.t() | nil
        }

  ## Login and tokens

  @doc """
  Finishes a Digital Post login started with `Ebox.Auth.start/1`: takes the
  pasted callback and stores the tokens. Options: `:dir` (default
  `Ebox.Device.dir/0`).
  """
  @spec authorize(Auth.t(), String.t(), keyword()) :: :ok | {:error, Error.t()}
  def authorize(%Auth{} = auth, callback, opts \\ []) do
    with {:ok, code} <- Auth.parse_callback(auth, callback),
         {:ok, tokens} <- Auth.exchange_code(auth, code) do
      save_tokens(tokens, opts[:dir])
    end
  end

  @doc "Stores Digital Post tokens privately. Options: `:dir`."
  @spec save_tokens(map(), Path.t() | nil) :: :ok | {:error, Error.t()}
  def save_tokens(tokens, dir \\ nil)

  def save_tokens(%{"refresh_token" => _} = tokens, dir) do
    dir = dir || Device.dir()
    File.mkdir_p!(dir)
    File.chmod!(dir, 0o700)
    tokens = Map.put(tokens, "saved_at", DateTime.utc_now() |> DateTime.to_iso8601())
    # Write-then-rename: a crash never leaves a half-written file behind.
    partial = tokens_path(dir) <> ".part"
    Device.write_private!(partial, JSON.encode!(tokens))
    File.rename!(partial, tokens_path(dir))
  end

  def save_tokens(other, _dir),
    do:
      {:error,
       Error.new(:digitalpost_token, "no refresh token in the login response",
         body: Map.keys(other)
       )}

  @doc "Whether Digital Post tokens are stored. Options: `:dir`."
  @spec logged_in?(keyword()) :: boolean()
  def logged_in?(opts \\ []), do: File.exists?(tokens_path(opts[:dir]))

  @doc """
  Renews the stored login once, without reading mail. Running this regularly
  keeps a login alive if the refresh token expires when unused. Options: `:dir`.
  """
  @spec renew(keyword()) :: :ok | {:error, Error.t()}
  def renew(opts \\ []) do
    with {:ok, tokens} <- load_tokens(opts[:dir]),
         {:ok, _} <- renew_tokens(tokens, opts[:dir]),
         do: :ok
  end

  ## Connection

  @doc """
  Renews the stored login and returns a connection process.
  Options: `:dir` (where the tokens are stored), `:name`.
  """
  @spec connect(keyword()) :: {:ok, pid()} | {:error, Error.t()}
  def connect(opts \\ []) do
    case GenServer.start(__MODULE__, opts, Keyword.take(opts, [:name])) do
      {:ok, pid} -> {:ok, pid}
      {:error, %Error{} = error} -> {:error, error}
      {:error, reason} -> {:error, Error.new(:connect, inspect(reason))}
    end
  end

  @doc "Like `connect/1` but linked to the caller."
  def start_link(opts \\ []),
    do: GenServer.start_link(__MODULE__, opts, Keyword.take(opts, [:name]))

  @doc "Closes the connection. The stored login is kept."
  def disconnect(dp), do: GenServer.stop(dp)

  @doc """
  The mailboxes you can read: your own (`owner_type: "CITIZEN"`) first, then
  those of organisations you represent (`"ORGANISATION"`).
  """
  @spec mailboxes(dp) :: [mailbox()]
  def mailboxes(dp), do: GenServer.call(dp, :mailboxes, @timeout)

  @doc """
  A current Digital Post access token, renewed when needed. `Ebox.Eboks` trades
  it for an e-Boks token, so one stored login serves both services.
  """
  @spec access_token(dp) :: {:ok, String.t()} | {:error, Error.t()}
  def access_token(dp), do: GenServer.call(dp, :access_token, @timeout)

  @doc "Folders of a mailbox. `type` is Digital Post's folder type, such as `\"INBOX\"`."
  @spec folders(dp, String.t()) :: {:ok, [folder()]} | {:error, Error.t()}
  def folders(dp, mailbox_id), do: GenServer.call(dp, {:folders, mailbox_id}, @timeout)

  @doc """
  One page of messages in a mailbox, newest first.

  Options: `:folder` (a folder id; default all folders), `:page` (zero-based,
  default 0), `:size` (default #{@page_size}), `:received_from` (a `Date`, to
  fetch only newer mail).
  """
  @spec messages(dp, String.t(), keyword()) :: {:ok, [Message.t()]} | {:error, Error.t()}
  def messages(dp, mailbox_id, opts \\ []),
    do: GenServer.call(dp, {:messages, mailbox_id, opts}, @timeout)

  @doc "Every message matching `messages/3`'s options, page by page."
  @spec all_messages(dp, String.t(), keyword()) :: {:ok, [Message.t()]} | {:error, Error.t()}
  def all_messages(dp, mailbox_id, opts \\ []) do
    size = opts[:size] || @page_size

    0
    |> Stream.iterate(&(&1 + 1))
    |> Enum.reduce_while({:ok, []}, fn page, {:ok, acc} ->
      case messages(dp, mailbox_id, Keyword.merge(opts, page: page, size: size)) do
        {:ok, batch} when length(batch) < size -> {:halt, {:ok, acc ++ batch}}
        {:ok, batch} -> {:cont, {:ok, acc ++ batch}}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  @doc "Downloads one file of a message."
  @spec content(dp, Message.t(), Message.File.t()) :: {:ok, binary()} | {:error, Error.t()}
  def content(dp, %Message{} = message, %Message.File{} = file),
    do: GenServer.call(dp, {:content, message, file}, @timeout)

  @doc "One message, fresh from the service (with its current `version` in `attrs`)."
  @spec message(dp, String.t(), String.t()) :: {:ok, Message.t()} | {:error, Error.t()}
  def message(dp, mailbox_id, id), do: GenServer.call(dp, {:message, mailbox_id, id}, @timeout)

  @doc """
  Changes a message: `patch` holds any of `"folderId"` (move), `"read"`,
  `"flag"`, `"note"`. The message's current version is fetched first and sent
  as `If-Match`, so a change never overwrites one made elsewhere in between.
  Returns the updated message.
  """
  @spec update(dp, String.t(), String.t(), map()) :: {:ok, Message.t()} | {:error, Error.t()}
  def update(dp, mailbox_id, id, patch) when is_map(patch) do
    with {:ok, current} <- message(dp, mailbox_id, id),
         do:
           GenServer.call(
             dp,
             {:update, mailbox_id, id, current.attrs["version"], patch},
             @timeout
           )
  end

  ## GenServer

  @impl true
  def init(opts) do
    with {:ok, tokens} <- load_tokens(opts[:dir]),
         {:ok, tokens} <- renew_tokens(tokens, opts[:dir]),
         state = %{dir: opts[:dir], tokens: tokens, renewed_at: now(), mailboxes: []},
         {:ok, mailboxes} <- run(:fetch_mailboxes, state) do
      {:ok, %{state | mailboxes: mailboxes}}
    else
      {:error, error} -> {:stop, error}
    end
  end

  @impl true
  def handle_call(:mailboxes, _from, state), do: {:reply, state.mailboxes, state}

  def handle_call(:access_token, _from, state) do
    case keep_alive(state) do
      {:ok, state} -> {:reply, {:ok, state.tokens["access_token"]}, state}
      {:error, error} -> {:reply, {:error, error}, state}
    end
  end

  def handle_call(request, _from, state) do
    with {:ok, state} <- keep_alive(state) do
      case run(request, state) do
        {:error, %Error{status: 401}} ->
          # The access token can be revoked early; renew once and retry.
          with {:ok, state} <- keep_alive(%{state | renewed_at: :never}),
               {:ok, result} <- run(request, state) do
            {:reply, {:ok, result}, state}
          else
            {:error, error} -> {:reply, {:error, error}, state}
          end

        {:ok, result} ->
          {:reply, {:ok, result}, state}

        {:error, error} ->
          {:reply, {:error, error}, state}
      end
    else
      {:error, error} -> {:reply, {:error, error}, state}
    end
  end

  # Keeps the tokens out of crash reports and :sys.get_status/1.
  @impl true
  def format_status(status) do
    Map.update(status, :state, nil, fn
      %{tokens: _} = state -> %{state | tokens: "[redacted]"}
      other -> other
    end)
  end

  defp keep_alive(state) do
    if state.renewed_at != :never and now() - state.renewed_at < @renew_after do
      {:ok, state}
    else
      with {:ok, tokens} <- renew_tokens(state.tokens, state.dir),
           do: {:ok, %{state | tokens: tokens, renewed_at: now()}}
    end
  end

  defp run(:fetch_mailboxes, state) do
    with {:ok, %{"mailboxes" => list}} when is_list(list) <-
           get(:mailboxes, "/mailboxes/", [], state) do
      mailboxes =
        list
        |> Enum.map(
          &%{id: &1["id"], owner_type: &1["ownerType"], owner_name: &1["ownerName"], attrs: &1}
        )
        |> Enum.sort_by(&if(&1.owner_type == "CITIZEN", do: 0, else: 1))

      {:ok, mailboxes}
    else
      {:ok, other} -> {:error, unexpected(:mailboxes, other)}
      error -> error
    end
  end

  defp run({:folders, mailbox_id}, state) do
    with {:ok, %{"folders" => list}} when is_list(list) <-
           get(:folders, "/mailboxes/#{mailbox_id}/folders/", [size: 1000], state) do
      {:ok,
       Enum.map(
         list,
         &%{
           id: &1["id"],
           name: &1["name"],
           type: &1["folderType"],
           parent_id: &1["parentFolderId"]
         }
       )}
    else
      {:ok, other} -> {:error, unexpected(:folders, other)}
      error -> error
    end
  end

  defp run({:messages, mailbox_id, opts}, state) do
    params =
      [
        page: opts[:page] || 0,
        size: opts[:size] || @page_size,
        sortFields: "receivedDateTime:desc"
      ] ++
        if(opts[:folder], do: [folderId: opts[:folder]], else: []) ++
        if(opts[:received_from],
          do: [receivedDateFrom: Date.to_iso8601(opts[:received_from])],
          else: []
        )

    with {:ok, %{"messages" => list}} when is_list(list) <-
           get(:messages, "/mailboxes/#{mailbox_id}/messages/", params, state) do
      {:ok, Enum.map(list, &Message.from_json/1)}
    else
      {:ok, other} -> {:error, unexpected(:messages, other)}
      error -> error
    end
  end

  defp run({:content, message, file}, state) do
    path =
      "/mailboxes/#{message.mailbox_id}/messages/#{message.id}" <>
        "/documents/#{file.document_id}/files/#{file.id}/content"

    request(:content, path, [], state, decode_body: false)
  end

  defp run({:message, mailbox_id, id}, state) do
    case get(:message, "/mailboxes/#{mailbox_id}/messages/#{id}", [], state) do
      {:ok, %{"id" => _} = json} -> {:ok, Message.from_json(json)}
      {:ok, other} -> {:error, unexpected(:message, other)}
      error -> error
    end
  end

  defp run({:update, mailbox_id, id, version, patch}, state) do
    options = [
      method: :patch,
      json: patch,
      headers: [{"if-match", to_string(version)}],
      retry: false
    ]

    case request(:update, "/mailboxes/#{mailbox_id}/messages/#{id}", [], state, options) do
      {:ok, %{"id" => _} = json} -> {:ok, Message.from_json(json)}
      {:ok, _} -> message_after_update(mailbox_id, id, state)
      error -> error
    end
  end

  defp get(step, path, params, state), do: request(step, path, params, state, [])

  defp message_after_update(mailbox_id, id, state), do: run({:message, mailbox_id, id}, state)

  defp request(step, path, params, state, options) do
    req =
      Ebox.HTTP.new(
        [
          method: :get,
          url: @api <> path,
          params: params,
          auth: {:bearer, state.tokens["access_token"]},
          # Digital Post rate-limits (429) bulk downloads; back off and retry,
          # honouring Retry-After. Writes pass retry: false.
          retry: :safe_transient,
          max_retries: 6
        ]
        |> Keyword.merge(options)
      )

    case Req.request(req) do
      {:ok, %Req.Response{status: status, body: body}} when status in 200..299 -> {:ok, body}
      {:ok, resp} -> {:error, Error.from_response(step, resp)}
      {:error, exception} -> {:error, Error.from_exception(step, exception)}
    end
  end

  ## Token storage and renewal

  defp renew_tokens(tokens, dir) do
    req =
      Ebox.HTTP.new(
        method: :post,
        url: Auth.digitalpost_token_url(),
        form: [
          grant_type: "refresh_token",
          refresh_token: tokens["refresh_token"],
          client_id: Auth.digitalpost_client_id()
        ],
        auth: Auth.digitalpost_client_auth()
      )

    case Req.request(req) do
      {:ok, %Req.Response{status: 200, body: %{"access_token" => _} = renewed}} ->
        # Keep the old refresh token if the server did not send a new one.
        renewed = Map.put_new(renewed, "refresh_token", tokens["refresh_token"])
        with :ok <- save_tokens(renewed, dir), do: {:ok, renewed}

      {:ok, %Req.Response{status: status} = resp} when status in [400, 401] ->
        error = Error.from_response(:renew, resp)

        {:error,
         %{
           error
           | message: error.message <> " (the login has expired; run mix ebox.digitalpost.auth)"
         }}

      {:ok, resp} ->
        {:error, Error.from_response(:renew, resp)}

      {:error, exception} ->
        {:error, Error.from_exception(:renew, exception)}
    end
  end

  defp tokens_path(dir), do: Path.join(dir || Device.dir(), "digitalpost.json")

  defp load_tokens(dir) do
    case File.read(tokens_path(dir)) do
      {:ok, json} ->
        case JSON.decode(json) do
          {:ok, %{"refresh_token" => _} = tokens} -> {:ok, tokens}
          _ -> {:error, Error.new(:connect, "#{tokens_path(dir)} is not a Digital Post login")}
        end

      {:error, :enoent} ->
        {:error,
         Error.new(:connect, "not logged in to Digital Post; run mix ebox.digitalpost.auth")}

      {:error, reason} ->
        {:error, Error.new(:connect, "cannot read #{tokens_path(dir)}: #{inspect(reason)}")}
    end
  end

  defp unexpected(step, body),
    do: Error.new(step, "Digital Post answered #{step} in an unexpected format", body: body)

  defp now, do: System.monotonic_time(:second)
end
