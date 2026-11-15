defmodule Ebox.DigitalPost.Message do
  @moduledoc """
  A Digital Post message as listed by `Ebox.DigitalPost.messages/3`.

  A message holds one or more documents (the letter, then attachments), each
  made of files, usually one PDF or HTML file. `files` flattens them in order.
  `attrs` keeps the full JSON Digital Post sent, for fields not mapped here.
  """

  defmodule File do
    @moduledoc "One downloadable file of a message."
    defstruct [:id, :document_id, :document_type, :name, :mime_type, :size]

    @type t :: %__MODULE__{
            id: String.t(),
            document_id: String.t(),
            document_type: String.t() | nil,
            name: String.t() | nil,
            mime_type: String.t() | nil,
            size: non_neg_integer() | nil
          }
  end

  defstruct [
    :id,
    :mailbox_id,
    :folder_id,
    :name,
    :sender,
    :received_at,
    :read,
    :reply_by,
    :legally_notified,
    files: [],
    attrs: %{}
  ]

  @type t :: %__MODULE__{
          id: String.t(),
          mailbox_id: String.t(),
          folder_id: String.t() | nil,
          name: String.t() | nil,
          sender: String.t() | nil,
          received_at: NaiveDateTime.t() | nil,
          read: boolean() | nil,
          reply_by: NaiveDateTime.t() | nil,
          legally_notified: boolean() | nil,
          files: [File.t()],
          attrs: map()
        }

  @doc false
  def from_json(json) do
    %__MODULE__{
      id: json["id"],
      mailbox_id: json["mailboxId"],
      folder_id: json["folderId"],
      name: json["label"],
      sender: get_in(json, ["sender", "label"]),
      received_at: parse_time(json["receivedDateTime"] || json["messageDateTime"]),
      read: json["read"],
      reply_by: parse_time(json["replyByDateTime"]),
      legally_notified: json["legallyNotified"],
      files:
        for document <- List.wrap(json["documents"]),
            file <- List.wrap(document["files"]) do
          %File{
            id: file["id"],
            document_id: document["id"],
            document_type: document["documentType"],
            name: file["filename"],
            mime_type: file["encodingFormat"],
            size: file["fileSize"]
          }
        end,
      attrs: json
    }
  end

  @doc "File extension for a file, from its name or else its MIME type."
  @spec extension(File.t()) :: String.t()
  def extension(%File{name: name, mime_type: mime}) do
    case name && Path.extname(name) do
      "." <> ext when ext != "" ->
        String.downcase(ext)

      _ ->
        case mime do
          "application/pdf" -> "pdf"
          "text/html" -> "html"
          "text/plain" -> "txt"
          "application/xml" -> "xml"
          "image/" <> image -> image
          _ -> "bin"
        end
    end
  end

  defp parse_time(text) when is_binary(text) do
    case NaiveDateTime.from_iso8601(text) do
      {:ok, time} -> NaiveDateTime.truncate(time, :second)
      _ -> nil
    end
  end

  defp parse_time(_), do: nil
end
