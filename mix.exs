defmodule NPlusOneDetector.MixProject do
  use Mix.Project

  def project do
    [
      app: :n_plus_one_detector,
      version: "0.1.0",
      elixir: "~> 1.14",
      start_permanent: Mix.env() == :prod,
      description: "N+1 query detector for Ecto test suites with surgical per-line CI failure",
      package: package(),
      deps: deps()
    ]
  end

  def application do
    [extra_applications: [:logger]]
  end

  defp deps do
    [
      {:ecto, "~> 3.0", only: [:dev, :test]},
      {:ex_doc, "~> 0.34", only: :dev, runtime: false}
    ]
  end

  defp package do
    [
      licenses: ["MIT"],
      links: %{"GitHub" => "https://github.com/stordco/elixir-n-plus-1-detector"}
    ]
  end
end
