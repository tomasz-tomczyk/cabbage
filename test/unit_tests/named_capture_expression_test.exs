defmodule Cabbage.Feature.NamedCaptureExpressionTest do
  use ExUnit.Case, async: true

  doctest Cabbage.Feature.NamedCaptureExpression

  alias Cabbage.Feature.NamedCaptureExpression

  describe "converting {name:type} expressions to a named-capture regex" do
    test "a plain string with no parameter is anchored verbatim" do
      assert NamedCaptureExpression.to_regex_string("simple string") == ~S/^simple string$/
    end

    test "a single {name:int} becomes a named integer capture" do
      assert NamedCaptureExpression.to_regex_string("{quantity:int} string") ==
               ~S/^(?<quantity>\d+) string$/
    end

    test "two integer parameters each get their own named capture" do
      assert NamedCaptureExpression.to_regex_string("{tea_count:int} tea and {coffee_count:int} coffee") ==
               ~S/^(?<tea_count>\d+) tea and (?<coffee_count>\d+) coffee$/
    end

    test "a {name:float} becomes a named float capture" do
      assert NamedCaptureExpression.to_regex_string("It cost $ {cost:float}") ==
               ~S/^It cost $ (?<cost>\d+\.\d+)$/
    end

    test "mixed int and float parameters" do
      assert NamedCaptureExpression.to_regex_string("It cost $ {price:int} or $ {cost:float} to be precise") ==
               ~S/^It cost $ (?<price>\d+) or $ (?<cost>\d+\.\d+) to be precise$/
    end

    test "a {name:word} capture" do
      assert NamedCaptureExpression.to_regex_string("My name is {name:word} I tell you!") ==
               ~S/^My name is (?<name>\w*\S) I tell you!$/
    end

    test "a {name:string} capture" do
      assert NamedCaptureExpression.to_regex_string("My full name is {full_name:string} I tell you!") ==
               ~S/^My full name is (?<full_name>"(.*)") I tell you!$/
    end

    test "the produced regex compiles and binds the named capture" do
      regex_string = NamedCaptureExpression.to_regex_string("{count:int} rows")
      regex = Regex.compile!(regex_string)
      assert Regex.named_captures(regex, "42 rows") == %{"count" => "42"}
    end
  end
end
