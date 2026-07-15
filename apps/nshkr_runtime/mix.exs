defmodule Nshkr.Runtime.MixProject do
  use Mix.Project

  @version "0.1.0"
  @source_url "https://github.com/nshkrdotcom/nshkr"

  def project do
    [
      app: :nshkr_runtime,
      version: @version,
      elixir: "~> 1.19",
      start_permanent: Mix.env() == :prod,
      deps: [],
      source_url: @source_url,
      homepage_url: @source_url,
      name: "NSHKR Runtime",
      description: "Production OTP composition and release application for NSHKR"
    ]
  end

  def application do
    [
      extra_applications: [:logger],
      mod: {Nshkr.Runtime.Application, []}
    ]
  end
end
