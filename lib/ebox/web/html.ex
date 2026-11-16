defmodule Ebox.Web.Html do
  @moduledoc false
  # The pages of Ebox.Web, as plain server-rendered HTML.

  alias Ebox.{Evaluate, Letter, Triage}

  @groups %{
    1 => {"Urgent and important", "p1"},
    2 => {"Important", "p2"},
    3 => {"Urgent", "p3"},
    4 => {"Neither urgent nor important", "p4"}
  }

  def index(overview, job, msg, secret) do
    today = Date.utc_today()
    {evaluated, pending} = Enum.split_with(overview.judge, &Letter.evaluation/1)
    groups = Enum.group_by(evaluated, &Evaluate.priority(&1, today))

    body = [
      header(msg, job),
      evaluate_bar(overview, job, secret),
      for p <- 1..4, letters = groups[p] || [], letters != [] do
        {title, class} = @groups[p]

        [
          ~s(<section class="group #{class}"><h2>#{p}. #{title} <span class="n">#{length(letters)}</span></h2>),
          Enum.map(letters, &card(&1, overview, today, secret)),
          "</section>"
        ]
      end,
      if pending != [] do
        [
          ~s(<section class="group p0"><h2>Not evaluated yet <span class="n">#{length(pending)}</span></h2>),
          Enum.map(pending, &card(&1, overview, today, secret)),
          "</section>"
        ]
      else
        []
      end,
      routine(overview.routine, secret)
    ]

    page("Indbakke", body, job.running)
  end

  defp header(msg, _job) do
    [
      ~s(<header><h1>Post</h1><nav><a href="/">Inbox</a> · <a href="/rules">Rules</a></nav></header>),
      if(msg, do: ~s(<p class="msg">#{e(msg)}</p>), else: "")
    ]
  end

  defp evaluate_bar(overview, job, secret) do
    cond do
      job.running ->
        ~s(<p class="bar">Claude is evaluating: #{job.done} of #{job.total} done…</p>)

      overview.unevaluated > 0 ->
        ~s(<form class="bar" method="post" action="/evaluate">#{t(secret)}) <>
          "#{overview.unevaluated} letter(s) not evaluated yet. " <>
          ~s(<button>Let Claude evaluate them</button></form>)

      true ->
        ""
    end <>
      if job.errors != [] do
        ~s[<details class="errors"><summary>#{length(job.errors)} evaluation(s) failed</summary><ul>] <>
          Enum.map_join(job.errors, "", fn {title, text} -> "<li>#{e(title)}: #{e(text)}</li>" end) <>
          "</ul></details>"
      else
        ""
      end
  end

  defp card(%Letter{} = l, overview, today, secret) do
    eval = Letter.evaluation(l) || %{}
    due = Evaluate.respond_by(l)
    folders = Triage.local_folders(l)
    suggested = Triage.suggested_folder(overview, l)
    rule = overview.rules[l.key]
    reminder = l.meta["reminder"]

    """
    <article class="card" id="l-#{l.key}">
      <div class="top">
        <h3><a href="/letter/#{l.key}/file/0" target="_blank">#{e(l.title)}</a></h3>
        #{due_badge(due, today)}
      </div>
      <p class="meta"><code class="ref" title="Reference for this letter">#{Letter.ref(l)}</code> · #{e(l.sender)} · #{e(l.mailbox)} · #{system(l)} · received #{l.received_at}#{attachments(l)}</p>
      #{if eval != %{}, do: evaluation(eval, l), else: ""}
      <div class="actions">
        <form method="post" action="/letter/#{l.key}/reminder">#{t(secret)}
          <button>#{if reminder, do: "Add reminder again", else: "Add reminder"}</button>
          #{if reminder, do: ~s(<span class="done">✓ reminder #{e(reminder["due"] || "without date")}</span>), else: ""}
        </form>
        <form method="post" action="/letter/#{l.key}/file" class="file">#{t(secret)}
          <select name="folder">#{folder_options(folders, suggested)}</select>
          <select name="rule">
            <option value="">just this letter</option>
            <option value="subject"#{if eval["recurring"] == true and is_nil(rule), do: " selected", else: ""}>and future ones like it</option>
            <option value="sender">and everything from this sender</option>
          </select>
          <button>File</button>
        </form>
        #{if eval != %{}, do: ~s(<form method="post" action="/letter/#{l.key}/evaluate">#{t(secret)}<button class="quiet">Evaluate again</button></form>), else: ""}
      </div>
      #{if rule, do: ~s(<p class="hint">Letters like this were filed in #{e(Enum.join(rule["folder"], "/"))} before.</p>), else: ""}
      #{new_folder_note(suggested, folders)}
    </article>
    """
  end

  defp evaluation(eval, l) do
    imp =
      if eval["important"],
        do: ~s(<b class="imp">Important</b>),
        else: ~s(<b class="notimp">Not important</b>)

    basis =
      cond do
        l.reply_by -> " (reply deadline in Digital Post)"
        eval["respondByBasis"] -> " (#{e(eval["respondByBasis"])})"
        true -> ""
      end

    """
    <p class="summary">#{e(eval["summary"])}</p>
    <p class="why">#{imp}: #{e(eval["importance"])}</p>
    #{if eval["action"], do: ~s(<p class="todo">→ #{e(eval["action"])}#{if Evaluate.respond_by(l), do: ~s(<span class="basis">#{basis}</span>), else: ""}</p>), else: ""}
    #{if eval["recurring"], do: ~s(<p class="hint">Claude thinks this is routine mail. “and future ones like it” makes a rule, so the next ones are filed without asking.</p>), else: ""}
    """
  end

  defp due_badge(nil, _), do: ""

  defp due_badge(due, today) do
    days = Date.diff(due, today)

    {text, class} =
      cond do
        days < -Evaluate.expired_days() -> {"deadline passed", "expired"}
        days < 0 -> {"overdue #{-days} d", "late"}
        days == 0 -> {"today", "late"}
        days <= Evaluate.urgent_days() -> {"in #{days} d", "soon"}
        true -> {"in #{days} d", "later"}
      end

    ~s(<span class="due #{class}">respond by #{due} · #{text}</span>)
  end

  defp attachments(l) do
    case Enum.drop(Enum.with_index(l.files), 1) do
      [] ->
        ""

      rest ->
        " · " <>
          Enum.map_join(rest, ", ", fn {f, i} ->
            ~s(<a href="/letter/#{l.key}/file/#{i}" target="_blank">#{e(attachment_name(f["name"]))}</a>)
          end)
    end
  end

  defp attachment_name(name) do
    case String.split(name, "] - ", parts: 2) do
      [_, rest] -> rest
      _ -> name
    end
  end

  defp folder_options(folders, suggested) do
    selected = if suggested in folders, do: suggested, else: nil

    [
      ~s(<option value="" disabled#{if selected, do: "", else: " selected"}>choose folder…</option>)
      | for f <- folders do
          path = Enum.join(f, "/")
          sel = if f == selected, do: " selected", else: ""
          ~s(<option value="#{e(path)}"#{sel}>#{e(path)}</option>)
        end
    ]
  end

  defp new_folder_note(suggested, folders) when is_list(suggested) and suggested != [] do
    if suggested in folders,
      do: "",
      else:
        ~s(<p class="hint">Claude suggests a new folder “#{e(Enum.join(suggested, "/"))}”. Create it in the app, run mix ebox.archive, then file.</p>)
  end

  defp new_folder_note(_, _), do: ""

  defp routine([], _), do: ""

  defp routine(routine, secret) do
    rows =
      Enum.map(routine, fn {l, rule} ->
        "<tr><td>#{l.received_at}</td><td>#{e(l.sender)}</td><td>#{e(l.title)}</td><td>→ #{e(Enum.join(rule["folder"], "/"))}</td></tr>"
      end)

    """
    <section class="group routine">
      <h2>Routine <span class="n">#{length(routine)}</span></h2>
      <p>A rule knows their folder and Claude found nothing to do (or you made the rule). They only need to go to their folder, locally and in the service; read state is not changed.</p>
      <form method="post" action="/routine/file">#{t(secret)}<button>File all #{length(routine)} routine letters</button></form>
      <details><summary>Show them</summary><table>#{rows}</table></details>
    </section>
    """
  end

  def rules(rules, msg, secret) do
    rows =
      rules
      |> Enum.with_index()
      |> Enum.map(fn {r, i} ->
        """
        <tr><td>#{e(r["origin"])}</td><td>#{e(r["mailbox"])}</td><td>#{e(r["source"])}</td>
        <td>#{e(r["sender"])}</td><td><code>#{e(r["subject"])}</code></td>
        <td>#{e(Enum.join(r["folder"], "/"))}</td><td>#{r["seen"] || ""}</td>
        <td><form method="post" action="/rules/#{i}/delete">#{t(secret)}<button class="quiet">remove</button></form></td></tr>
        """
      end)

    page(
      "Rules",
      [
        header(msg, nil),
        ~s(<p>First match wins. <code>#</code> stands for numbers and month names, <code>*</code> for any subject. Learned rules are remade by <code>mix ebox.rules ARCHIVE</code>; your own are kept.</p>),
        ~s(<table class="rules"><tr><th>origin</th><th>mailbox</th><th>system</th><th>sender</th><th>subject</th><th>folder</th><th>seen</th><th></th></tr>),
        rows,
        "</table>"
      ],
      false
    )
  end

  defp system(%Letter{source: "digitalpost"}), do: "Digital Post"
  defp system(_), do: "e-Boks"

  defp t(secret), do: ~s(<input type="hidden" name="t" value="#{secret}">)

  defp e(nil), do: ""
  defp e(text), do: text |> to_string() |> Plug.HTML.html_escape()

  defp page(title, body, refresh) do
    IO.iodata_to_binary([
      """
      <!doctype html><html lang="en"><head><meta charset="utf-8">
      <meta name="viewport" content="width=device-width, initial-scale=1">
      #{if refresh, do: ~s(<meta http-equiv="refresh" content="10">), else: ""}
      <title>#{title}</title><style>#{css()}</style></head><body><main>
      """,
      body,
      "</main></body></html>"
    ])
  end

  defp css do
    """
    :root{--bg:#f7f6f3;--card:#fff;--ink:#1d1d1f;--mute:#6b6b70;--line:#e3e1dc;--p1:#c0392b;--p2:#d68910;--p3:#2471a3;--p4:#7f8c8d;--ok:#1e8449}
    @media (prefers-color-scheme:dark){:root{--bg:#161618;--card:#222226;--ink:#ececee;--mute:#9a9aa2;--line:#34343a}}
    *{box-sizing:border-box}body{margin:0;background:var(--bg);color:var(--ink);font:15px/1.45 -apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif}
    main{max-width:960px;margin:0 auto;padding:16px}
    header{display:flex;justify-content:space-between;align-items:baseline}h1{margin:0 0 8px}
    a{color:inherit}nav a{color:var(--mute)}
    .msg{background:var(--card);border-left:4px solid var(--ok);padding:8px 12px;margin:8px 0}
    .bar{background:var(--card);border:1px solid var(--line);padding:8px 12px;border-radius:8px}
    .group{margin:24px 0}.group h2{font-size:17px;margin:0 0 8px;padding-left:10px;border-left:5px solid var(--p4)}
    .p1 h2{border-color:var(--p1)}.p2 h2{border-color:var(--p2)}.p3 h2{border-color:var(--p3)}
    .n{color:var(--mute);font-weight:normal}
    .card{background:var(--card);border:1px solid var(--line);border-radius:10px;padding:12px 14px;margin:10px 0}
    .top{display:flex;justify-content:space-between;gap:12px;align-items:flex-start}
    .card h3{margin:0;font-size:16px}.card h3 a{text-decoration:none}.card h3 a:hover{text-decoration:underline}
    .meta{color:var(--mute);margin:2px 0 6px;font-size:13px}
    .summary{margin:6px 0}.why,.todo{margin:4px 0}.todo{font-weight:600}
    .basis{font-weight:normal;color:var(--mute)}
    .imp{color:var(--p1)}.notimp{color:var(--mute)}
    .hint{color:var(--mute);font-size:13px;margin:6px 0 0}
    .due{white-space:nowrap;font-size:13px;padding:2px 8px;border-radius:999px;border:1px solid var(--line)}
    .due.expired{color:var(--mute);text-decoration:line-through}.due.late{background:var(--p1);color:#fff;border-color:var(--p1)}.due.soon{color:var(--p1);border-color:var(--p1)}
    .actions{display:flex;flex-wrap:wrap;gap:8px 16px;align-items:center;margin-top:8px}
    .actions form{display:flex;gap:6px;align-items:center;margin:0}
    button{font:inherit;padding:4px 10px;border-radius:6px;border:1px solid var(--line);background:var(--bg);color:var(--ink);cursor:pointer}
    button:hover{border-color:var(--mute)}button.quiet{color:var(--mute)}
    select{font:inherit;max-width:260px}
    .ref{font-size:12px;user-select:all}.done{color:var(--ok);font-size:13px}
    table{border-collapse:collapse;width:100%;font-size:13px}td,th{text-align:left;padding:4px 6px;border-bottom:1px solid var(--line);vertical-align:top}
    .errors{color:var(--p1)}
    """
  end
end
