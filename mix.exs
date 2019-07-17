defmodule Membrane.Protocol.Icecast.MixProject do
  use Mix.Project

  def project do
    [
      app: :membrane_protocol_icecast,
      version: "0.1.0",
      elixir: "~> 1.8",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger],
      mod: {Membrane.Protocol.Icecast.Application, []}
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:ranch, "~> 1.7"},
      {:castore, "~> 0.1.0", only: :test},
      {:mint, "~> 0.2.0", only: :test},
      {:dialyxir, "~> 0.4", only: [:dev]}
    ]
  end
end
