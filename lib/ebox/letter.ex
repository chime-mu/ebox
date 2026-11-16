defmodule Ebox.Letter do
  @moduledoc """
  One letter in the local archive, read from its `.json` (see `Ebox.Archive`).

  `key` identifies a letter across the archive (system, mailbox, message id)
  and does not change when the letter is filed elsewhere.
  """

  alias Ebox.Archive

  defstruct [
    :key,
    :json_path,
    :source,
    :mailbox,
    :mailbox_id,
    :folder,
    :folder_id,
    :id,
    :title,
    :sender,
    :received_at,
    :reply_by,
    :read,
    files: [],
    meta: %{}
  ]

  @type t :: %__MODULE__{}

  # The name both services give the inbox.
  @inbox "Indbakke"

  @doc "The local directory name of the inbox."
  def inbox_name, do: @inbox

  @doc "Whether the letter is in an inbox (or a folder below it)."
  def in_inbox?(%__MODULE__{folder: [@inbox | _]}), do: true
  def in_inbox?(_), do: false

  @doc """
  Every letter in the archive. Directories starting with a dot (such as
  `.ebox`) are not part of the mail.
  """
  @spec all(Path.t()) :: [t()]
  def all(archive) do
    archive
    |> Path.join("*/*/**/*.json")
    |> Path.wildcard()
    |> Enum.flat_map(fn path ->
      case load(path) do
        {:ok, letter} -> [letter]
        _ -> []
      end
    end)
  end

  @doc "The letters in the inboxes."
  def inbox(archive), do: archive |> all() |> Enum.filter(&in_inbox?/1)

  @doc "Reads one letter."
  @spec load(Path.t()) :: {:ok, t()} | {:error, term()}
  def load(path) do
    with {:ok, json} <- File.read(path),
         {:ok, %{"source" => source, "message" => m} = meta} <- JSON.decode(json) do
      {:ok, from_meta(path, source, m, meta)}
    else
      {:ok, _} -> {:error, :not_a_letter}
      error -> error
    end
  end

  defp from_meta(path, source, m, meta) do
    {sender, received, reply_by, read} =
      case source do
        "digitalpost" ->
          {get_in(m, ["sender", "label"]), m["receivedDateTime"] || m["createdDateTime"],
           m["replyByDateTime"], m["read"]}

        _ ->
          {get_in(m, ["sender", "name"]), m["received"], nil, not m["unread"]}
      end

    %__MODULE__{
      key: key(source, meta["mailboxId"], m["id"]),
      json_path: path,
      source: source,
      mailbox: meta["mailbox"],
      mailbox_id: meta["mailboxId"],
      folder: meta["folder"] || [],
      folder_id: meta["folderId"],
      id: to_string(m["id"]),
      title: m["label"] || m["subject"] || get_in(m, ["content", "title"]),
      sender: sender,
      received_at: date(received),
      reply_by: date(reply_by),
      read: read,
      files: meta["files"] || [],
      meta: meta
    }
  end

  @doc "A URL-safe identifier of a letter."
  def key(source, mailbox_id, id),
    do: Base.url_encode64("#{source}|#{mailbox_id}|#{id}", padding: false)

  @doc """
  A short reference for a letter (6 characters), for talking about it: shown
  in the web app, and accepted by `find/2`. Stable when the letter is filed.
  """
  def ref(%__MODULE__{key: key}), do: ref(key)

  def ref(key) when is_binary(key),
    do: :crypto.hash(:sha256, key) |> Base.encode16(case: :lower) |> binary_part(0, 6)

  @doc "Finds a letter by `key/3` or by its `ref/1`."
  def find(archive, key_or_ref),
    do: archive |> all() |> Enum.find(&(&1.key == key_or_ref or ref(&1) == key_or_ref))

  @doc "The system's directory name: \"Post fra virksomheder\" or \"Post fra det offentlige\"."
  def system_dir(%__MODULE__{source: "digitalpost"}), do: Archive.system_dir(:digitalpost)
  def system_dir(%__MODULE__{}), do: Archive.system_dir(:eboks)

  @doc "The local paths of the letter's files, letter first."
  def file_paths(%__MODULE__{json_path: json, files: files}),
    do: for(f <- files, do: Path.join(Path.dirname(json), f["name"]))

  @doc "Claude's evaluation, if made (see `Ebox.Evaluate`)."
  def evaluation(%__MODULE__{meta: meta}), do: meta["evaluation"]

  @doc "Rewrites the letter's `.json` with `fun` applied to its metadata."
  def update_meta!(%__MODULE__{json_path: path} = letter, fun) do
    meta = fun.(letter.meta)
    partial = path <> ".part"
    File.write!(partial, JSON.encode!(meta))
    File.rename!(partial, path)
    {:ok, letter} = load(path)
    letter
  end

  defp date(nil), do: nil

  defp date(text) do
    case DateTime.from_iso8601(text) do
      {:ok, dt, _} ->
        DateTime.to_date(dt)

      _ ->
        case NaiveDateTime.from_iso8601(text) do
          {:ok, ndt} -> NaiveDateTime.to_date(ndt)
          _ -> nil
        end
    end
  end
end
