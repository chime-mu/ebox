defmodule Ebox.FakeDigitalPost do
  @moduledoc false
  # A stand-in for Digital Post's view-client API (gateway.digitalpost.dk/apis/v1)
  # and its token endpoint, shaped after the OpenAPI description published by
  # the Agency for Digital Government and responses observed from production.
  # Refresh tokens do not rotate; access tokens are numbered per renewal.

  import Plug.Conn

  @personal "11111111-1111-1111-1111-111111111111"
  @company "22222222-2222-2222-2222-222222222222"
  @inbox "aaaaaaaa-0000-0000-0000-000000000001"
  @company_inbox "bbbbbbbb-0000-0000-0000-000000000001"

  def personal, do: @personal
  def company, do: @company
  def inbox, do: @inbox

  def start(opts \\ []) do
    {:ok, agent} =
      Agent.start_link(fn ->
        %{
          generation: 0,
          code_challenge: nil,
          refresh_valid: true,
          revoke_access_next: false,
          throttle_next: 0,
          renewals: 0,
          messages: opts[:messages] || default_messages(),
          writes: 0,
          eboks: Ebox.FakeEboksApi.initial(opts)
        }
      end)

    Req.Test.stub(Ebox, &call(&1, agent))
    agent
  end

  def get(agent, key), do: Agent.get(agent, &Map.fetch!(&1, key))
  def expire_login(agent), do: Agent.update(agent, &%{&1 | refresh_valid: false})
  def revoke_access(agent), do: Agent.update(agent, &%{&1 | revoke_access_next: true})
  def throttle(agent, n), do: Agent.update(agent, &%{&1 | throttle_next: n})

  def expect_code_challenge(agent, url) do
    %{"code_challenge" => challenge} = URI.decode_query(URI.parse(url).query)
    Agent.update(agent, &%{&1 | code_challenge: challenge})
  end

  @doc "Tokens as stored on disk after the given number of renewals."
  def tokens(n),
    do: %{"access_token" => "access-#{n}", "refresh_token" => "refresh", "expires_in" => 1199}

  defp call(%{host: "digitalpost.dk", request_path: "/auth/oauth/token"} = conn, agent) do
    conn = fetch_query_params(conn)
    {:ok, body, conn} = read_body(conn)
    params = Map.merge(conn.query_params, URI.decode_query(body))
    ["Basic " <> basic] = get_req_header(conn, "authorization")
    "e-boks-mobile:" <> _ = Base.decode64!(basic)

    case params["grant_type"] do
      "authorization_code" ->
        challenge =
          Base.url_encode64(:crypto.hash(:sha256, params["code_verifier"]), padding: false)

        if params["code"] == "the-code" and challenge == get(agent, :code_challenge),
          do: Req.Test.json(conn, tokens(0)),
          else: error(conn, 400, "invalid_grant")

      "refresh_token" ->
        if params["refresh_token"] == "refresh" and get(agent, :refresh_valid) do
          n =
            Agent.get_and_update(
              agent,
              &{&1.generation + 1,
               %{&1 | generation: &1.generation + 1, renewals: &1.renewals + 1}}
            )

          # The real service sends the same refresh token back.
          Req.Test.json(conn, tokens(n))
        else
          error(conn, 400, "invalid_grant")
        end
    end
  end

  defp call(%{host: "gateway.digitalpost.dk", request_path: "/apis/v1" <> path} = conn, agent) do
    conn = fetch_query_params(conn)
    expected = "Bearer access-#{get(agent, :generation)}"

    revoked? =
      Agent.get_and_update(agent, &{&1.revoke_access_next, %{&1 | revoke_access_next: false}})

    throttled? =
      Agent.get_and_update(
        agent,
        &{&1.throttle_next > 0, %{&1 | throttle_next: max(&1.throttle_next - 1, 0)}}
      )

    cond do
      throttled? ->
        conn |> put_resp_header("retry-after", "0") |> send_resp(429, "")

      revoked? or get_req_header(conn, "authorization") != [expected] ->
        conn |> put_status(401) |> Req.Test.json(%{error: "Unauthorized", status: 401})

      conn.method == "PATCH" ->
        Agent.update(agent, &%{&1 | writes: &1.writes + 1})
        patch(String.split(path, "/", trim: true), conn, agent)

      conn.method != "GET" ->
        Agent.update(agent, &%{&1 | writes: &1.writes + 1})
        send_resp(conn, 405, "")

      true ->
        route(String.split(path, "/", trim: true), conn, agent)
    end
  end

  # Hosts of the e-Boks JSON API and its login.
  defp call(conn, agent), do: Ebox.FakeEboksApi.call(conn, agent)

  defp route(["mailboxes"], conn, _agent) do
    page(conn, "mailboxes", [
      %{id: @company, ownerType: "ORGANISATION", ownerName: "Firma ApS"},
      %{id: @personal, ownerType: "CITIZEN", ownerName: "Søren Ærø"}
    ])
  end

  defp route(["mailboxes", mailbox, "folders"], conn, _agent) do
    inbox = if mailbox == @personal, do: @inbox, else: @company_inbox

    page(conn, "folders", [
      %{id: inbox, folderType: "INBOX", name: "Indbakke", mailboxId: mailbox},
      %{id: inbox <> "-x", folderType: "USER_DEFINED", name: "Skat/2025", mailboxId: mailbox}
    ])
  end

  defp route(["mailboxes", mailbox, "messages"], conn, agent) do
    %{"page" => page, "size" => size, "sortFields" => "receivedDateTime:desc"} = conn.query_params

    all =
      agent
      |> get(:messages)
      |> Enum.filter(&(&1.mailboxId == mailbox))
      |> Enum.filter(&(conn.query_params["folderId"] in [nil, &1.folderId]))

    {page, size} = {String.to_integer(page), String.to_integer(size)}
    page(conn, "messages", Enum.slice(all, page * size, size))
  end

  defp route(["mailboxes", mailbox, "messages", id], conn, agent) do
    case find(agent, mailbox, id) do
      nil -> error(conn, 404, "not_found")
      message -> Req.Test.json(conn, message)
    end
  end

  defp route(
         [
           "mailboxes",
           _mailbox,
           "messages",
           message,
           "documents",
           document,
           "files",
           file,
           "content"
         ],
         conn,
         _agent
       ) do
    conn
    |> put_resp_content_type("application/pdf")
    |> send_resp(200, pdf(message, document, file))
  end

  # PATCH a message: If-Match must name its current version; each change
  # increments it, as the real service does.
  defp patch(["mailboxes", mailbox, "messages", id], conn, agent) do
    {:ok, body, conn} = read_body(conn)
    changes = JSON.decode!(body)

    case find(agent, mailbox, id) do
      nil ->
        error(conn, 404, "not_found")

      message ->
        if get_req_header(conn, "if-match") != [to_string(message.version)] do
          error(conn, 409, "version_conflict")
        else
          updated =
            Enum.reduce(changes, %{message | version: message.version + 1}, fn
              {"folderId", f}, m -> %{m | folderId: f}
              {"read", r}, m -> %{m | read: r}
              {k, v}, m -> Map.put(m, String.to_atom(k), v)
            end)

          Agent.update(agent, fn state ->
            %{state | messages: Enum.map(state.messages, &if(&1.id == id, do: updated, else: &1))}
          end)

          Req.Test.json(conn, updated)
        end
    end
  end

  defp patch(_, conn, _agent), do: send_resp(conn, 405, "")

  defp find(agent, mailbox, id),
    do: Enum.find(get(agent, :messages), &(&1.mailboxId == mailbox and &1.id == id))

  # The main document's body matches the fileSize the listing advertises.
  def pdf(message, document, file) do
    body = "%PDF-1.7 #{message}/#{document}/#{file}"
    if String.ends_with?(document, "b"), do: body, else: String.pad_trailing(body, 1234)
  end

  defp page(conn, key, items) do
    Req.Test.json(conn, %{key => items, "currentPage" => 0, "totalElements" => length(items)})
  end

  defp error(conn, status, code), do: conn |> put_status(status) |> Req.Test.json(%{error: code})

  def message(n, opts \\ []) do
    mailbox = opts[:mailbox] || @personal
    folder = opts[:folder] || if(mailbox == @personal, do: @inbox, else: @company_inbox)

    %{
      id: "msg-#{n}",
      mailboxId: mailbox,
      folderId: folder,
      label: opts[:label] || "Brev #{n}",
      sender: %{label: opts[:sender] || "Skattestyrelsen"},
      receivedDateTime:
        "2026-10-#{String.pad_leading(to_string(rem(n, 28) + 1), 2, "0")}T09:30:00.123Z",
      read: Keyword.get(opts, :read, false),
      replyByDateTime: opts[:reply_by],
      legallyNotified: false,
      version: 1,
      documents: [
        %{
          id: "doc-#{n}",
          documentType: "MAIN",
          files: [
            %{
              id: "file-#{n}",
              filename: "brev.pdf",
              encodingFormat: "application/pdf",
              fileSize: 1234
            }
          ]
        }
        | if(opts[:attachment],
            do: [
              %{
                id: "doc-#{n}b",
                documentType: "ATTACHMENT",
                files: [
                  %{id: "file-#{n}b", filename: "bilag.pdf", encodingFormat: "application/pdf"}
                ]
              }
            ],
            else: []
          )
      ]
    }
  end

  defp default_messages do
    [
      message(1, attachment: true, reply_by: "2026-12-01T00:00:00Z"),
      message(2, read: true, sender: "Halsnæs Kommune", label: "../../etc/passwd"),
      message(3, mailbox: @company, sender: "Erhvervsstyrelsen", label: "Årsrapport")
    ]
  end
end
