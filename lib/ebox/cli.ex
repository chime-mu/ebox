defmodule Ebox.CLI do
  @moduledoc false
  # Shared plumbing for the mix tasks.

  alias Ebox.Device

  def start do
    {:ok, _} = Application.ensure_all_started(:ebox)
    :ok
  end

  @doc "Password from $EBOX_PASSWORD, or an interactive prompt without echo."
  def password do
    case System.get_env("EBOX_PASSWORD") do
      password when is_binary(password) and password != "" -> password
      _ -> prompt_hidden("e-Boks mobile-access password: ")
    end
  end

  def connect! do
    case Ebox.connect(password: password()) do
      {:ok, box} ->
        remember_sig_hash(box)
        box

      {:error, error} ->
        Mix.raise(Exception.message(error))
    end
  end

  # The first successful login settles which signature hash the server accepts.
  defp remember_sig_hash(box) do
    %{device: device} = Ebox.whoami(box)

    with {:ok, %Device{sig_hash: stored}} when stored != device.sig_hash <- Device.load() do
      Device.save(device)
    end
  end

  def ok!({:ok, value}), do: value
  def ok!({:error, error}), do: Mix.raise(Exception.message(error))

  @doc "Resolves a folder given by id or (case-insensitive) name."
  def folder!(box, wanted, opts) do
    folders = ok!(Ebox.folders(box, opts))
    wanted_down = String.downcase(wanted)

    Enum.find(folders, &(&1.id == wanted)) ||
      Enum.find(folders, &(String.downcase(&1.name || "") == wanted_down)) ||
      Mix.raise(
        "no folder #{inspect(wanted)}; available: " <> Enum.map_join(folders, ", ", & &1.name)
      )
  end

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
