defmodule Ebox.MixProject do
  use Mix.Project

  def project do
    [
      app: :ebox,
      version: "0.1.0",
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      elixirc_paths: if(Mix.env() == :test, do: ["lib", "test/support"], else: ["lib"]),
      deps: deps()
    ]
  end

  def application do
    [extra_applications: [:logger, :crypto, :public_key, :xmerl]]
  end

  defp deps do
    [
      {:req, "~> 0.7.5"},
      {:plug, "~> 1.16", only: :test}
    ]
  end
end
