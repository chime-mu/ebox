defmodule Ebox.Message do
  @moduledoc """
  A message (document) in an e-Boks folder.

  `attachments` is only filled in by `Ebox.message/2`; folder listings do not
  include it. `attrs` keeps every XML attribute the server sent, for fields this
  struct does not model.
  """

  defmodule Attachment do
    @moduledoc "An extra document attached to a message."
    defstruct [:id, :name, :format, attrs: %{}]

    @type t :: %__MODULE__{id: String.t(), name: String.t(), format: String.t(), attrs: map()}
  end

  defstruct [
    :id,
    :name,
    :format,
    :sender,
    :received_at,
    :unread,
    :share_id,
    :folder_id,
    attachments: [],
    attrs: %{}
  ]

  @type t :: %__MODULE__{
          id: String.t(),
          name: String.t(),
          format: String.t() | nil,
          sender: String.t() | nil,
          received_at: NaiveDateTime.t() | nil,
          unread: boolean() | nil,
          share_id: String.t(),
          folder_id: String.t(),
          attachments: [Attachment.t()],
          attrs: map()
        }

  @doc false
  def from_xml(%{attrs: attrs} = node, share_id, folder_id) do
    %__MODULE__{
      id: attrs["id"],
      name: attrs["name"],
      format: attrs["format"],
      sender: sender(node),
      received_at: parse_time(attrs["receivedDateTime"]),
      unread: boolean(attrs["unread"]),
      share_id: share_id,
      folder_id: folder_id,
      attachments:
        for %{attrs: a} <- Ebox.XML.descendants(node, "AttachmentInfo") do
          %Attachment{id: a["id"], name: a["name"], format: a["format"], attrs: a}
        end,
      attrs: attrs
    }
  end

  @doc "File extension for a message or attachment, from its e-Boks format."
  @spec extension(t() | Attachment.t()) :: String.t()
  def extension(%{format: format}) do
    case String.downcase(format || "") do
      "" -> "bin"
      format when format in ["plain", "text"] -> "txt"
      format -> String.replace(format, ~r/[^a-z0-9]/, "")
    end
  end

  @doc "MIME type for a message or attachment, from its e-Boks format."
  @spec mime_type(t() | Attachment.t()) :: String.t()
  def mime_type(item) do
    case extension(item) do
      "txt" -> "text/plain"
      "html" -> "text/html"
      "jpg" -> "image/jpeg"
      ext when ext in ["gif", "jpeg", "tiff", "png", "webp"] -> "image/" <> ext
      "bin" -> "application/octet-stream"
      ext -> "application/" <> ext
    end
  end

  defp sender(node) do
    case Ebox.XML.children(node, "Sender") do
      [%{text: text} | _] when text != "" -> text
      _ -> nil
    end
  end

  defp parse_time(nil), do: nil

  defp parse_time(value) do
    case NaiveDateTime.from_iso8601(value) do
      {:ok, time} -> time
      _ -> nil
    end
  end

  defp boolean("true"), do: true
  defp boolean("false"), do: false
  defp boolean(_), do: nil
end
