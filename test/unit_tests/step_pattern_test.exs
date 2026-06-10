defmodule Cabbage.StepPatternTest do
  use ExUnit.Case, async: true

  alias Cabbage.StepPattern
  alias Cabbage.CucumberExpression
  alias Cabbage.CucumberExpression.ParameterTypeRegistry

  defp registry, do: ParameterTypeRegistry.new()
  defp classify(pattern), do: StepPattern.classify(pattern, registry())

  describe "classify/2" do
    test "a ~r// regex is passed through verbatim as {:regex, regex}" do
      regex = ~r/^there (is|are) (?<number>\d+) widgets?$/
      assert {:regex, ^regex} = classify(regex)
    end

    test "a binary with a {...} parameter classifies as a cucumber expression" do
      assert {:cucumber_expression, %CucumberExpression{} = expr} = classify("a {int} b")
      assert expr.source == "a {int} b"
    end

    test "a plain binary classifies as an anchored, escaped regex" do
      assert {:regex, %Regex{} = regex} = classify("plain $literal")
      # Matches ONLY the exact text, with the `$` escaped to a literal.
      assert "plain $literal" =~ regex
      refute "plain $literalX" =~ regex
      refute "Xplain $literal" =~ regex
      refute "plain Yliteral" =~ regex
    end

    test "a plain binary escapes every regex metacharacter to match literally" do
      {:regex, regex} = classify("a.b(c)+d*e?f")
      assert "a.b(c)+d*e?f" =~ regex
      refute "axbcd*e?f" =~ regex
    end

    test "a backslash-escaped brace routes to a cucumber expression (literal braces)" do
      # "\\{weird\\}" in Elixir source is the pattern `\{weird\}`; it contains a
      # `{...}` span so the binary-with-braces branch fires, but the braces are
      # escaped, so the compiled expression matches the literal text `{weird}`.
      assert {:cucumber_expression, %CucumberExpression{} = expr} = classify("\\{weird\\}")
      assert CucumberExpression.match(expr, "{weird}") == []
    end

    test "the {name:type} sugar raises a helpful Undefined parameter type error" do
      assert_raise Cabbage.CucumberExpression.Errors.CucumberExpressionError, fn ->
        classify("there are {count:int} rows")
      end
    end
  end
end
