defmodule Ebox.XML do
  @moduledoc false
  # Minimal XML reader on top of :xmerl. e-Boks responses are small attribute-heavy
  # documents, so every element becomes a plain map:
  #
  #     %{name: "FolderInfo", attrs: %{"id" => "1"}, children: [...], text: ""}

  require Record

  for record <- [:xmlElement, :xmlAttribute, :xmlText] do
    Record.defrecordp(record, Record.extract(record, from_lib: "xmerl/include/xmerl.hrl"))
  end

  @type xml_node :: %{name: String.t(), attrs: map(), children: [xml_node], text: String.t()}

  @spec parse(binary()) :: {:ok, xml_node} | {:error, term()}
  def parse(body) when is_binary(body) do
    chars = body |> to_chars() |> strip_declaration()

    try do
      {doc, _rest} = :xmerl_scan.string(chars, quiet: true, allow_entities: false)
      {:ok, to_node(doc)}
    catch
      :exit, reason -> {:error, {:invalid_xml, reason}}
    end
  end

  @doc "Direct children named `name`."
  def children(%{children: children}, name), do: Enum.filter(children, &(&1.name == name))

  @doc "All descendants named `name`, in document order."
  def descendants(%{children: children}, name) do
    Enum.flat_map(children, fn child ->
      if child.name == name,
        do: [child | descendants(child, name)],
        else: descendants(child, name)
    end)
  end

  @doc "The node itself or its first descendant named `name`."
  def find(%{name: name} = node, name), do: node
  def find(node, name), do: node |> descendants(name) |> List.first()

  def escape(value) do
    value
    |> to_string()
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
    |> String.replace("\"", "&quot;")
  end

  # The server has been seen sending Latin-1 as well as UTF-8. xmerl wants UTF-8
  # bytes, so normalise here and drop the declaration so it does not decode twice.
  defp to_chars(body) do
    utf8 = if String.valid?(body), do: body, else: :unicode.characters_to_binary(body, :latin1)
    :binary.bin_to_list(utf8)
  end

  defp strip_declaration([0xEF, 0xBB, 0xBF | rest]), do: strip_declaration(rest)

  defp strip_declaration([?<, ??, ?x, ?m, ?l | rest]) do
    rest |> Enum.drop_while(&(&1 != ?>)) |> Enum.drop(1)
  end

  defp strip_declaration(chars), do: chars

  defp to_node(xmlElement(name: name, attributes: attributes, content: content)) do
    %{
      name: local_name(name),
      attrs:
        Map.new(attributes, fn xmlAttribute(name: key, value: value) ->
          {local_name(key), to_string(value)}
        end),
      children: for(xmlElement() = element <- content, do: to_node(element)),
      text: for(xmlText(value: value) <- content, into: "", do: to_string(value)) |> String.trim()
    }
  end

  defp local_name(name), do: name |> Atom.to_string() |> String.split(":") |> List.last()
end
