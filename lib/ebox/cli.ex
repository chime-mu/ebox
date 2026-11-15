defmodule Ebox.CLI do
  @moduledoc false
  # Shared plumbing for the mix tasks.

  def start do
    {:ok, _} = Application.ensure_all_started(:ebox)
    :ok
  end

  @doc """
  The e-Boks mobile-access password, needed once by `mix ebox.auth`: from
  $EBOX_PASSWORD, or an interactive prompt without echo.
  """
  def password do
    case System.get_env("EBOX_PASSWORD") do
      password when is_binary(password) and password != "" -> password
      _ -> prompt_hidden("e-Boks mobile-access password: ")
    end
  end

  @doc """
  Opens the connections the tasks work with: Digital Post and e-Boks (both
  from the one stored login), or only the one named by `--only`.
  """
  def connect_sources!(only \\ nil) do
    dp = ok!(Ebox.DigitalPost.connect())

    case only do
      nil -> %{digitalpost: dp, eboks: ok!(Ebox.Eboks.connect(digitalpost: dp))}
      "digitalpost" -> %{digitalpost: dp}
      "e-boks" -> %{eboks: ok!(Ebox.Eboks.connect(digitalpost: dp))}
      other -> Mix.raise("--only takes e-boks or digitalpost, not #{inspect(other)}")
    end
  end

  def ok!(:ok), do: :ok
  def ok!({:ok, value}), do: value
  def ok!({:error, error}), do: Mix.raise(Exception.message(error))

  defp prompt_hidden(prompt) do
    tty? =
      match?({_, 0}, System.cmd("sh", ["-c", "stty -echo < /dev/tty"], stderr_to_stdout: true))

    try do
      case IO.gets(prompt) do
        value when is_binary(value) -> String.trim_trailing(value, "\n")
        _ -> Mix.raise("no password given (set EBOX_PASSWORD for non-interactive use)")
      end
    after
      if tty? do
        System.cmd("sh", ["-c", "stty echo < /dev/tty"], stderr_to_stdout: true)
        IO.puts("")
      end
    end
  end
end
