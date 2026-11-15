defmodule Ebox.FakeEboksApi do
  @moduledoc false
  # A stand-in for the e-Boks mobile JSON API (mobile-api-dk.e-boks.com/2) and
  # the token chain into it, shaped after the routes in the e-Boks Android app
  # and responses observed from production. It lives inside FakeDigitalPost's
  # agent (key :eboks), because the e-Boks token is made from a Digital Post
  # access token.

  import Plug.Conn

  @own_inbox 10
  @share 777

  def share_user_id, do: @share

  def initial(opts) do
    %{
      device_id: opts[:device_id],
      messages: opts[:eboks_messages] || default_messages(),
      writes: [],
      content_reads: []
    }
  end

  def call(%{host: "digitalpostproxy.e-boks.dk"} = conn, agent) do
    "/loginservice/v2/connect/usertoken" = conn.request_path
    expected = "Bearer access-#{Agent.get(agent, & &1.generation)}"

    case {get_req_header(conn, "authorization"), get_req_header(conn, "content-length")} do
      {[^expected], [_]} -> Req.Test.json(conn, %{userToken: "user-token"})
      {[^expected], []} -> send_resp(conn, 411, "Length Required")
      _ -> send_resp(conn, 401, "")
    end
  end

  def call(%{host: "oauth-dk.e-boks.com", request_path: "/1/connect/token"} = conn, agent) do
    {:ok, body, conn} = read_body(conn)
    form = URI.decode_query(body)
    device_id = Agent.get(agent, & &1.eboks.device_id)

    if form["grant_type"] == "usertoken" and form["usertoken"] == "user-token" and
         form["deviceid"] == device_id do
      Req.Test.json(conn, %{
        access_token: "eboks-access",
        refresh_token: "eboks-refresh",
        expires_in: 300,
        token_type: "Bearer"
      })
    else
      send_resp(conn, 400, "")
    end
  end

  def call(%{host: "mobile-api-dk.e-boks.com", request_path: "/2/" <> path} = conn, agent) do
    conn = fetch_query_params(conn)

    if get_req_header(conn, "authorization") == ["Bearer eboks-access"] do
      user = conn.query_params["userId"] || "own"
      route(conn.method, String.split(path, "/", trim: true), user, conn, agent)
    else
      send_resp(conn, 401, "")
    end
  end

  defp route("GET", ["user", "profile"], _, conn, _),
    do: Req.Test.json(conn, %{name: "Søren Ærø", identity: "0101901234"})

  defp route("GET", ["mail", "shares"], _, conn, _) do
    Req.Test.json(conn, [
      %{userId: @share, name: "Firma ApS", permission: "Administration", status: "Accepted"},
      %{userId: 888, name: "Pending ApS", permission: "Read", status: "Pending"}
    ])
  end

  defp route("GET", ["mail", "folders"], "own", conn, _) do
    Req.Test.json(conn, [
      %{id: @own_inbox, name: "Indbakke", type: "inbox", unreadCount: 1, folders: []},
      %{
        id: 20,
        name: "Bank",
        type: "folder",
        folders: [%{id: 21, name: "Konto/udtog", type: "folder", parent: %{id: 20}}]
      },
      %{id: 30, name: "Tom", type: "folder", folders: []},
      %{id: 40, name: "Slettet post", type: "deleteditems", folders: []}
    ])
  end

  defp route("GET", ["mail", "folders"], _share, conn, _) do
    Req.Test.json(conn, [
      %{id: 50, name: "Indbakke", type: "inbox", folders: []},
      %{id: 51, name: "Diverse", type: "folder", folders: []}
    ])
  end

  defp route("GET", ["mail", "folders", folder, "messages"], user, conn, agent) do
    offset = String.to_integer(conn.query_params["offset"] || "0")
    limit = String.to_integer(conn.query_params["limit"] || "100")
    all = for m <- messages(agent), m.user == user, to_string(m.folderId) == folder, do: m

    Req.Test.json(conn, %{
      items: all |> Enum.slice(offset, limit) |> Enum.map(&listed/1),
      metadata: %{total: length(all), unreadCount: Enum.count(all, & &1.unread)}
    })
  end

  defp route("GET", ["mail", "folders", folder, "messages", id], user, conn, agent) do
    case find(agent, user, folder, id) do
      nil ->
        send_resp(conn, 404, "")

      m ->
        Req.Test.json(
          conn,
          Map.drop(m, [:user, :folderId]) |> Map.put(:folder, %{id: m.folderId})
        )
    end
  end

  defp route("GET", ["mail", "folders", folder, "messages", id, "content"], user, conn, agent) do
    content(conn, agent, user, folder, id, nil)
  end

  defp route(
         "GET",
         ["mail", "folders", f, "messages", id, "attachment", att, "content"],
         u,
         conn,
         agent
       ) do
    content(conn, agent, u, f, id, att)
  end

  defp route("POST", ["mail", "folders", folder, "messages", id], user, conn, agent) do
    {:ok, body, conn} = read_body(conn)
    patch = JSON.decode!(body)

    Agent.update(agent, fn state ->
      eboks = state.eboks

      messages =
        Enum.map(eboks.messages, fn m ->
          if m.user == user and to_string(m.folderId) == folder and m.id == id do
            m
            |> then(
              &if(Map.has_key?(patch, "unread"), do: %{&1 | unread: patch["unread"]}, else: &1)
            )
            |> then(&if(patch["folderId"], do: %{&1 | folderId: patch["folderId"]}, else: &1))
          else
            m
          end
        end)

      %{state | eboks: %{eboks | messages: messages, writes: eboks.writes ++ [{user, id, patch}]}}
    end)

    send_resp(conn, 204, "")
  end

  # Downloading marks the message read, as the real service does.
  defp content(conn, agent, user, folder, id, att) do
    case find(agent, user, folder, id) do
      nil ->
        send_resp(conn, 404, "")

      m ->
        Agent.update(agent, fn state ->
          eboks = state.eboks

          messages =
            Enum.map(
              eboks.messages,
              &if(&1.id == id and &1.user == user, do: %{&1 | unread: false}, else: &1)
            )

          %{
            state
            | eboks: %{
                eboks
                | messages: messages,
                  content_reads: eboks.content_reads ++ [{user, id, att}]
              }
          }
        end)

        conn |> put_resp_content_type("application/pdf") |> send_resp(200, body(m, att))
    end
  end

  def body(m, nil), do: String.pad_trailing("%PDF-1.4 #{m.id}", m.content.fileSize)

  def body(m, att) do
    a = Enum.find(m.attachments, &(to_string(&1.id) == att))
    String.pad_trailing("%PDF-1.4 #{m.id}/#{att}", a.fileSize)
  end

  defp find(agent, user, folder, id),
    do:
      Enum.find(
        messages(agent),
        &(&1.user == user and to_string(&1.folderId) == folder and &1.id == id)
      )

  defp messages(agent), do: Agent.get(agent, & &1.eboks.messages)
  def writes(agent), do: Agent.get(agent, & &1.eboks.writes)
  def content_reads(agent), do: Agent.get(agent, & &1.eboks.content_reads)
  def get_message(agent, id), do: Enum.find(messages(agent), &(&1.id == id))

  defp listed(m),
    do:
      m |> Map.drop([:user, :attachments]) |> Map.put(:numberOfAttachments, length(m.attachments))

  def message(id, opts \\ []) do
    %{
      id: id,
      user: opts[:user] || "own",
      folderId: opts[:folder] || @own_inbox,
      subject: opts[:subject] || "Brev #{id}",
      sender: %{id: 1, name: opts[:sender] || "Banken A/S"},
      received: opts[:received] || "2025-05-04T10:00:00",
      unread: Keyword.get(opts, :unread, false),
      content: %{
        id: id,
        title: "Brev",
        fileExtension: "PDF",
        mimeType: "application/pdf",
        fileSize: 40
      },
      attachments:
        for {aid, title} <- opts[:attachments] || [] do
          %{
            id: aid,
            title: title,
            fileExtension: "PDF",
            mimeType: "application/pdf",
            fileSize: 50
          }
        end
    }
  end

  defp default_messages do
    [
      message("E1", folder: @own_inbox, unread: true),
      message("E2", folder: 21, attachments: [{901, "Bilag"}, {902, "Bilag"}]),
      message("E3", folder: 21, unread: true, subject: "../../etc/passwd"),
      message("E4", user: to_string(@share), folder: 51, sender: "Kreditinfo A/S")
    ]
  end
end
