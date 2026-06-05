defmodule Cabbage.Feature.ParameterTest do
  use ExUnit.Case, async: true

  alias Cabbage.Feature.Parameter

  describe "converting cucumber expression term to parameter" do
    test "term in the form of {name:type} returns a parameter" do
      term = "{name:int}"
      result = Parameter.convert(term)
      # Compare the regex by source rather than by struct equality: since Elixir 1.19
      # two `Regex` structs built from separate compilations no longer compare equal
      # (the embedded compiled pattern differs), so `== %Parameter{type_regex: ~r/\d+/}`
      # is unreliable across versions.
      assert %Cabbage.Feature.Parameter{capture_name: "name", type_regex: type_regex} = result
      assert Regex.source(type_regex) == "\\d+"
    end

    test "term not in the form of a parameter returns itself" do
      term = "coffee"
      result = Parameter.convert(term)
      assert result == "coffee"
    end
  end
end
