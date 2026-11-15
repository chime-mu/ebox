defmodule Ebox.Eboks do
  @moduledoc ~S"""
  e-Boks mail ("Post fra virksomheder"), through the JSON API the e-Boks mobile
  app uses (`mobile-api-dk.e-boks.com/2`).

      {:ok, dp} = Ebox.DigitalPost.connect()
      {:ok, eb} = Ebox.Eboks.connect(digitalpost: dp)
      [mine | _shared] = Ebox.Eboks.mailboxes(eb)
      {:ok, folders} = Ebox.Eboks.folders(eb, mine)
      {:ok, messages} = Ebox.Eboks.all_messages(eb, mine, hd(folders).id)

  ## Login

  No password and no MitID: the stored Digital Post login (`Ebox.DigitalPost`)
  is traded for a short-lived e-Boks token together with the device registered
  by `mix ebox.auth` (see `Ebox.Auth.eboks_token/2`). The token is renewed as
  needed.

  ## Mailboxes

  Your own mailbox, then every mailbox shared with you and accepted, such as a
  company's e-Boks shared to your CPR number under Indstillinger > Adgange.
  Every call takes the mailbox it is about.

  ## Read state

  Downloading a document (`content/4`) marks the message read in e-Boks;
  listing and `message/3` do not. `update/4` changes it back.
  """

  use GenServer

  alias Ebox.{Auth, Device, DigitalPost, Error}
  alias Ebox.Eboks.Message

  @timeout 60_000
  @page_size 100
  # e-Boks tokens live 300 seconds; renew before that.
  @renew_after 240

  @type eb :: GenServer.server()
  @type mailbox :: %{
          id: String.t(),
          user_id: integer() | nil,
          name: String.t() | nil,
          own: boolean(),
          permission: String.t() | nil
        }
  @type folder :: %{
          id: String.t(),
          name: String.t(),
          type: String.t(),
          parent_id: String.t() | nil
        }

  @doc """
  Logs in and returns a connection process. Options: `:digitalpost` (a
  connection from `Ebox.DigitalPost.connect/1`; by default one is opened),
  `:dir` (where the login and device are stored), `:name`.
  """
  @spec connect(keyword()) :: {:ok, pid()} | {:error, Error.t()}
  def connect(opts \\ []) do
    case GenServer.start(__MODULE__, opts, Keyword.take(opts, [:name])) do
      {:ok, pid} -> {:ok, pid}
      {:error, %Error{} = error} -> {:error, error}
      {:error, reason} -> {:error, Error.new(:connect, inspect(reason))}
    end
  end

  @doc "Closes the connection."
  def disconnect(eb), do: GenServer.stop(eb)

  @doc "Your own mailbox (`own: true`) first, then accepted shares."
  @spec mailboxes(eb) :: [mailbox()]
  def mailboxes(eb), do: GenServer.call(eb, :mailboxes, @timeout)

  @doc "Folders of a mailbox, flattened; subfolders carry their `parent_id`."
  @spec folders(eb, mailbox()) :: {:ok, [folder()]} | {:error, Error.t()}
  def folders(eb, mailbox), do: GenServer.call(eb, {:folders, mailbox}, @timeout)

  @doc "One page of messages in a folder. Options: `:offset` (default 0), `:limit`."
  @spec messages(eb, mailbox(), String.t(), keyword()) ::
          {:ok, %{messages: [Message.t()], total: non_neg_integer()}} | {:error, Error.t()}
  def messages(eb, mailbox, folder_id, opts \\ []),
    do: GenServer.call(eb, {:messages, mailbox, to_string(folder_id), opts}, @timeout)

  @doc "Every message in a folder, page by page."
  @spec all_messages(eb, mailbox(), String.t()) :: {:ok, [Message.t()]} | {:error, Error.t()}
  def all_messages(eb, mailbox, folder_id) do
    Stream.iterate(0, &(&1 + @page_size))
    |> Enum.reduce_while({:ok, []}, fn offset, {:ok, acc} ->
      case messages(eb, mailbox, folder_id, offset: offset, limit: @page_size) do
        {:ok, %{messages: batch, total: total}} ->
          acc = acc ++ batch

          if batch == [] or length(acc) >= total,
            do: {:halt, {:ok, acc}},
            else: {:cont, {:ok, acc}}

        {:error, _} = error ->
          {:halt, error}
      end
    end)
  end

  @doc "Full details of a message, including its attachments. Leaves it unread."
  @spec message(eb, mailbox(), Message.t()) :: {:ok, Message.t()} | {:error, Error.t()}
  def message(eb, mailbox, %Message{} = message),
    do: GenServer.call(eb, {:message, mailbox, message}, @timeout)

  @doc "Downloads the letter or an attachment. Marks the message read in e-Boks."
  @spec content(eb, mailbox(), Message.t(), Message.File.t()) ::
          {:ok, binary()} | {:error, Error.t()}
  def content(eb, mailbox, %Message{} = message, %Message.File{} = file),
    do: GenServer.call(eb, {:content, mailbox, message, file}, @timeout)

  @doc """
  Changes a message: `%{unread: true | false}`, `%{folderId: id}` (moves it),
  also `flag` and `note`.
  """
  @spec update(eb, mailbox(), Message.t(), map()) :: :ok | {:error, Error.t()}
  def update(eb, mailbox, %Message{} = message, patch) when is_map(patch),
    do: GenServer.call(eb, {:update, mailbox, message, patch}, @timeout)

  ## GenServer

  @impl true
  def init(opts) do
    with {:ok, dp} <- digitalpost(opts),
         {:ok, device} <- device(opts),
         state = %{dp: dp, device: device, token: nil, renewed_at: :never, mailboxes: []},
         {:ok, state} <- keep_alive(state),
         {:ok, mailboxes} <- fetch_mailboxes(state) do
      {:ok, %{state | mailboxes: mailboxes}}
    else
      {:error, error} -> {:stop, error}
    end
  end

  defp digitalpost(opts) do
    case opts[:digitalpost] do
      nil -> DigitalPost.connect(Keyword.take(opts, [:dir]))
      dp -> {:ok, dp}
    end
  end

  defp device(opts) do
    case Device.load(opts[:dir] || Device.dir()) do
      {:ok, %Device{activated: true} = device} -> {:ok, device}
      _ -> {:error, Error.new(:connect, "no activated e-Boks device; run mix ebox.auth")}
    end
  end

  @impl true
  def handle_call(:mailboxes, _from, state), do: {:reply, state.mailboxes, state}

  def handle_call(request, _from, state) do
    with {:ok, state} <- keep_alive(state) do
      case run(request, state) do
        {:error, %Error{status: 401}} ->
          with {:ok, state} <- keep_alive(%{state | renewed_at: :never}),
               {:ok, result} <- run(request, state) do
            {:reply, {:ok, result}, state}
          else
            {:error, error} -> {:reply, {:error, error}, state}
          end

        :ok ->
          {:reply, :ok, state}

        {:ok, result} ->
          {:reply, {:ok, result}, state}

        {:error, error} ->
          {:reply, {:error, error}, state}
      end
    else
      {:error, error} -> {:reply, {:error, error}, state}
    end
  end

  @impl true
  def format_status(status) do
    Map.update(status, :state, nil, fn
      %{token: _} = state -> %{state | token: "[redacted]", device: "[redacted]"}
      other -> other
    end)
  end

  defp keep_alive(state) do
    if state.renewed_at != :never and now() - state.renewed_at < @renew_after do
      {:ok, state}
    else
      with {:ok, dp_token} <- DigitalPost.access_token(state.dp),
           {:ok, %{"access_token" => token}} <- Auth.eboks_token(dp_token, state.device) do
        {:ok, %{state | token: token, renewed_at: now()}}
      else
        {:ok, other} -> {:error, unexpected(:eboks_token, other)}
        {:error, _} = error -> error
      end
    end
  end

  defp fetch_mailboxes(state) do
    with {:ok, %{} = profile} <- get(:profile, "/user/profile", nil, [], state),
         {:ok, shares} when is_list(shares) <- get(:shares, "/mail/shares", nil, [], state) do
      own = %{id: "own", user_id: nil, name: profile["name"], own: true, permission: "Owner"}

      shared =
        for s <- shares, s["status"] == "Accepted" do
          %{
            id: to_string(s["userId"]),
            user_id: s["userId"],
            name: s["name"],
            own: false,
            permission: s["permission"]
          }
        end

      {:ok, [own | shared]}
    else
      {:ok, other} -> {:error, unexpected(:mailboxes, other)}
      error -> error
    end
  end

  defp run({:folders, mailbox}, state) do
    case get(:folders, "/mail/folders", mailbox, [], state) do
      {:ok, list} when is_list(list) -> {:ok, flatten(list, nil)}
      {:ok, other} -> {:error, unexpected(:folders, other)}
      error -> error
    end
  end

  defp run({:messages, mailbox, folder_id, opts}, state) do
    params = [offset: opts[:offset] || 0, limit: opts[:limit] || @page_size]

    case get(:messages, "/mail/folders/#{folder_id}/messages", mailbox, params, state) do
      {:ok, %{"items" => items} = body} when is_list(items) ->
        {:ok,
         %{
           messages: Enum.map(items, &Message.from_json/1),
           total: get_in(body, ["metadata", "total"]) || length(items)
         }}

      {:ok, other} ->
        {:error, unexpected(:messages, other)}

      error ->
        error
    end
  end

  defp run({:message, mailbox, message}, state) do
    case get(:message, message_path(message), mailbox, [], state) do
      {:ok, %{"id" => _} = json} -> {:ok, Message.from_json(json)}
      {:ok, other} -> {:error, unexpected(:message, other)}
      error -> error
    end
  end

  defp run({:content, mailbox, message, file}, state) do
    path =
      case file.kind do
        :content -> message_path(message) <> "/content"
        :attachment -> message_path(message) <> "/attachment/#{file.id}/content"
      end

    request(:content, :get, path, mailbox, [decode_body: false], state)
  end

  defp run({:update, mailbox, message, patch}, state) do
    with {:ok, _} <-
           request(:update, :post, message_path(message), mailbox, [json: patch], state),
         do: :ok
  end

  defp message_path(message), do: "/mail/folders/#{message.folder_id}/messages/#{message.id}"

  defp flatten(list, parent_id) do
    Enum.flat_map(list, fn folder ->
      id = to_string(folder["id"])

      entry = %{
        id: id,
        name: folder["name"],
        type: folder["type"],
        parent_id: parent_id || (folder["parent"] && to_string(folder["parent"]["id"]))
      }

      [entry | flatten(folder["folders"] || [], id)]
    end)
  end

  defp get(step, path, mailbox, params, state),
    do: request(step, :get, path, mailbox, [params: params], state)

  defp request(step, method, path, mailbox, options, state) do
    {params, options} = Keyword.pop(options, :params, [])
    params = if mailbox && mailbox.user_id, do: [userId: mailbox.user_id] ++ params, else: params

    req =
      Ebox.HTTP.new(
        [
          method: method,
          url: Auth.mobile_api() <> path,
          params: params,
          auth: {:bearer, state.token},
          retry: if(method == :get, do: :safe_transient, else: false),
          max_retries: 4
        ] ++ options
      )

    case Req.request(req) do
      {:ok, %Req.Response{status: status, body: body}} when status in 200..299 -> {:ok, body}
      {:ok, resp} -> {:error, Error.from_response(step, resp)}
      {:error, exception} -> {:error, Error.from_exception(step, exception)}
    end
  end

  defp unexpected(step, body),
    do: Error.new(step, "e-Boks answered #{step} in an unexpected format", body: body)

  defp now, do: System.monotonic_time(:second)
end
