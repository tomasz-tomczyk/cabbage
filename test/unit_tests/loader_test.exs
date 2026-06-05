defmodule Cabbage.Feature.LoaderTest do
  use ExUnit.Case, async: true

  alias Cabbage.Feature.Loader

  defp keywords(feature_string) do
    feature_string
    |> Loader.load_from_string()
    |> Map.fetch!(:scenarios)
    |> hd()
    |> Map.fetch!(:steps)
    |> Enum.map(& &1.keyword)
  end

  describe "fix_step_types/1" do
    test "rewrites And to the previous step's keyword" do
      feature = """
      Feature: And handling
        Scenario: uses and
          Given a precondition
          And another precondition
          When something happens
          And something else happens
          Then a result occurs
          And another result occurs
      """

      assert keywords(feature) == ~w(Given Given When When Then Then)
    end

    test "rewrites But to the previous step's keyword" do
      feature = """
      Feature: But handling
        Scenario: uses but
          Given a precondition
          But not this precondition
          When something happens
          But not that thing
          Then a result occurs
          But not that result
      """

      assert keywords(feature) == ~w(Given Given When When Then Then)
    end

    test "chains And and But together inheriting the running keyword" do
      feature = """
      Feature: And/But chaining
        Scenario: mixes and and but
          Given a precondition
          And another precondition
          But not this one
          When something happens
          Then a result occurs
      """

      assert keywords(feature) == ~w(Given Given Given When Then)
    end
  end
end
