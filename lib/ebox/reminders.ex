defmodule Ebox.Reminders do
  @moduledoc """
  Adds a reminder for a letter to Apple Reminders (macOS), in the list
  `$EBOX_REMINDERS_LIST` (default "Post"), created if missing. The first time,
  macOS asks whether the program may control Reminders.
  """

  alias Ebox.{Evaluate, Letter}

  @script """
  on run argv
    set listName to item 1 of argv
    set theName to item 2 of argv
    set theBody to item 3 of argv
    tell application "Reminders"
      if not (exists list listName) then make new list with properties {name:listName}
      set props to {name:theName, body:theBody}
      if (count of argv) > 3 then
        set d to current date
        set day of d to 1
        set year of d to (item 4 of argv) as integer
        set month of d to (item 5 of argv) as integer
        set day of d to (item 6 of argv) as integer
        set time of d to 9 * hours
        set props to props & {due date:d, remind me date:d}
      end if
      make new reminder at end of list listName with properties props
    end tell
  end run
  """

  def list_name, do: System.get_env("EBOX_REMINDERS_LIST") || "Post"

  @doc """
  The reminder for a letter: its action (or title) as the name, due on the
  respond-by date; the body holds sender, summary, a link to the letter in the
  web app and the local file.
  """
  def reminder(%Letter{} = letter, link) do
    eval = Letter.evaluation(letter) || %{}

    body =
      [
        "#{letter.sender}: #{letter.title}",
        eval["summary"],
        link,
        List.first(Letter.file_paths(letter))
      ]
      |> Enum.reject(&(&1 in [nil, ""]))
      |> Enum.join("\n\n")

    %{name: eval["action"] || letter.title, body: body, due: Evaluate.respond_by(letter)}
  end

  @doc "Adds the reminder (see `reminder/2`) and notes it in the letter's `.json`."
  def add(%Letter{} = letter, link, opts \\ []) do
    r = reminder(letter, link)
    due = if r.due, do: [r.due.year, r.due.month, r.due.day] |> Enum.map(&to_string/1), else: []
    run = opts[:runner] || (&osascript/1)

    with :ok <- run.([list_name(), r.name, r.body | due]) do
      {:ok,
       Letter.update_meta!(letter, fn meta ->
         Map.put(meta, "reminder", %{
           "name" => r.name,
           "due" => r.due && Date.to_iso8601(r.due),
           "at" => DateTime.utc_now() |> DateTime.to_iso8601()
         })
       end)}
    end
  end

  defp osascript(args) do
    case System.cmd("osascript", ["-e", @script | args], stderr_to_stdout: true) do
      {_, 0} -> :ok
      {out, _} -> {:error, Ebox.Error.new(:reminder, "Reminders: " <> String.trim(out))}
    end
  end
end
