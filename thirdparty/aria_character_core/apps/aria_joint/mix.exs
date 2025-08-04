# Copyright (c) 2025-present K. S. Ernest (iFire) Lee

defmodule AriaJoint.MixProject do
  use Mix.Project

  def project do
    [
      app: :aria_joint,
      version: "0.1.0",
      build_path: "../../_build",
      config_path: "../../config/config.exs",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger],
      mod: {AriaJoint.Application, []}
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:aria_math, in_umbrella: true},
      {:nx, "~> 0.10.0"},
      {:torchx, "~> 0.10"},
    ]
  end
end
