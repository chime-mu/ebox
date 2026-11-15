defmodule Ebox.Device do
  @moduledoc """
  The local "device" identity that e-Boks knows this connector as.

  e-Boks authenticates its mobile clients with a device id plus an RSA key whose
  public half is registered on your account (see `Ebox.Auth`). A device is
  generated once per installation and stored under `~/.config/ebox/`
  (`$EBOX_HOME` or `$XDG_CONFIG_HOME/ebox` override the location):

    * `device.json` – device id, CPR number, name and the login signature hash that worked
    * `device_key.pem` – the RSA private key

  Both files are written with mode `0600`. The mobile-access password is never
  stored.
  """

  @derive {Inspect, except: [:private_key, :cpr]}
  defstruct [:id, :private_key, :cpr, :name, :sig_hash, activated: false]

  @type t :: %__MODULE__{
          id: String.t(),
          private_key: tuple(),
          cpr: String.t() | nil,
          name: String.t() | nil,
          sig_hash: :sha | :sha256 | nil,
          activated: boolean()
        }

  @doc "Generates a fresh device id and 2048-bit RSA key (nothing is written to disk)."
  @spec generate() :: t()
  def generate do
    %__MODULE__{
      id: uuid(),
      private_key: :public_key.generate_key({:rsa, 2048, 65_537})
    }
  end

  @doc "The public key as e-Boks wants it: base64 of the DER SubjectPublicKeyInfo."
  @spec public_key(t()) :: String.t()
  def public_key(%__MODULE__{private_key: key}) do
    public = {:RSAPublicKey, elem(key, 2), elem(key, 3)}
    {:SubjectPublicKeyInfo, der, _} = :public_key.pem_entry_encode(:SubjectPublicKeyInfo, public)
    Base.encode64(der)
  end

  @doc "RSA PKCS#1 v1.5 signature of `data`, base64 encoded."
  @spec sign(t(), binary(), :sha | :sha256) :: String.t()
  def sign(%__MODULE__{private_key: key}, data, hash) do
    data |> :public_key.sign(hash, key) |> Base.encode64()
  end

  @doc "Directory holding the device files."
  @spec dir() :: Path.t()
  def dir do
    cond do
      home = System.get_env("EBOX_HOME") -> home
      xdg = System.get_env("XDG_CONFIG_HOME") -> Path.join(xdg, "ebox")
      true -> Path.join([System.user_home!(), ".config", "ebox"])
    end
  end

  @spec load(Path.t()) :: {:ok, t()} | {:error, :not_found | term()}
  def load(dir \\ dir()) do
    with {:ok, json} <- File.read(Path.join(dir, "device.json")),
         {:ok, pem} <- File.read(Path.join(dir, "device_key.pem")),
         {:ok, meta} <- JSON.decode(json),
         [entry | _] <- :public_key.pem_decode(pem) do
      {:ok,
       %__MODULE__{
         id: meta["device_id"],
         cpr: meta["cpr"],
         name: meta["name"],
         sig_hash: sig_hash(meta["sig_hash"]),
         activated: meta["activated"] == true,
         private_key: :public_key.pem_entry_decode(entry)
       }}
    else
      {:error, :enoent} -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
      [] -> {:error, :invalid_key_file}
    end
  end

  @spec save(t(), Path.t()) :: :ok
  def save(%__MODULE__{} = device, dir \\ dir()) do
    File.mkdir_p!(dir)
    File.chmod!(dir, 0o700)

    pem =
      :public_key.pem_encode([:public_key.pem_entry_encode(:RSAPrivateKey, device.private_key)])

    meta =
      JSON.encode!(%{
        device_id: device.id,
        cpr: device.cpr,
        name: device.name,
        sig_hash: device.sig_hash,
        activated: device.activated
      })

    write_private!(Path.join(dir, "device_key.pem"), pem)
    write_private!(Path.join(dir, "device.json"), meta)
  end

  defp sig_hash("sha"), do: :sha
  defp sig_hash("sha256"), do: :sha256
  defp sig_hash(_), do: nil

  # Create with 0600 before any secret is written into the file.
  defp write_private!(path, content) do
    File.touch!(path)
    File.chmod!(path, 0o600)
    File.write!(path, content)
  end

  defp uuid do
    <<a::32, b::16, _::4, c::12, _::2, d::14, e::48>> = :crypto.strong_rand_bytes(16)

    [<<a::32>>, <<b::16>>, <<4::4, c::12>>, <<2::2, d::14>>, <<e::48>>]
    |> Enum.map_join("-", &Base.encode16/1)
  end
end
