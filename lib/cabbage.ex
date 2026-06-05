defmodule Cabbage do
  @moduledoc """
  A spec-conformant Cucumber runner for Elixir.

  `Cabbage.Feature` compiles Gherkin `.feature` files into ExUnit tests; this module holds
  the small amount of application configuration the loader reads (`:features`, `:global_tags`).
  """

  @doc "The directory feature files are loaded from (config `:cabbage, :features`)."
  @spec base_path() :: String.t()
  def base_path(), do: Application.get_env(:cabbage, :features, "test/features/")

  @doc "Tags applied to every generated scenario (config `:cabbage, :global_tags`)."
  @spec global_tags() :: [atom() | String.t()]
  def global_tags(), do: Application.get_env(:cabbage, :global_tags, []) |> List.wrap()
end
