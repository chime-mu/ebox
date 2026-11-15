defmodule Ebox do
  @moduledoc ~S"""
  Read-only connector for [e-Boks](https://www.e-boks.dk), speaking the same
  API as the official mobile app.

      {:ok, box} = Ebox.connect(password: "mobile-access password")

      {:ok, folders} = Ebox.folders(box)
      inbox = Enum.find(folders, &(&1.name == "Inbox"))

      {:ok, [message | _]} = Ebox.messages(box, inbox.id)
      {:ok, pdf} = Ebox.content(box, message)
      File.write!("letter.#{Ebox.Message.extension(message)}", pdf)

  The device has to be activated once with MitID first; see `Ebox.Auth` and
  `mix ebox.auth`.

  `connect/1` starts a process that owns the session. e-Boks issues a new nonce
  with every response, so calls on one connection run one at a time, and a
  session that has expired is re-established transparently.
  """

  use GenServer

  alias Ebox.{Device, Error, Message, Session}

  @type box :: GenServer.server()
  @timeout 60_000

  @doc """
  Logs in and returns a connection process.

  Options:

    * `:password` – the mobile-access password (required)
    * `:device` – an `Ebox.Device`; defaults to the one stored by `mix ebox.auth`
    * `:name` – optional name to register the process under
  """
  @spec connect(keyword()) :: {:ok, pid()} | {:error, Error.t()}
  def connect(opts) do
    case GenServer.start(__MODULE__, opts, Keyword.take(opts, [:name])) do
      {:ok, pid} -> {:ok, pid}
      {:error, %Error{} = error} -> {:error, error}
      {:error, reason} -> {:error, Error.new(:connect, inspect(reason))}
    end
  end

  @doc "Like `connect/1` but linked to the caller, for use in a supervision tree."
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, Keyword.take(opts, [:name]))

  @doc "Closes the connection."
  def disconnect(box), do: GenServer.stop(box)

  @doc "The account the connection is logged in as, and the device used."
  @spec whoami(box) :: %{name: String.t(), user_id: String.t(), device: Device.t()}
  def whoami(box), do: GenServer.call(box, :whoami, @timeout)

  @doc "Mailboxes shared with you. Pass a share's `id` as the `:share` option elsewhere."
  def shares(box), do: call(box, {Session, :shares, []})

  @doc "Folders of your mailbox, or of a share when `share: id` is given."
  def folders(box, opts \\ []), do: call(box, {Session, :folders, [share(opts)]})

  @doc """
  One page of messages in a folder, newest first as e-Boks returns them.

  Options: `:share`, `:skip` (default 0), `:take` (default 100).
  """
  @spec messages(box, String.t(), keyword()) :: {:ok, [Message.t()]} | {:error, Error.t()}
  def messages(box, folder_id, opts \\ []), do: call(box, {Session, :messages, [folder_id, opts]})

  @doc "Every message in a folder, fetched page by page. Options: `:share`."
  @spec all_messages(box, String.t(), keyword()) :: {:ok, [Message.t()]} | {:error, Error.t()}
  def all_messages(box, folder_id, opts \\ []) do
    page_size = 200

    0
    |> Stream.iterate(&(&1 + page_size))
    |> Enum.reduce_while({:ok, []}, fn skip, {:ok, acc} ->
      case messages(box, folder_id, share: share(opts), skip: skip, take: page_size) do
        {:ok, page} when length(page) < page_size -> {:halt, {:ok, acc ++ page}}
        {:ok, page} -> {:cont, {:ok, acc ++ page}}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  @doc "Reloads a message with full details, including `attachments`."
  @spec message(box, Message.t()) :: {:ok, Message.t()} | {:error, Error.t()}
  def message(box, %Message{} = message), do: call(box, {Session, :message, [message]})

  @doc "Downloads the message's document, or the given attachment, as a binary."
  @spec content(box, Message.t(), Message.Attachment.t() | nil) ::
          {:ok, binary()} | {:error, Error.t()}
  def content(box, %Message{} = message, attachment \\ nil),
    do: call(box, {Session, :content, [message, attachment]})

  defp share(opts), do: to_string(opts[:share] || "0")
  defp call(box, request), do: GenServer.call(box, request, @timeout)

  ## GenServer

  @impl true
  def init(opts) do
    with {:ok, password} <- fetch_password(opts),
         {:ok, device} <- fetch_device(opts),
         {:ok, session} <- Session.login(device, password) do
      {:ok, session}
    else
      {:error, error} -> {:stop, error}
    end
  end

  @impl true
  def handle_call(:whoami, _from, session) do
    {:reply, Map.take(session, [:name, :user_id, :device]), session}
  end

  def handle_call({module, function, args}, _from, session) do
    case apply(module, function, [session | args]) do
      {:error, %Error{status: status}} when status in [401, 403] ->
        # Sessions expire after a period of inactivity; log in again and retry once.
        with {:ok, session} <- Session.login(session.device, session.password),
             {:ok, result, session} <- apply(module, function, [session | args]) do
          {:reply, {:ok, result}, session}
        else
          {:error, error} -> {:reply, {:error, error}, session}
        end

      {:ok, result, session} ->
        {:reply, {:ok, result}, session}

      {:error, error} ->
        {:reply, {:error, error}, session}
    end
  end

  # Keeps the password out of crash reports and :sys.get_status/1.
  @impl true
  def format_status(status) do
    Map.update(status, :state, nil, fn
      %Session{} = session -> %{session | password: "[redacted]"}
      other -> other
    end)
  end

  defp fetch_password(opts) do
    case opts[:password] do
      password when is_binary(password) and password != "" -> {:ok, password}
      _ -> {:error, Error.new(:connect, "the :password option is required")}
    end
  end

  defp fetch_device(opts) do
    case opts[:device] do
      %Device{} = device ->
        {:ok, device}

      nil ->
        case Device.load() do
          {:ok, %Device{activated: true} = device} ->
            {:ok, device}

          _ ->
            {:error,
             Error.new(
               :connect,
               "no activated device in #{Device.dir()}, run `mix ebox.auth` first"
             )}
        end
    end
  end
end
