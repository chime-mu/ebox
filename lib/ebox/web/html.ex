defmodule Ebox.Web.Html do
  @moduledoc false
  # The pages of Ebox.Web, as plain server-rendered HTML: a list of letters on
  # the left, the open letter on the right. Everything works without
  # JavaScript; `Ebox.Web.Js` only makes opening and filing smoother.

  alias Ebox.{Evaluate, Letter}

  @groups [
    {1, "Urgent and important", "p1"},
    {2, "Important", "p2"},
    {3, "Urgent", "p3"},
    {4, "Neither urgent nor important", "p4"}
  ]

  @months ~w(Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec)

  # ---------------------------------------------------------------- pages

  @doc "The inbox with no letter open."
  def index(overview, job, msg, secret),
    do: shell(overview, job, msg, secret, nil, start(overview), "Post")

  @doc "The inbox with one letter open (any letter of the archive)."
  def letter(%Letter{} = l, overview, ctx, n, msg, secret, job),
    do: shell(overview, job, msg, secret, l, pane(l, ctx, n, secret), l.title)

  defp shell(overview, job, msg, secret, selected, pane, title) do
    today = Date.utc_today()
    sel = selected && selected.key

    page(
      title,
      """
      #{topbar(:inbox)}
      <div class="desk#{if selected, do: " has-letter", else: ""}">
        <nav id="list" class="list" aria-label="Letters">
          #{job_bar(overview, job, secret)}
          #{groups(overview, today, sel)}
          #{routine(overview.routine, secret, sel, today)}
        </nav>
        <main id="pane" class="pane">#{pane}</main>
      </div>
      #{toast(msg)}
      """,
      :app
    )
  end

  defp topbar(current) do
    link = fn id, href, text ->
      cur = if id == current, do: ~s( aria-current="page"), else: ""
      ~s(<a href="#{href}"#{cur}>#{text}</a>)
    end

    """
    <header class="top">
      <a class="brand" href="/">Post</a>
      <nav>#{link.(:inbox, "/", "Inbox")}#{link.(:rules, "/rules", "Rules")}</nav>
    </header>
    """
  end

  defp toast(nil), do: ~s(<div id="toast" class="toast" role="status"></div>)
  defp toast(msg), do: ~s(<div id="toast" class="toast show" role="status">#{e(msg)}</div>)

  # ----------------------------------------------------------------- list

  defp job_bar(overview, job, secret) do
    bar =
      cond do
        job.running ->
          ~s(<p id="job" class="job" data-running>Claude is reading: #{job.done} of #{job.total} done</p>)

        overview.unevaluated > 0 ->
          """
          <form class="job" method="post" action="/evaluate">#{t(secret)}
            <span>#{plural(overview.unevaluated, "letter has", "letters have")} not been read by Claude.</span>
            <button>Let Claude read them</button>
          </form>
          """

        true ->
          ""
      end

    errors =
      if job.errors != [] do
        items =
          Enum.map_join(job.errors, "", fn {title, text} ->
            "<li>#{e(title)}: #{e(text)}</li>"
          end)

        ~s(<details class="job errors"><summary>#{plural(length(job.errors), "letter", "letters")} could not be read</summary><ul>#{items}</ul></details>)
      else
        ""
      end

    bar <> errors
  end

  defp groups(overview, today, sel) do
    {evaluated, pending} = Enum.split_with(overview.judge, &Letter.evaluation/1)
    by = Enum.group_by(evaluated, &Evaluate.priority(&1, today))

    sections =
      for {p, title, cls} <- @groups, letters = by[p] || [], letters != [] do
        group(title, cls, Enum.map_join(letters, "", &row(&1, today, sel)), length(letters))
      end

    sections =
      if pending != [],
        do:
          sections ++
            [
              group(
                "Not read by Claude yet",
                "p0",
                Enum.map_join(pending, "", &row(&1, today, sel)),
                length(pending)
              )
            ],
        else: sections

    if sections == [],
      do: ~s(<p class="empty">Nothing waits for you. Only routine mail is left.</p>),
      else: Enum.join(sections)
  end

  defp group(title, cls, rows, n) do
    """
    <section class="group #{cls}">
      <h2><span class="dot" aria-hidden="true"></span>#{title}<span class="n">#{n}</span></h2>
      #{rows}
    </section>
    """
  end

  defp row(%Letter{} = l, today, sel, extra \\ nil) do
    eval = Letter.evaluation(l) || %{}
    on = if l.key == sel, do: ~s( on" aria-current="true), else: ""

    third =
      cond do
        extra -> ~s(<span class="r3">#{extra}</span>)
        eval["action"] not in [nil, ""] -> ~s(<span class="r3">#{e(eval["action"])}</span>)
        true -> ""
      end

    """
    <a class="row#{on}" href="/letter/#{l.key}" data-key="#{l.key}">
      <span class="r1"><span class="title">#{e(l.title)}</span>#{due_chip(Evaluate.respond_by(l), today)}</span>
      <span class="r2"><span class="from">#{e(l.sender)}</span><span class="when">#{short_date(l.received_at, today)}</span></span>
      #{third}
    </a>
    """
  end

  defp routine([], _, _, _), do: ""

  defp routine(routine, secret, sel, today) do
    rows =
      Enum.map_join(routine, "", fn {l, rule} ->
        row(l, today, sel, "Goes to " <> e(Enum.join(rule["folder"], "/")))
      end)

    n = length(routine)

    """
    <section class="group routine">
      <h2><span class="dot" aria-hidden="true"></span>Routine<span class="n">#{n}</span></h2>
      <p class="aside">A rule knows where these go, and Claude found nothing to do in them. Filing moves them here and in the service; read state stays as it is.</p>
      <form method="post" action="/routine/file">#{t(secret)}<button>File all #{n}</button></form>
      <details><summary>Show them</summary>#{rows}</details>
    </section>
    """
  end

  defp start(overview) do
    n = length(overview.judge)
    first = List.first(overview.judge)

    """
    <div class="start">
      <h2>#{if n == 0, do: "Nothing waits for you.", else: plural(n, "letter waits", "letters wait") <> " for you."}</h2>
      <p>The most pressing are at the top. Read one, then file it or set a reminder, and the next one opens.</p>
      #{if first, do: ~s(<p><a class="button primary" href="/letter/#{first.key}" data-open="#{first.key}">Open the first letter</a></p>), else: ""}
      <p class="keys">Move through the list with <kbd>j</kbd> and <kbd>k</kbd>.</p>
    </div>
    """
  end

  # ------------------------------------------------------------ the letter

  @doc "The open letter: what it is, Claude's reading, actions, and the letter itself."
  def pane(%Letter{} = l, ctx, n, secret) do
    eval = Letter.evaluation(l) || %{}
    today = Date.utc_today()

    folder =
      if Letter.in_inbox?(l),
        do: "Inbox",
        else: e(Enum.join(l.folder, "/"))

    """
    <article class="letter" data-key="#{l.key}" data-f="#{n}">
      <div class="dossier">
        <div class="ident">
        <p class="back"><a href="/#l-#{l.key}">All letters</a></p>
        <h2 class="subject">#{e(l.title)}</h2>
        #{deadline(l, eval, today)}
        <dl class="facts">
          <dt>From</dt><dd>#{e(l.sender)}</dd>
          <dt>To</dt><dd>#{e(l.mailbox)}, #{system(l)}</dd>
          <dt>Received</dt><dd>#{long_date(l.received_at)}</dd>
          <dt>Folder</dt><dd>#{folder}</dd>
          <dt>Ref</dt><dd><code class="ref" title="Use this to ask Claude about the letter">#{Letter.ref(l)}</code></dd>
        </dl>
        </div>
        <div class="work">
        #{note(eval)}
        #{actions(l, ctx, eval, secret)}
        </div>
      </div>
      <div class="reader">
        #{sheetbar(l, n)}
        #{sheet(l, n)}
      </div>
    </article>
    """
  end

  defp deadline(l, eval, today) do
    case Evaluate.respond_by(l) do
      nil ->
        ""

      due ->
        {text, cls} = due_text(due, today)

        basis =
          cond do
            l.reply_by -> "Reply deadline set in Digital Post"
            eval["respondByBasis"] -> eval["respondByBasis"]
            true -> nil
          end

        """
        <p class="deadline #{cls}"><strong>Respond by #{long_date(due)}</strong><span>#{text}</span></p>
        #{if basis, do: ~s(<p class="basis">#{e(basis)}</p>), else: ""}
        """
    end
  end

  defp note(eval) when map_size(eval) == 0,
    do:
      ~s(<section class="note"><p class="quiet-text">Claude has not read this letter yet.</p></section>)

  defp note(eval) do
    imp =
      if eval["important"],
        do: ~s(<p class="imp"><strong>Important.</strong> #{e(eval["importance"])}</p>),
        else: ~s(<p class="notimp"><strong>Not important.</strong> #{e(eval["importance"])}</p>)

    todo =
      if eval["action"] not in [nil, ""],
        do: ~s(<p class="todo">#{e(eval["action"])}</p>),
        else: ~s(<p class="quiet-text">Nothing to do.</p>)

    """
    <section class="note" aria-labelledby="note-h">
      <h3 id="note-h">Claude’s reading</h3>
      <p>#{e(eval["summary"])}</p>
      #{imp}
      #{todo}
    </section>
    """
  end

  defp actions(l, ctx, eval, secret) do
    form = fn action, cls, inner ->
      ~s(<form method="post" action="/letter/#{l.key}/#{action}" class="#{cls}" data-ajax="#{action}" data-key="#{l.key}">#{t(secret)}<input type="hidden" name="from" value="letter">#{inner}</form>)
    end

    reminder = l.meta["reminder"]

    remind =
      form.(
        "reminder",
        "remind",
        ~s(<button data-busy="Adding…">#{if reminder, do: "Remind me again", else: "Remind me"}</button>) <>
          if(reminder,
            do:
              ~s(<span class="done">Reminder set#{if reminder["due"], do: " for " <> e(reminder["due"]), else: ""}</span>),
            else: ""
          )
      )

    evaluate =
      form.(
        "evaluate",
        "again",
        ~s(<button class="quiet" data-busy="Claude is reading…">#{if eval == %{}, do: "Let Claude read it", else: "Read again"}</button>)
      )

    filing =
      if Letter.in_inbox?(l) do
        selected_rule = eval["recurring"] == true and is_nil(ctx.rule)

        form.(
          "file",
          "file",
          """
          <label for="folder-#{l.key}">File in</label>
          <select id="folder-#{l.key}" name="folder" required>#{folder_options(ctx.folders, ctx.suggested)}</select>
          <select name="rule" aria-label="Which letters to file there">
            <option value="">only this letter</option>
            <option value="subject"#{if selected_rule, do: " selected", else: ""}>this and future ones like it</option>
            <option value="sender">everything from #{e(l.sender)}</option>
          </select>
          <button class="primary" data-busy="Filing…">File</button>
          """
        ) <> filing_hints(ctx, eval)
      else
        ""
      end

    """
    <section class="actions">
      #{filing}
      <div class="minor">#{remind}#{evaluate}</div>
    </section>
    """
  end

  defp filing_hints(ctx, eval) do
    [
      if(ctx.rule,
        do: "Letters like this went to #{e(Enum.join(ctx.rule["folder"], "/"))} before.",
        else: nil
      ),
      if(eval["recurring"] && is_nil(ctx.rule),
        do:
          "Claude thinks this comes regularly. Filing future ones like it makes a rule, so they are filed without asking.",
        else: nil
      ),
      case ctx.suggested do
        [_ | _] = s ->
          if s in ctx.folders,
            do: nil,
            else:
              "Claude suggests a new folder, #{e(Enum.join(s, "/"))}. Create it in the app, run mix ebox.archive, then file."

        _ ->
          nil
      end
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.map_join("", &~s(<p class="hint">#{&1}</p>))
  end

  defp folder_options(folders, suggested) do
    selected = if suggested in folders, do: suggested, else: nil

    [
      ~s(<option value="" disabled#{if selected, do: "", else: " selected"}>Choose a folder</option>)
      | for f <- folders do
          path = Enum.join(f, "/")

          ~s(<option value="#{e(path)}"#{if f == selected, do: " selected", else: ""}>#{e(path)}</option>)
        end
    ]
    |> Enum.join()
  end

  defp sheetbar(l, n) do
    tabs =
      l.files
      |> Enum.with_index()
      |> Enum.map_join("", fn {f, i} ->
        label = if i == 0, do: "Letter", else: file_label(f["name"])
        cur = if i == n, do: ~s( aria-current="true"), else: ""

        ~s(<a class="tab" href="/letter/#{l.key}?f=#{i}" data-f="#{i}"#{cur}>#{e(label)}<span class="n">#{ext(f["name"])}, #{size(f["size"])}</span></a>)
      end)

    links =
      case Enum.at(l.files, n) do
        nil ->
          ""

        _ ->
          src = "/letter/#{l.key}/file/#{n}"

          ~s(<span class="filelinks"><a href="#{src}" target="_blank" rel="noopener">Open in new tab</a><a href="#{src}?download=1">Download</a></span>)
      end

    ~s(<div class="sheetbar"><nav class="tabs" aria-label="Letter and attachments">#{tabs}</nav>#{links}</div>)
  end

  defp sheet(l, n) do
    file = Enum.at(l.files, n)
    src = "/letter/#{l.key}/file/#{n}"

    inner =
      cond do
        is_nil(file) ->
          ~s(<p class="sheetmsg">No files were downloaded for this letter.</p>)

        viewable?(file["name"]) ->
          pdf? = file_type(file["name"]) == "application/pdf"
          sandbox = if pdf?, do: "", else: " sandbox"
          # The browser's PDF viewer would fit the whole page into the frame.
          src = if pdf?, do: src <> "#view=FitH&navpanes=0", else: src

          ~s(<p class="sheetmsg" aria-hidden="true">Opening…</p><iframe class="viewer" src="#{src}"#{sandbox} title="#{e(file_label(file["name"]))}"></iframe>)

        true ->
          ~s[<p class="sheetmsg">This file (#{ext(file["name"])}) cannot be shown here. <a href="#{src}?download=1">Download it</a>.</p>]
      end

    ~s(<div class="sheet">#{inner}</div>)
  end

  # ------------------------------------------------------------------ rules

  def rules(rules, msg, secret) do
    rows =
      rules
      |> Enum.with_index()
      |> Enum.map_join("", fn {r, i} ->
        """
        <tr><td>#{e(r["origin"])}</td><td>#{e(r["mailbox"])}</td><td>#{e(r["source"])}</td>
        <td>#{e(r["sender"])}</td><td><code>#{e(r["subject"])}</code></td>
        <td>#{e(Enum.join(r["folder"], "/"))}</td><td>#{r["seen"] || ""}</td>
        <td><form method="post" action="/rules/#{i}/delete">#{t(secret)}<button class="quiet">Remove</button></form></td></tr>
        """
      end)

    page(
      "Rules",
      """
      #{topbar(:rules)}
      <main class="sheetpage">
        <h1>Rules</h1>
        <p>A rule sends letters from a sender, with a subject like the one shown, to a folder. The first rule that matches wins. In subjects, <code>#</code> stands for numbers and month names and <code>*</code> for any subject. <code>mix ebox.rules</code> relearns the learned rules and keeps yours.</p>
        <div class="tablewrap"><table>
          <tr><th>Made by</th><th>Mailbox</th><th>System</th><th>Sender</th><th>Subject</th><th>Folder</th><th>Seen</th><th></th></tr>
          #{rows}
        </table></div>
      </main>
      #{toast(msg)}
      """,
      :plain
    )
  end

  # ---------------------------------------------------------------- files

  @doc "The media type a letter's file is served with."
  def file_type(name) do
    case ext(name) do
      e when e in ~w(htm html) -> "text/html"
      "xml" -> "text/xml"
      "txt" -> "text/plain"
      e when e in ~w(pdf png jpg jpeg gif) -> MIME.from_path(name)
      _ -> "application/octet-stream"
    end
  end

  @doc "A file's name without the letter's own name in front, as shown to the user."
  def file_label(name) do
    case String.split(name, "] - ", parts: 2) do
      [_, rest] -> rest
      _ -> name
    end
  end

  defp viewable?(name), do: file_type(name) != "application/octet-stream"

  defp ext(name), do: name |> Path.extname() |> String.trim_leading(".") |> String.downcase()

  defp size(nil), do: "size unknown"
  defp size(b) when b < 1024, do: "#{b} B"
  defp size(b) when b < 1024 * 1024, do: "#{div(b, 1024)} kB"
  defp size(b), do: "#{Float.round(b / 1024 / 1024, 1)} MB"

  # ------------------------------------------------------------ small parts

  defp due_chip(nil, _), do: ""

  defp due_chip(due, today) do
    {text, cls} = due_text(due, today)
    ~s(<span class="due #{cls}">#{text}</span>)
  end

  defp due_text(due, today) do
    days = Date.diff(due, today)

    cond do
      days < -Evaluate.expired_days() -> {"deadline passed", "expired"}
      days < 0 -> {plural(-days, "day", "days") <> " overdue", "late"}
      days == 0 -> {"due today", "late"}
      days == 1 -> {"due tomorrow", "soon"}
      days <= Evaluate.urgent_days() -> {"due in #{days} days", "soon"}
      true -> {"due #{short_date(due, today)}", "later"}
    end
  end

  defp long_date(nil), do: "unknown"
  defp long_date(%Date{} = d), do: "#{d.day} #{Enum.at(@months, d.month - 1)} #{d.year}"

  defp short_date(nil, _), do: ""

  defp short_date(%Date{} = d, today),
    do:
      if(d.year == today.year,
        do: "#{d.day} #{Enum.at(@months, d.month - 1)}",
        else: long_date(d)
      )

  defp plural(1, one, _), do: "1 #{one}"
  defp plural(n, _, many), do: "#{n} #{many}"

  defp system(%Letter{source: "digitalpost"}), do: "Digital Post"
  defp system(_), do: "e-Boks"

  defp t(secret), do: ~s(<input type="hidden" name="t" value="#{secret}">)

  defp e(nil), do: ""
  defp e(text), do: text |> to_string() |> Plug.HTML.html_escape()

  defp page(title, body, kind) do
    """
    <!doctype html><html lang="en"><head><meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <title>#{e(title)}</title><style>#{css()}</style>
    #{if kind == :app, do: ~s(<script src="/app.js" defer></script>), else: ""}
    </head><body class="#{kind}">#{body}</body></html>
    """
  end

  defp css do
    """
    :root{
      --desk:#E3E7EB;--panel:#F4F6F8;--paper:#FFFFFF;--ink:#17263A;--mute:#5B6878;--line:#CDD4DB;
      --hover:#EAEEF2;--sel:#FFFFFF;--stamp:#B42318;--onstamp:#FFFFFF;--imp:#2B5C9E;--urg:#9A6700;--ok:#2F7D4F;--noteb:#E8EEF5;
      --ui:"Avenir Next","Avenir",-apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif;
      --letter:"Charter","Iowan Old Style",Georgia,serif;
      color-scheme:light dark}
    @media (prefers-color-scheme:dark){:root{
      --desk:#13171C;--panel:#1A1F25;--paper:#FAFAF8;--ink:#E4E9EF;--mute:#93A0AE;--line:#2A313A;
      --hover:#20262D;--sel:#262D36;--stamp:#F07462;--onstamp:#2A0E0A;--imp:#86AEE6;--urg:#D9A441;--ok:#6CC08E;--noteb:#1F2731}}
    *{box-sizing:border-box}
    html,body{margin:0}
    body{background:var(--desk);color:var(--ink);font:15px/1.5 var(--ui);-webkit-font-smoothing:antialiased}
    a{color:inherit}
    :focus-visible{outline:2px solid var(--imp);outline-offset:2px}
    code{font-size:.9em}

    .top{display:flex;align-items:center;justify-content:space-between;padding:10px 20px;background:var(--panel);border-bottom:1px solid var(--line)}
    .brand{font:600 21px/1 var(--letter);text-decoration:none}
    .top nav a{margin-left:18px;color:var(--mute);text-decoration:none;font-size:14px}
    .top nav a[aria-current]{color:var(--ink);font-weight:600}

    body.app{height:100vh;display:flex;flex-direction:column;overflow:hidden}
    .desk{flex:1;min-height:0;display:grid;grid-template-columns:clamp(300px,22vw,460px) 1fr}
    .list{overflow-y:auto;background:var(--panel);border-right:1px solid var(--line);padding:4px 0 48px;overscroll-behavior:contain}
    .pane{overflow-y:auto;min-width:0;overscroll-behavior:contain}

    .job{display:flex;flex-wrap:wrap;gap:8px;align-items:center;margin:12px 16px;padding:10px 12px;border-radius:8px;background:var(--noteb);font-size:13px}
    .job.errors{display:block;color:var(--stamp)}
    .group h2{display:flex;align-items:center;gap:8px;margin:20px 16px 4px;font-size:13px;font-weight:600}
    .group .n{color:var(--mute);font-weight:500;margin-left:auto;font-variant-numeric:tabular-nums}
    .dot{width:8px;height:8px;border-radius:50%;background:var(--mute);flex:none}
    .p1 .dot{background:var(--stamp)}.p2 .dot{background:var(--imp)}.p3 .dot{background:var(--urg)}
    .p0 .dot{background:transparent;box-shadow:inset 0 0 0 1.5px var(--mute)}.routine .dot{background:var(--ok)}
    .aside{margin:0 16px 8px;font-size:13px;color:var(--mute)}
    .routine form{margin:0 16px 8px}
    .routine summary{margin:0 16px;font-size:13px;color:var(--mute);cursor:pointer}
    .empty{margin:24px 16px;color:var(--mute)}

    .row{display:block;padding:9px 16px 10px 13px;border-left:3px solid transparent;text-decoration:none;color:inherit;transition:background-color .12s}
    .row:hover{background:var(--hover)}
    .row.on{background:var(--sel);border-left-color:var(--ink)}
    .r1{display:flex;gap:8px;align-items:flex-start;justify-content:space-between;margin-bottom:2px}
    .title{font-weight:600;line-height:1.3;overflow:hidden;display:-webkit-box;-webkit-box-orient:vertical;-webkit-line-clamp:2;overflow-wrap:anywhere}
    .r2{display:flex;gap:8px;justify-content:space-between;font-size:13px;color:var(--mute)}
    .from{overflow:hidden;white-space:nowrap;text-overflow:ellipsis}.when{flex:none;font-variant-numeric:tabular-nums}
    .r3{display:block;font-size:13px;color:var(--mute);overflow:hidden;white-space:nowrap;text-overflow:ellipsis}
    .row.gone{opacity:0;transition:opacity .18s}

    .due{flex:none;margin-top:1px;font-size:12px;font-weight:600;padding:1px 8px;border-radius:999px;white-space:nowrap}
    .due.late{background:var(--stamp);color:var(--onstamp)}
    .due.soon{color:var(--stamp);box-shadow:inset 0 0 0 1px var(--stamp)}
    .due.later{color:var(--mute);font-weight:500}
    .due.expired{color:var(--mute);font-weight:500;text-decoration:line-through}

    .start{max-width:46ch;margin:14vh auto 0;padding:0 24px}
    .start h2{font:500 30px/1.2 var(--letter);margin:0 0 12px}
    .start p{color:var(--mute)}
    .keys{font-size:13px}
    kbd{font:inherit;font-size:12px;padding:0 6px;border:1px solid var(--line);border-bottom-width:2px;border-radius:4px;background:var(--panel)}

    .letter{display:grid;grid-template-columns:clamp(300px,23vw,460px) 1fr;height:100%}
    .dossier{overflow-y:auto;padding:24px 24px 40px;border-right:1px solid var(--line)}
    .reader{display:flex;flex-direction:column;min-width:0;padding:14px 24px 24px}
    .back{display:none;margin:0 0 12px;font-size:14px}
    .subject{font:600 23px/1.25 var(--letter);margin:0 0 14px;text-wrap:balance}
    .deadline{display:flex;flex-wrap:wrap;gap:4px 10px;align-items:baseline;margin:0;font-size:15px}
    .deadline span{font-size:13px;font-weight:600}
    .deadline.late span,.deadline.soon span{color:var(--stamp)}
    .deadline.expired strong{text-decoration:line-through;color:var(--mute)}
    .deadline.expired span,.deadline.later span{color:var(--mute)}
    .basis{margin:2px 0 0;font-size:13px;color:var(--mute)}
    .facts{display:grid;grid-template-columns:auto 1fr;gap:3px 14px;margin:16px 0;font-size:14px}
    .facts dt{color:var(--mute)}.facts dd{margin:0;min-width:0;overflow-wrap:anywhere}
    .ref{user-select:all}
    .note{background:var(--noteb);border-radius:10px;padding:14px 16px;margin:18px 0;font-size:14px}
    .note h3{margin:0 0 6px;font-size:13px;font-weight:600;color:var(--mute)}
    .note p{margin:0 0 8px}.note p:last-child{margin:0}
    .imp strong{color:var(--stamp)}.notimp strong{color:var(--mute)}
    .todo{font-weight:600}
    .quiet-text{color:var(--mute)}

    .actions{display:grid;gap:12px}
    .file{display:grid;gap:8px}
    .file label{font-size:13px;font-weight:600}
    .minor{display:flex;flex-wrap:wrap;gap:8px;align-items:center}
    .minor form{display:flex;gap:10px;align-items:center;margin:0}
    .hint{margin:0;font-size:13px;color:var(--mute)}
    .done{color:var(--ok);font-size:13px}
    select{font:inherit;font-size:14px;width:100%;padding:6px 8px;border-radius:7px;border:1px solid var(--line);background:var(--panel);color:var(--ink)}
    button,.button{display:inline-block;font:inherit;font-size:14px;font-weight:500;padding:7px 14px;border-radius:7px;border:1px solid var(--line);background:var(--panel);color:var(--ink);cursor:pointer;text-decoration:none}
    button:hover,.button:hover{border-color:var(--mute)}
    .primary{background:var(--ink);border-color:var(--ink);color:var(--panel)}
    .primary:hover{opacity:.9}
    button.quiet{background:transparent;border-color:transparent;color:var(--mute)}
    button.quiet:hover{color:var(--ink)}
    button:disabled{opacity:.6;cursor:progress}

    .sheetbar{display:flex;flex-wrap:wrap;gap:8px 16px;align-items:center;justify-content:space-between;margin-bottom:10px}
    .tabs{display:flex;flex-wrap:wrap;gap:6px}
    .tab{font-size:13px;padding:4px 10px;border-radius:7px;text-decoration:none;color:var(--mute);max-width:320px;overflow:hidden;white-space:nowrap;text-overflow:ellipsis}
    .tab .n{margin-left:6px;opacity:.75}
    .tab:hover{color:var(--ink);background:var(--hover)}
    .tab[aria-current]{color:var(--ink);background:var(--panel);box-shadow:inset 0 0 0 1px var(--line);font-weight:600}
    .filelinks{display:flex;gap:14px;font-size:13px}.filelinks a{color:var(--mute)}
    .sheet{position:relative;flex:1;min-height:420px;background:var(--paper);border-radius:3px;overflow:hidden;
      box-shadow:0 1px 2px rgb(23 38 58/.12),0 12px 32px rgb(23 38 58/.12)}
    .sheet iframe{position:absolute;inset:0;width:100%;height:100%;border:0;background:var(--paper);transition:opacity .22s ease}
    .sheet iframe.pending{opacity:0}
    .sheetmsg{position:absolute;inset:0;display:grid;place-items:center;margin:0;padding:24px;text-align:center;color:#6A7684;font-size:14px}
    @media (prefers-color-scheme:dark){.sheet{box-shadow:0 0 0 1px #000,0 12px 32px rgb(0 0 0/.5)}.sheet iframe{filter:brightness(.93)}}

    .toast{position:fixed;left:50%;bottom:24px;z-index:9;max-width:min(560px,calc(100vw - 32px));padding:10px 16px;border-radius:9px;
      background:var(--ink);color:var(--panel);font-size:14px;box-shadow:0 8px 24px rgb(0 0 0/.2);
      transform:translate(-50%,12px);opacity:0;pointer-events:none;transition:opacity .2s,transform .2s}
    .toast.show{opacity:1;transform:translate(-50%,0)}
    .toast.bad{background:var(--stamp);color:var(--onstamp)}

    .sheetpage{max-width:1180px;margin:0 auto;padding:24px 20px 48px}
    .sheetpage h1{font:600 28px/1.2 var(--letter);margin:0 0 8px}
    .sheetpage > p{max-width:72ch;color:var(--mute)}
    .tablewrap{overflow-x:auto;background:var(--panel);border-radius:10px;border:1px solid var(--line)}
    table{border-collapse:collapse;width:100%;font-size:13px}
    th{font-weight:600;color:var(--mute)}
    td,th{text-align:left;padding:7px 10px;border-bottom:1px solid var(--line);vertical-align:top}
    tr:last-child td{border-bottom:0}

    .work .note{margin-top:0}
    @media (max-width:1100px){
      .letter{display:block;height:auto}
      .dossier{display:grid;grid-template-columns:minmax(0,1fr) minmax(0,1fr);gap:0 28px;border-right:0;overflow:visible;padding-bottom:12px}
      .reader{height:calc(100vh - 60px)}}
    @media (max-width:900px){
      body.app{height:auto;overflow:visible}
      .desk{display:block}
      .list{overflow:visible;border-right:0}
      .desk.has-letter .list,.desk:not(.has-letter) .pane{display:none}
      .back{display:block}
      .dossier{grid-template-columns:minmax(0,1fr)}
      .dossier,.reader{padding-left:16px;padding-right:16px}}
    @media (prefers-reduced-motion:reduce){*{transition:none!important}}
    """
  end
end
