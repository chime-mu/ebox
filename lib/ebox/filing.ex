defmodule Ebox.Filing do
  @moduledoc """
  Files a letter: moves it to another folder in the service (e-Boks or Digital
  Post) and moves its local files to the matching directory, so both sides
  stay alike. Read state is not changed.

  The service is changed first, and only if the letter is still where the
  archive says it is; a letter that was moved elsewhere in the meantime is
  left alone and reported.
  """

  alias Ebox.{Archive, DigitalPost, Eboks, Letter}
  alias Ebox.Eboks.Message, as: EBMessage

  @doc """
  The folders of the letter's mailbox as `{folder_id, path}`, path being the
  list of directory names (`["Bank", "Kontoudskrift"]`).
  """
  def folders(conns, %Letter{} = letter) do
    with {:ok, folders} <- service_folders(conns, letter) do
      {:ok, for({f, path} <- Archive.folder_paths(folders), do: {f.id, path})}
    end
  end

  defp service_folders(conns, %Letter{source: "digitalpost"} = l),
    do: DigitalPost.folders(conns.digitalpost, l.mailbox_id)

  defp service_folders(conns, %Letter{} = l) do
    with {:ok, mailbox} <- eboks_mailbox(conns, l), do: Eboks.folders(conns.eboks, mailbox)
  end

  @doc """
  Moves the letter to the folder with local path `path` in both places.
  `how` is recorded in the `.json` (`"rule"` or `"user"`). Returns the letter
  as it is afterwards.
  """
  @spec file(map(), Letter.t(), [String.t()], String.t()) ::
          {:ok, Letter.t()} | {:error, Ebox.Error.t()}
  def file(conns, %Letter{} = letter, path, how) do
    with {:ok, folders} <- folders(conns, letter),
         {:ok, folder_id} <- target(folders, path),
         :ok <- move_remote(conns, letter, folder_id) do
      {:ok, move_local(letter, path, folder_id, how)}
    end
  end

  defp target(folders, path) do
    case Enum.find(folders, fn {_, p} -> p == path end) do
      {id, _} -> {:ok, id}
      nil -> {:error, Ebox.Error.new(:file, "no folder #{Enum.join(path, "/")} in this mailbox")}
    end
  end

  defp move_remote(conns, %Letter{source: "digitalpost"} = l, folder_id) do
    dp = conns.digitalpost

    with {:ok, current} <- DigitalPost.message(dp, l.mailbox_id, l.id),
         :ok <- still_there(current.folder_id, l),
         {:ok, _} <- DigitalPost.update(dp, l.mailbox_id, l.id, %{"folderId" => folder_id}),
         do: :ok
  end

  defp move_remote(conns, %Letter{} = l, folder_id) do
    eb = conns.eboks
    message = %EBMessage{id: l.id, folder_id: to_string(l.folder_id)}

    # Details are fetched through the folder the archive knows; if the letter
    # is no longer there, e-Boks answers 404.
    with {:ok, mailbox} <- eboks_mailbox(conns, l),
         {:ok, _} <- found(Eboks.message(eb, mailbox, message), l),
         :ok <- Eboks.update(eb, mailbox, message, %{folderId: eboks_id(folder_id)}),
         do: :ok
  end

  defp still_there(folder_id, l) do
    if to_string(folder_id) == to_string(l.folder_id),
      do: :ok,
      else: {:error, moved_elsewhere(l)}
  end

  defp found({:error, %Ebox.Error{status: 404}}, l), do: {:error, moved_elsewhere(l)}
  defp found(other, _), do: other

  defp moved_elsewhere(l),
    do:
      Ebox.Error.new(
        :file,
        "\"#{l.title}\" is no longer in #{Enum.join(l.folder, "/")} in the service; " <>
          "run mix ebox.archive to catch up"
      )

  defp eboks_id(id) do
    case Integer.parse(to_string(id)) do
      {n, ""} -> n
      _ -> id
    end
  end

  defp eboks_mailbox(conns, %Letter{mailbox_id: id}) do
    case Enum.find(Eboks.mailboxes(conns.eboks), &(to_string(&1.id) == to_string(id))) do
      nil -> {:error, Ebox.Error.new(:file, "e-Boks mailbox #{id} is not available")}
      mailbox -> {:ok, mailbox}
    end
  end

  defp move_local(%Letter{} = letter, path, folder_id, how) do
    old_dir = Path.dirname(letter.json_path)
    system_root = Path.join(Enum.drop(Path.split(old_dir), -length(letter.folder)))
    new_dir = Path.join([system_root | path])
    File.mkdir_p!(new_dir)

    for f <- letter.files do
      File.rename!(Path.join(old_dir, f["name"]), Path.join(new_dir, f["name"]))
    end

    new_json = Path.join(new_dir, Path.basename(letter.json_path))
    File.rename!(letter.json_path, new_json)

    Letter.update_meta!(%{letter | json_path: new_json}, fn meta ->
      meta
      |> Map.put("folder", path)
      |> Map.put("folderId", folder_id)
      |> Map.update("message", %{}, &Map.put(&1, "folderId", folder_id))
      |> Map.put("filed", %{
        "from" => letter.folder,
        "how" => how,
        "at" => DateTime.utc_now() |> DateTime.to_iso8601()
      })
    end)
  end
end
