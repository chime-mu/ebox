defmodule Ebox.Web do
  @moduledoc """
  A small local web app over the inboxes (`mix ebox.web ARCHIVE`): what has
  arrived, ordered by priority (urgent and important first), with Claude's
  evaluation, one-click Apple Reminders, and filing into folders (locally and
  in the service).

  It listens on 127.0.0.1 only. Every change is a POST carrying a secret made
  when the server starts, and requests must name the local host, so other web
  pages in the browser cannot drive it.
  """

  use Plug.Router

  alias Ebox.{Evaluate, Filing, Letter, Reminders, Rules, Triage}
  alias Ebox.Web.{Html, Jobs}

  plug(Plug.Parsers, parsers: [:urlencoded])
  plug(:guard)
  plug(:match)
  plug(:dispatch)

  @doc "Starts the server. Options: `:archive` (required), `:port` (default 4100)."
  def start(opts) do
    archive = Path.expand(Keyword.fetch!(opts, :archive))
    port = opts[:port] || 4100
    secret = Base.url_encode64(:crypto.strong_rand_bytes(18), padding: false)

    :persistent_term.put(__MODULE__, %{archive: archive, port: port, secret: secret})
    {:ok, _} = Jobs.start_link()
    {:ok, _} = Ebox.Web.Conns.start_link()
    Bandit.start_link(plug: __MODULE__, ip: {127, 0, 0, 1}, port: port)
  end

  defp config, do: :persistent_term.get(__MODULE__)
  defp archive, do: config().archive

  @doc "The address of the app, or of one letter in it."
  def url(key \\ nil),
    do: "http://127.0.0.1:#{config().port}/" <> if(key, do: "#l-#{key}", else: "")

  # Only the local host by name (against DNS rebinding), and every POST must
  # carry the secret.
  defp guard(conn, _) do
    host_ok = conn.host in ["127.0.0.1", "localhost"]

    cond do
      not host_ok ->
        conn |> send_resp(403, "forbidden") |> halt()

      conn.method == "POST" ->
        if Plug.Crypto.secure_compare(conn.body_params["t"] || "", config().secret),
          do: conn,
          else: conn |> send_resp(403, "forbidden") |> halt()

      true ->
        conn
    end
  end

  get "/" do
    overview = Triage.overview(archive())
    html(conn, Html.index(overview, Jobs.status(), conn.query_params["msg"], config().secret))
  end

  get "/rules" do
    html(conn, Html.rules(Rules.load(archive()), conn.query_params["msg"], config().secret))
  end

  get "/letter/:key/file/:n" do
    with %Letter{} = letter <- Letter.find(archive(), key),
         {n, ""} <- Integer.parse(n),
         path when is_binary(path) <- Enum.at(Letter.file_paths(letter), n),
         true <- File.regular?(path) do
      conn
      |> put_resp_content_type(MIME.from_path(path), nil)
      |> put_resp_header("content-disposition", "inline")
      |> send_file(200, path)
    else
      _ -> send_resp(conn, 404, "not found")
    end
  end

  post "/letter/:key/file" do
    with_letter(conn, key, fn letter ->
      path = String.split(conn.body_params["folder"] || "", "/", trim: true)

      with {:ok, conns} <- Ebox.Web.Conns.get(),
           {:ok, _} <- Filing.file(conns, letter, path, "user") do
        rule =
          case conn.body_params["rule"] do
            "subject" -> Rules.add(archive(), letter, path)
            "sender" -> Rules.add(archive(), letter, path, any_subject: true)
            _ -> nil
          end

        "Filed \"#{letter.title}\" in #{Enum.join(path, "/")}" <>
          if(rule, do: ", and made a rule for letters like it", else: "")
      end
    end)
  end

  post "/letter/:key/reminder" do
    with_letter(conn, key, fn letter ->
      with {:ok, _} <- Reminders.add(letter, url(letter.key)) do
        "Reminder added to \"#{Reminders.list_name()}\": #{letter.title}"
      end
    end)
  end

  post "/letter/:key/evaluate" do
    with_letter(conn, key, fn letter ->
      with {:ok, _} <- Evaluate.evaluate(letter, Triage.local_folders(letter)) do
        "Evaluated again: #{letter.title}"
      end
    end)
  end

  post "/routine/file" do
    case Ebox.Web.Conns.get() do
      {:ok, conns} ->
        results = Triage.file_routine(archive(), conns)
        failed = for {l, {:error, e}} <- results, do: "#{l.title}: #{Exception.message(e)}"

        back(
          conn,
          "Filed #{length(results) - length(failed)} routine letter(s)" <>
            if(failed == [], do: "", else: "; failed: " <> Enum.join(failed, "; "))
        )

      {:error, e} ->
        back(conn, Exception.message(e))
    end
  end

  post "/evaluate" do
    msg =
      case Jobs.evaluate(archive()) do
        :started -> "Evaluating in the background; this page refreshes until it is done"
        :running -> "Already evaluating"
      end

    back(conn, msg)
  end

  post "/rules/:index/delete" do
    {i, ""} = Integer.parse(index)
    Rules.delete(archive(), i)
    conn |> put_resp_header("location", "/rules?msg=Rule+removed") |> send_resp(303, "")
  end

  match _ do
    send_resp(conn, 404, "not found")
  end

  defp with_letter(conn, key, fun) do
    case Letter.find(archive(), key) do
      nil ->
        back(conn, "That letter is no longer in the archive where it was")

      letter ->
        case fun.(letter) do
          msg when is_binary(msg) -> back(conn, msg, letter.key)
          {:error, %{__exception__: true} = e} -> back(conn, Exception.message(e), letter.key)
          {:error, other} -> back(conn, inspect(other), letter.key)
        end
    end
  end

  defp back(conn, msg, anchor \\ nil) do
    location = "/?" <> URI.encode_query(msg: msg) <> if(anchor, do: "#l-#{anchor}", else: "")
    conn |> put_resp_header("location", location) |> send_resp(303, "")
  end

  defp html(conn, body) do
    conn
    |> put_resp_content_type("text/html")
    |> put_resp_header("content-security-policy", "default-src 'self'; style-src 'unsafe-inline'")
    |> send_resp(200, body)
  end
end

defmodule Ebox.Web.Conns do
  @moduledoc false
  # The service connections, opened on first use and kept.
  use Agent

  def start_link, do: Agent.start_link(fn -> nil end, name: __MODULE__)

  def get do
    Agent.get_and_update(
      __MODULE__,
      fn
        nil ->
          with {:ok, dp} <- Ebox.DigitalPost.connect(),
               {:ok, eb} <- Ebox.Eboks.connect(digitalpost: dp) do
            conns = %{digitalpost: dp, eboks: eb}
            {{:ok, conns}, conns}
          else
            error -> {error, nil}
          end

        conns ->
          {{:ok, conns}, conns}
      end,
      120_000
    )
  end
end

defmodule Ebox.Web.Jobs do
  @moduledoc false
  # Background evaluation with progress for the page.
  use Agent

  def start_link,
    do:
      Agent.start_link(fn -> %{running: false, done: 0, total: 0, errors: []} end,
        name: __MODULE__
      )

  def status, do: Agent.get(__MODULE__, & &1)

  def evaluate(archive) do
    start? =
      Agent.get_and_update(__MODULE__, fn
        %{running: true} = s -> {false, s}
        s -> {true, %{s | running: true, done: 0, errors: []}}
      end)

    if start? do
      total = Ebox.Triage.overview(archive).unevaluated
      Agent.update(__MODULE__, &%{&1 | total: total})

      Task.start(fn ->
        try do
          Ebox.Triage.evaluate_pending(archive, [], fn letter, result ->
            Agent.update(__MODULE__, fn s ->
              case result do
                {:ok, _} ->
                  %{s | done: s.done + 1}

                {:error, e} ->
                  text = if is_exception(e), do: Exception.message(e), else: inspect(e)
                  %{s | done: s.done + 1, errors: [{letter && letter.title, text} | s.errors]}
              end
            end)
          end)
        after
          Agent.update(__MODULE__, &%{&1 | running: false})
        end
      end)

      :started
    else
      :running
    end
  end
end
