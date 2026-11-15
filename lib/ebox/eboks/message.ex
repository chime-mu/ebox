defmodule Ebox.Eboks.Message do
  @moduledoc """
  An e-Boks message as listed by `Ebox.Eboks.messages/4`.

  `files` holds the letter itself first, then its attachments. Folder listings
  only describe the letter; `Ebox.Eboks.message/3` adds the attachments
  (`attachment_count` says whether there are any). `attrs` keeps the JSON
  e-Boks sent, for fields not mapped here.
  """

  defmodule File do
    @moduledoc "One downloadable file: the letter (`kind: :content`) or an attachment."
    defstruct [:id, :kind, :name, :extension, :mime_type, :size]

    @type t :: %__MODULE__{
            id: String.t(),
            kind: :content | :attachment,
            name: String.t() | nil,
            extension: String.t() | nil,
            mime_type: String.t() | nil,
            size: non_neg_integer() | nil
          }
  end

  defstruct [
    :id,
    :folder_id,
    :name,
    :sender,
    :received_at,
    :unread,
    attachment_count: 0,
    files: [],
    attrs: %{}
  ]

  @type t :: %__MODULE__{
          id: String.t(),
          folder_id: String.t(),
          name: String.t() | nil,
          sender: String.t() | nil,
          received_at: NaiveDateTime.t() | nil,
          unread: boolean() | nil,
          attachment_count: non_neg_integer(),
          files: [File.t()],
          attrs: map()
        }

  @doc false
  def from_json(json) do
    content = json["content"] || %{}

    %__MODULE__{
      id: json["id"],
      folder_id: to_string(json["folderId"] || get_in(json, ["folder", "id"])),
      name: json["subject"] || content["title"],
      sender: get_in(json, ["sender", "name"]),
      received_at: parse_time(json["received"]),
      unread: json["unread"],
      attachment_count: json["numberOfAttachments"] || length(json["attachments"] || []),
      files:
        [file(content, :content, json["id"])] ++
          Enum.map(json["attachments"] || [], &file(&1, :attachment, nil)),
      attrs: json
    }
  end

  defp file(json, kind, fallback_id) do
    %File{
      id: to_string(json["id"] || fallback_id),
      kind: kind,
      name: json["title"],
      extension: json["fileExtension"],
      mime_type: json["mimeType"],
      size: json["fileSize"]
    }
  end

  @doc "File extension for a file, lower case, from e-Boks' `fileExtension` or the MIME type."
  @spec extension(File.t()) :: String.t()
  def extension(%File{extension: ext}) when is_binary(ext) and ext != "", do: String.downcase(ext)
  def extension(%File{mime_type: "application/pdf"}), do: "pdf"
  def extension(%File{mime_type: "text/html"}), do: "html"
  def extension(%File{mime_type: "text/plain"}), do: "txt"
  def extension(%File{mime_type: "image/" <> image}), do: image
  def extension(%File{}), do: "bin"

  defp parse_time(text) when is_binary(text) do
    case NaiveDateTime.from_iso8601(text) do
      {:ok, time} -> time
      _ -> nil
    end
  end

  defp parse_time(_), do: nil
end
