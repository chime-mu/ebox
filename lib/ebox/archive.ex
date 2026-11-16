defmodule Ebox.Archive do
  @moduledoc """
  A local copy of all your mail, laid out like the e-Boks app:

      ARCHIVE/OWNER/Post fra virksomheder/FOLDER/SUBFOLDER/DATE SENDER - TITLE [ID].pdf
      ARCHIVE/OWNER/Post fra det offentlige/FOLDER/DATE SENDER - TITLE [ID].pdf

  `OWNER` is you, or a company whose mail you can read (a Digital Post mailbox
  you represent, an e-Boks mailbox shared with you). "Post fra virksomheder" is
  e-Boks (`Ebox.Eboks`), "Post fra det offentlige" is Digital Post
  (`Ebox.DigitalPost`). Every folder exists locally, also empty ones.

  Each message is stored as its files (the letter, then attachments as
  `... - NAME.ext`) and a `.json` next to them:

      {"source": "e-boks" | "digitalpost", "mailbox": OWNER, "mailboxId": ...,
       "folder": ["Bank", "Kontoudskrift"], "folderId": ...,
       "files": [{"name": local file name, "id": ..., "size": bytes}, ...],
       "message": what the service sent, "archivedAt": ...}

  The `.json` is written last, so it marks a message as complete.

  Archiving leaves read state as it was: Digital Post is read without side
  effects, and e-Boks messages that were unread are marked unread again right
  after their files are downloaded.
  """

  alias Ebox.{DigitalPost, Eboks}
  alias Ebox.DigitalPost.Message, as: DPMessage
  alias Ebox.Eboks.Message, as: EBMessage

  @systems %{eboks: "Post fra virksomheder", digitalpost: "Post fra det offentlige"}

  @typedoc "Open connections; either may be left out."
  @type conns :: %{optional(:digitalpost) => pid(), optional(:eboks) => pid()}

  @typedoc "One mailbox of one system, as it should look locally."
  @type part :: %{
          source: :digitalpost | :eboks,
          label: String.t(),
          mailbox: map(),
          dirs: [Path.t()],
          entries: [%{message: struct(), dir: Path.t(), folder: map() | nil, path: [String.t()]}]
        }

  @doc "The local directory name of a system."
  def system_dir(source), do: Map.fetch!(@systems, source)

  @doc """
  What the archive should hold: every mailbox, every folder in scope and every
  message with the directory it belongs in. Options: `:skip_inbox`.
  """
  @spec plan(conns(), Path.t(), keyword()) :: {:ok, [part()]} | {:error, Ebox.Error.t()}
  def plan(conns, archive, opts \\ []) do
    parts =
      for {source, conn} <- Enum.sort_by(conns, fn {s, _} -> s end), conn, reduce: {:ok, []} do
        {:ok, acc} ->
          case plan_source(source, conn, archive, opts) do
            {:ok, parts} -> {:ok, acc ++ parts}
            error -> error
          end

        error ->
          error
      end

    with {:ok, parts} <- parts, do: {:ok, Enum.sort_by(parts, &{&1.label, &1.source})}
  end

  defp plan_source(:digitalpost, dp, archive, opts) do
    collect(DigitalPost.mailboxes(dp), fn mailbox ->
      with {:ok, folders} <- DigitalPost.folders(dp, mailbox.id),
           {:ok, messages} <- DigitalPost.all_messages(dp, mailbox.id) do
        label = mailbox.owner_name || mailbox.id
        tree = tree(folders, &(&1.type == "INBOX"), opts)
        root = Path.join([archive, clean(label), system_dir(:digitalpost)])

        entries =
          for message <- messages, message.folder_id not in tree.skipped do
            {folder, path} = tree.place.(message.folder_id)
            %{message: message, dir: Path.join([root | path]), folder: folder, path: path}
          end

        {:ok,
         %{
           source: :digitalpost,
           label: label,
           mailbox: mailbox,
           dirs: Enum.map(tree.paths, &Path.join([root | &1])),
           entries: entries
         }}
      end
    end)
  end

  defp plan_source(:eboks, eb, archive, opts) do
    collect(Eboks.mailboxes(eb), fn mailbox ->
      with {:ok, folders} <- Eboks.folders(eb, mailbox) do
        label = mailbox.name || mailbox.id
        tree = tree(folders, &(&1.type == "inbox"), opts)
        root = Path.join([archive, clean(label), system_dir(:eboks)])

        entries =
          collect(Enum.reject(folders, &(&1.id in tree.skipped)), fn folder ->
            with {:ok, messages} <- Eboks.all_messages(eb, mailbox, folder.id) do
              {_, path} = tree.place.(folder.id)

              {:ok,
               for(
                 m <- messages,
                 do: %{message: m, dir: Path.join([root | path]), folder: folder, path: path}
               )}
            end
          end)

        with {:ok, entries} <- entries do
          {:ok,
           %{
             source: :eboks,
             label: label,
             mailbox: mailbox,
             dirs: Enum.map(tree.paths, &Path.join([root | &1])),
             entries: List.flatten(entries)
           }}
        end
      end
    end)
  end

  @doc """
  Every folder with its local path (directory names below the system
  directory), as `plan/3` lays them out.
  """
  def folder_paths(folders) do
    tree = tree(folders, fn _ -> false end, [])
    for folder <- folders, do: {folder, elem(tree.place.(folder.id), 1)}
  end

  # Folder paths by id; inboxes (and their subfolders) left out with :skip_inbox.
  defp tree(folders, inbox?, opts) do
    by_id = Map.new(folders, &{&1.id, &1})

    path = fn path, folder ->
      parent = folder.parent_id && by_id[folder.parent_id]
      name = with "" <- clean(folder.name || ""), do: clean(folder.id)
      if parent, do: path.(path, parent) ++ [name], else: [name]
    end

    under_inbox? = fn under, folder ->
      inbox?.(folder) or
        (folder.parent_id != nil and by_id[folder.parent_id] != nil and
           under.(under, by_id[folder.parent_id]))
    end

    skipped =
      for f <- folders,
          opts[:skip_inbox] && under_inbox?.(under_inbox?, f),
          into: MapSet.new(),
          do: f.id

    kept = Enum.reject(folders, &(&1.id in skipped))

    %{
      skipped: skipped,
      paths: Enum.map(kept, &path.(path, &1)),
      place: fn id ->
        case by_id[id] do
          nil -> {nil, ["Andet"]}
          folder -> {folder, path.(path, folder)}
        end
      end
    }
  end

  defp collect(items, fun) do
    Enum.reduce_while(items, {:ok, []}, fn item, {:ok, acc} ->
      case fun.(item) do
        {:ok, result} -> {:cont, {:ok, acc ++ [result]}}
        error -> {:halt, error}
      end
    end)
  end

  ## Naming

  @doc "The `.json` path of a planned message."
  def meta_path(%{dir: dir} = entry, source),
    do: Path.join(dir, base(source, entry.message) <> ".json")

  @doc false
  def base(:digitalpost, %DPMessage{} = m) do
    date = m.received_at || parse_time(m.attrs["createdDateTime"])
    base_name(date, m.sender, m.name, String.slice(m.id || "", 0, 8))
  end

  def base(:eboks, %EBMessage{} = m), do: base_name(m.received_at, m.sender, m.name, m.id)

  defp base_name(date, sender, title, tag) do
    date = if date, do: date |> NaiveDateTime.to_date() |> Date.to_iso8601(), else: "undated"
    clean("#{date} #{sender || "unknown"} - #{title}") <> " [#{clean(tag)}]"
  end

  @doc """
  Local file names for the files of a message: the first one is named after
  the message, the others get their own name as a suffix (plus their id where
  two would otherwise collide).
  """
  def filenames(source, message) do
    base = base(source, message)

    named =
      message.files
      |> Enum.with_index()
      |> Enum.map(fn
        {file, 0} -> {file, ""}
        {file, _} -> {file, " - " <> String.slice(clean(file_label(source, file)), 0, 60)}
      end)

    taken = Enum.frequencies_by(named, fn {file, suffix} -> {suffix, extension(source, file)} end)

    for {file, suffix} <- named do
      ext = extension(source, file)

      suffix =
        if taken[{suffix, ext}] > 1,
          do: "#{suffix} [#{clean(String.slice(to_string(file.id), 0, 8))}]",
          else: suffix

      {file, "#{base}#{suffix}.#{ext}"}
    end
  end

  defp file_label(:digitalpost, file), do: Path.rootname(file.name || file.id)
  defp file_label(:eboks, file), do: file.name || file.id

  defp extension(:digitalpost, file), do: DPMessage.extension(file)
  defp extension(:eboks, file), do: EBMessage.extension(file)

  @doc false
  # Server-supplied text must not be able to leave the target directory.
  def clean(text) do
    text
    |> to_string()
    |> String.replace(~r/[\/\\:\x00-\x1f]+/u, "_")
    |> String.trim()
    |> String.trim_leading(".")
    |> String.slice(0, 120)
    |> String.trim()
  end

  defp parse_time(text) when is_binary(text) do
    case NaiveDateTime.from_iso8601(text) do
      {:ok, time} -> time
      _ -> nil
    end
  end

  defp parse_time(_), do: nil

  ## Downloading

  @doc """
  Downloads what `plan/3` lists and is not stored yet, and creates every folder.
  Calls `report.(part, stats)` after each mailbox. Returns totals:
  `%{new: n, messages: n, unread_restored: n}`.
  """
  def download(conns, parts, report \\ fn _, _ -> :ok end) do
    Enum.reduce(parts, %{new: 0, messages: 0, unread_restored: 0}, fn part, totals ->
      Enum.each(part.dirs, &File.mkdir_p!/1)

      stats =
        Enum.reduce(part.entries, %{new: 0, messages: 0, unread_restored: 0}, fn entry, stats ->
          stats = %{stats | messages: stats.messages + 1}

          if File.exists?(meta_path(entry, part.source)) do
            stats
          else
            restored = store(conns, part, entry)
            %{stats | new: stats.new + 1, unread_restored: stats.unread_restored + restored}
          end
        end)

      report.(part, stats)
      Map.merge(totals, stats, fn _, a, b -> a + b end)
    end)
  end

  defp store(conns, %{source: :digitalpost} = part, entry) do
    dp = conns.digitalpost

    files =
      for {file, name} <- filenames(:digitalpost, entry.message) do
        write(Path.join(entry.dir, name), ok!(DigitalPost.content(dp, entry.message, file)))
        %{"name" => name, "id" => file.id, "document" => file.document_id, "size" => file.size}
      end

    write_meta(part, entry, entry.message, files)
    0
  end

  defp store(conns, %{source: :eboks} = part, entry) do
    eb = conns.eboks
    message = entry.message

    # Attachments are only in the details. Names stay those of the listing, as
    # verify/1 computes them from it.
    message =
      if message.attachment_count > 0 and length(message.files) < message.attachment_count + 1 do
        details = ok!(Eboks.message(eb, part.mailbox, message))
        %{message | files: details.files, attrs: details.attrs}
      else
        message
      end

    files =
      for {file, name} <- filenames(:eboks, message) do
        write(Path.join(entry.dir, name), ok!(Eboks.content(eb, part.mailbox, message, file)))
        %{"name" => name, "id" => file.id, "kind" => to_string(file.kind), "size" => file.size}
      end

    restored =
      if entry.message.unread do
        :ok = ok!(Eboks.update(eb, part.mailbox, message, %{unread: true}))
        1
      else
        0
      end

    write_meta(part, entry, message, files)
    restored
  end

  defp write_meta(part, entry, message, files) do
    meta = %{
      "source" => if(part.source == :eboks, do: "e-boks", else: "digitalpost"),
      "mailbox" => part.label,
      "mailboxId" => part.mailbox.id,
      "folder" => entry.path,
      "folderId" => entry.folder && entry.folder.id,
      "files" => files,
      "message" => message.attrs,
      "archivedAt" => DateTime.utc_now() |> DateTime.to_iso8601()
    }

    write(meta_path(entry, part.source), JSON.encode!(meta))
  end

  defp write(path, data) do
    partial = path <> ".part"
    File.write!(partial, data)
    File.rename!(partial, path)
  end

  defp ok!(:ok), do: :ok
  defp ok!({:ok, value}), do: value
  defp ok!({:error, error}), do: raise(error)

  ## Verification

  @doc """
  Checks the archive against `plan/3`. Returns per part
  `%{part: part, messages: n, files: n, problems: [{text, path}], notes: [{text, path}]}`.
  Problems: a message, file or folder missing locally, an empty or wrongly
  sized file, a `.pdf` that is not a PDF, an unfinished `.part` download.
  Notes: read state changed since archiving, local messages the service no
  longer lists in that folder.
  """
  def verify(parts) do
    for part <- parts do
      acc = %{part: part, messages: 0, files: 0, problems: [], notes: []}
      expected = MapSet.new(part.entries, &meta_path(&1, part.source))

      acc =
        Enum.reduce(part.dirs, acc, fn dir, acc ->
          if File.dir?(dir), do: acc, else: problem(acc, "folder missing", dir)
        end)

      acc = Enum.reduce(part.entries, acc, &check_entry(&2, part.source, &1))

      acc =
        for dir <- Enum.uniq(part.dirs ++ Enum.map(part.entries, & &1.dir)),
            {:ok, names} <- [File.ls(dir)],
            name <- names,
            reduce: acc do
          acc ->
            path = Path.join(dir, name)

            cond do
              String.ends_with?(name, ".part") ->
                problem(acc, "unfinished download", path)

              String.ends_with?(name, ".json") and path not in expected ->
                note(acc, "not listed by the service in this folder", path)

              true ->
                acc
            end
        end

      %{acc | problems: Enum.reverse(acc.problems), notes: Enum.reverse(acc.notes)}
    end
  end

  defp check_entry(acc, source, entry) do
    meta = meta_path(entry, source)
    acc = %{acc | messages: acc.messages + 1}

    with {:ok, json} <- File.read(meta),
         {:ok, %{"files" => files} = stored} <- JSON.decode(json) do
      expected_count =
        case source do
          :digitalpost -> length(entry.message.files)
          :eboks -> entry.message.attachment_count + 1
        end

      acc =
        if length(files) != expected_count,
          do:
            problem(
              acc,
              "#{length(files)} file(s) stored, the service lists #{expected_count}",
              meta
            ),
          else: acc

      acc =
        if read_state(source, stored["message"]) != read_state(source, entry.message.attrs),
          do: note(acc, "read state changed since archiving", meta),
          else: acc

      Enum.reduce(files, acc, fn file, acc ->
        check_file(acc, Path.join(entry.dir, file["name"]), file["size"])
      end)
    else
      {:error, :enoent} -> problem(acc, "missing", meta)
      _ -> problem(acc, "unreadable metadata", meta)
    end
  end

  defp read_state(:digitalpost, attrs), do: attrs["read"]
  defp read_state(:eboks, attrs), do: !attrs["unread"]

  defp check_file(acc, path, size) do
    acc = %{acc | files: acc.files + 1}

    case File.stat(path) do
      {:error, _} ->
        problem(acc, "missing file", path)

      {:ok, %{size: 0}} ->
        problem(acc, "empty file", path)

      {:ok, %{size: actual}} when is_integer(size) and actual != size ->
        problem(acc, "size #{actual}, the service says #{size}", path)

      {:ok, _} ->
        if String.downcase(Path.extname(path)) == ".pdf" and not pdf?(path),
          do: problem(acc, "not a PDF", path),
          else: acc
    end
  end

  defp pdf?(path), do: File.open!(path, [:read, :binary], &IO.binread(&1, 5)) == "%PDF-"

  defp problem(acc, text, path), do: %{acc | problems: [{text, path} | acc.problems]}
  defp note(acc, text, path), do: %{acc | notes: [{text, path} | acc.notes]}
end
