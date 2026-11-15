defmodule Ebox.HTTP do
  @moduledoc false
  # One place to build Req requests so tests can swap the transport with
  # `config :ebox, req_options: [plug: ...]`.

  def new(options \\ []) do
    [retry: false, redirect: false, user_agent: "ebox-elixir"]
    |> Keyword.merge(options)
    |> Keyword.merge(Application.get_env(:ebox, :req_options, []))
    |> Req.new()
  end
end
