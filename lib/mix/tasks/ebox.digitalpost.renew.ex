defmodule Mix.Tasks.Ebox.Digitalpost.Renew do
  @shortdoc "Renews the stored Digital Post login"

  @moduledoc """
  Renews the stored Digital Post login without reading mail.

      mix ebox.digitalpost.renew

  Every other Digital Post task renews the login as well. Run this from a
  scheduled job only if the login turns out to expire when it is left unused.
  """

  use Mix.Task

  alias Ebox.{CLI, DigitalPost}

  @impl true
  def run(_args) do
    CLI.start()

    case DigitalPost.renew() do
      :ok ->
        Mix.shell().info(
          "#{DateTime.utc_now() |> DateTime.truncate(:second)} Digital Post login renewed"
        )

      {:error, error} ->
        Mix.raise(Exception.message(error))
    end
  end
end
