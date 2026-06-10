defmodule Cabbage.Feature do
  @moduledoc """
  An extension on ExUnit to be able to execute feature files.

  > #### Which runner is this? {: .info}
  >
  > `Cabbage.Feature` is the compile-time runner you `use` in a test module — almost
  > certainly the one you want. It is a separate path from `Cabbage.Messages`, the runtime
  > cucumber-messages interpreter the Cucumber Compatibility Kit is graded against.

  ## Configuration

  In `config/test.exs`

      config :cabbage,
        # Default is "test/features/"
        features: "my/path/to/features/"
        # Default is []
        global_tags: :integration

  - `features` - Allows you to specify the location of your feature files. They can be anywhere, but typically are located within the test folder.
  - `global_tags` - Allow you to specify ex unit tag assigned to all cabbage generated tests

  ## Features

  Given a feature file, create a corresponding feature module which references it. Heres an example:

      defmodule MyApp.SomeFeatureTest do
        use Cabbage.Feature, file: "some_feature.feature"

        defgiven ~r/I am given a given statement/, _matched_data, _current_state do
          assert 1 + 1 == 2
          {:ok, %{new: :state}}
        end

        # Patterns may also be string Cucumber Expressions; `{int}` arrives as an
        # integer in the positional matched-data list.
        defwhen "I when execute it {int} times", [times], _current_state do
          assert times >= 0
          nil
        end

        defthen ~r/everything is ok/, _matched_data, _current_state do
          assert true
        end
      end

  This translates loosely into:

      defmodule MyApp.SomeFeatureTest do
        use ExUnit.Case

        test "The name of the scenario here" do
          assert 1 + 1 == 2
          nil
          assert true
        end
      end

  ### Step Patterns

  The first argument to `defgiven/4`, `defwhen/4` and `defthen/4` is a *pattern*.
  It may be either a `~r/regex/` or a string Cucumber Expression. The two differ
  only in how the matched data (the second argument) is shaped.

  ### Extracting Matched Data

  You'll likely have data within your feature statements which you want to extract.

  A **regex** binds its matched data as a *map of named captures* (the values are
  always strings):

      # NOTICE THE `number` VARIABLE IS STILL A STRING!!
      defgiven ~r/^there (is|are) (?<number>\d+) widget(s?)$/, %{number: number}, _state do
        assert String.to_integer(number) >= 1
      end

  For every named capture, you'll have a key as an atom in the second parameter. You can then use those variables you create within your block.

  A **Cucumber Expression** (any string pattern containing a `{...}` parameter)
  binds its matched data as a *positional list* of already-transformed arguments.
  Parameter types are converted for you — `{int}` arrives as an integer,
  `{float}` as a float, `{string}`/`{word}` as a string:

      # `count` is an INTEGER, already transformed by the {int} parameter type.
      defgiven "there are {int} widgets", [count], _state do
        assert count >= 1
      end

  Cucumber Expression arguments are positional, so the second argument is a list
  whose elements line up with the `{...}` parameters left to right. (Tables and
  doc strings are not Cucumber Expression parameters; use a regex named capture
  if you need to bind them.) To match a literal `{`, escape it with a backslash:
  `"\\\\{weird\\\\}"` in Elixir source matches the text `{weird}` instead of being
  parsed as a parameter.

  > #### `{name:type}` is not supported {: .warning}
  >
  > The non-spec `{name:type}` named-capture sugar (e.g. `{count:int}`) was removed
  > in 1.0.0. Such a pattern reaches the spec engine and raises an
  > `Undefined parameter type 'count:int'` compile error. Use a regex named capture
  > (`~r/(?<count>\d+)/`) to bind by name, or the spec `{int}` to bind positionally.

  ### Modifying State

  You'll likely have to keep track of some state in between statements. The third parameter to each of `defgiven/4`, `defwhen/4` and `defthen/4` is a pattern in which specifies what you want to call your state in the same way that the `ExUnit.Case.test/3` macro works.

  You can setup initial state using plain ExUnit `setup/1` and `setup_all/1`. Whatever state is provided via the `test/3` macro will be your initial state.

  To update the state, simply return `{:ok, %{new: :state}}`. Note that a `Map.merge/2` will be performed for you so only have to specify the keys you want to update. For this reason, only a map is allowed as state.

  Heres an example modifying state:

      defwhen ~r/^I am an admin$/, _, %{user: user} do
        {:ok, %{user: User.promote_to_admin(user)}}
      end

  All other statements do not need to return (and should be careful not to!) the `{:ok, state}` pattern.

  ### Organizing Features

  You may want to reuse several statements you create, especially ones that deal with global logic like users and logging in.

  Feature modules can be created without referencing a file. This makes them do nothing except hold translations between steps in a scenario and test code to be included into a test. These modules must be compiled prior to running the test suite, so for that reason you must add them to the `elixirc_paths` in your `mix.exs` file, like so:

      defmodule MyApp.Mixfile do
        use Mix.Project

        def project do
          [
            app: :my_app,
            ... # Add this to your project function
            elixirc_paths: elixirc_paths(Mix.env),
            ...
          ]
        end

        # Specifies which paths to compile per environment.
        defp elixirc_paths(:test), do: ["lib", "test/support"]
        defp elixirc_paths(_),     do: ["lib"]

        ...
      end

  If you're using Phoenix, this should already be setup for you. Simply place a file like the following into `test/support`.

      defmodule MyApp.GlobalFeatures do
        use Cabbage.Feature

        # Write your `defgiven/4`, `defthen/4` and `defwhen/4`s here
      end

  Then inside the test file (the .exs one) add a `import_feature MyApp.GlobalFeatures` line after the `use Cabbage.Feature` line lke so:

      defmodule MyApp.SomeFeatureTest do
        use Cabbage.Feature, file: "some_feature.feature"
        import_feature MyApp.GlobalFeatures

        # Omitted the rest
      end

  Keep in mind that if you'd like to be more explicit about what you bring into your test, you can use the macros `import_steps/1` and `import_tags/1`. This will allow you to be more selective about whats getting included into your integration tests. The `import_feature/1` macro simply calls both the `import_steps/1` and `import_tags/1` macros.

  ## Options

  `use Cabbage.Feature` accepts:

    * `:file` — the `.feature` file to generate scenarios from;
    * `:template` — the case template to `use` instead of `ExUnit.Case`;
    * `:on_ambiguous_step` — how to react at compile time when more than one registered
      step definition matches a scenario step. One of:
      * `:ignore` (default) — first-match-wins, silently. Preserves the historical
        behaviour where a general pattern plus a specific override is resolved by picking
        the first match (which, because step definitions accumulate, is the *last*
        textually-written matching `defgiven`/`defwhen`/`defthen`).
      * `:warn` — emit a compile warning naming the ambiguous step, then still first-match-wins.
      * `:raise` — abort compilation with a `CompileError`.
  """
  import Cabbage.Feature.Helpers

  alias Cabbage.Feature.{Loader, MissingStepError}

  @feature_options [:file, :template, :on_ambiguous_step, :import]

  # How the compile-time step matcher reacts when more than one registered step pattern
  # matches a scenario step. `:ignore` (the default) preserves the historical first-match-wins
  # behaviour; `:warn` emits a compile warning and still picks the first match; `:raise` aborts
  # compilation. Opt in via `use Cabbage.Feature, on_ambiguous_step: :warn`.
  @on_ambiguous_step_values [:ignore, :warn, :raise]
  defmacro __using__(options) do
    has_assigned_feature = !match?(nil, options[:file])

    Module.register_attribute(__CALLER__.module, :steps, accumulate: true)
    Module.register_attribute(__CALLER__.module, :imported_steps, accumulate: true)
    Module.register_attribute(__CALLER__.module, :tags, accumulate: true)
    Module.put_attribute(__CALLER__.module, :on_ambiguous_step, validate_on_ambiguous_step!(options))

    quote do
      unquote(prepare_executable_feature(has_assigned_feature, options))

      @before_compile {unquote(__MODULE__), :expose_metadata}
      import unquote(__MODULE__)
      require Logger

      unquote(load_features(has_assigned_feature, options))
      unquote(import_modules(options))
    end
  end

  # Imported steps go into a dedicated `@imported_steps` accumulator and are appended
  # *after* the importer's own `@steps` when the final step list is assembled
  # (`registered_steps/1`). First-match-wins then resolves a same-pattern collision in
  # favour of the importer's local step.
  defp import_modules(options) do
    for module <- List.wrap(options[:import]) do
      quote do
        import_steps(unquote(module))
        import_tags(unquote(module))
      end
    end
  end

  defp validate_on_ambiguous_step!(options) do
    case Keyword.get(options, :on_ambiguous_step, :ignore) do
      value when value in @on_ambiguous_step_values ->
        value

      other ->
        raise ArgumentError,
              "invalid :on_ambiguous_step #{inspect(other)} passed to `use Cabbage.Feature`; " <>
                "expected one of #{inspect(@on_ambiguous_step_values)}"
    end
  end

  defp prepare_executable_feature(false, _options), do: nil

  defp prepare_executable_feature(true, options) do
    {_options, template_options} = Keyword.split(options, @feature_options)

    quote do
      @before_compile unquote(__MODULE__)
      use unquote(options[:template] || ExUnit.Case), unquote(template_options)
    end
  end

  defp load_features(false, _options), do: nil

  defp load_features(true, options) do
    quote do
      @feature Loader.load_from_file(unquote(options[:file]))
      @scenarios @feature.scenarios
    end
  end

  # Local steps first (in their usual accumulate newest-first read order), imported steps
  # appended after — first-match-wins keeps a local step ahead of a same-pattern imported one.
  # Reversing @imported_steps restores insertion order, so the guarantee is deterministic:
  # imported steps appear in their source-definition order within each module, modules in
  # import order.
  defp registered_steps(module) do
    local = Module.get_attribute(module, :steps) || []
    imported = Enum.reverse(Module.get_attribute(module, :imported_steps) || [])
    local ++ imported
  end

  defmacro expose_metadata(env) do
    steps = registered_steps(env.module)
    tags = Module.get_attribute(env.module, :tags) || []
    feature = Module.get_attribute(env.module, :feature)

    quote generated: true do
      def raw_steps() do
        unquote(Macro.escape(steps))
      end

      def raw_tags() do
        unquote(Macro.escape(tags))
      end

      # The loaded `Cabbage.Feature.Loader` document this module's scenarios were
      # generated from (or `nil` for a file-less step library). Read by
      # `Cabbage.Formatter` to emit per-feature source/gherkinDocument/pickle envelopes;
      # additive accessor only — it does not affect scenario execution.
      def __cabbage_document__() do
        unquote(Macro.escape(feature))
      end
    end
  end

  defmacro __before_compile__(env) do
    scenarios = Module.get_attribute(env.module, :scenarios) || []
    steps = registered_steps(env.module)
    tags = Module.get_attribute(env.module, :tags) || []
    on_ambiguous_step = Module.get_attribute(env.module, :on_ambiguous_step) || :ignore

    check_ambiguous_steps(scenarios, steps, on_ambiguous_step, env)

    scenarios
    |> Enum.map(fn scenario ->
      scenario =
        Map.put(
          scenario,
          :tags,
          Cabbage.global_tags() ++ List.wrap(Module.get_attribute(env.module, :moduletag)) ++ scenario.tags
        )

      quote bind_quoted: [
              scenario: Macro.escape(scenario),
              tags: Macro.escape(tags),
              steps: Macro.escape(steps)
            ],
            line: scenario.line do
        describe scenario.name do
          setup context do
            # Tag blocks contribute initial state purely (no process); ExUnit's own context
            # is layered on top so a `setup`/`setup_all` value can override a tag default.
            tag_state =
              Cabbage.Feature.Helpers.collect_tag_state(
                unquote(Macro.escape(tags)),
                unquote(scenario.tags)
              )

            {:ok, Map.merge(tag_state, Cabbage.Feature.Helpers.to_map(context))}
          end

          tags = Cabbage.Feature.Helpers.map_tags(scenario.tags) || []

          name =
            Cabbage.Feature.Helpers.register_test(__ENV__, :scenario, scenario.name, tags)

          def unquote(name)(exunit_state) do
            # Each step is compiled to a `fn context -> next_context end`; we thread the scenario
            # state through them with a plain reduce. No process, no shared variable — state is a
            # value passed step-to-step, which is what makes `async: true` safe by construction.
            Enum.reduce(
              unquote(Enum.map(scenario.steps, &compile_step(&1, steps))),
              Cabbage.Feature.Helpers.init_context(exunit_state),
              fn step_fun, context -> step_fun.(context) end
            )

            :ok
          end
        end
      end
    end)
  end

  @doc """
  Compiles a single Gherkin `step` into a quoted `fn context -> next_context end`.

  Used at compile time by `__before_compile__/1`; `steps` is the list of registered step
  definition ASTs. The returned function receives the current scenario state, runs the matched
  step block, and returns the next state — `Map.merge`d with the step's `{:ok, delta}` return
  (or unchanged for any other return). `__before_compile__/1` threads these functions with a
  reduce, so scenario state is a plain value rather than process state.
  """
  @spec compile_step(struct(), [Macro.t()]) :: Macro.t()
  def compile_step(step, steps) when is_list(steps) do
    step_type = step.keyword

    step
    |> find_implementation_of_step(steps)
    |> compile(step, step_type)
  end

  defp compile(
         {:{}, _, [pattern, vars, state_pattern, block, metadata]},
         step,
         step_type
       ) do
    matched_data =
      case eval_pattern(pattern) do
        {:regex, regex} ->
          extract_named_vars(regex, step.text)
          |> Map.merge(%{table: step.table_data, doc_string: step.doc_string})

        # Cucumber Expression arguments are positional and already transformed
        # (`{int}` -> integer, `{string}` -> string, ...); they bind as a list,
        # not a named-captures map. Table/doc-string are not spec parameters, so
        # they are not injected here — use a regex named capture if you need them.
        {:cucumber_expression, expression} ->
          Cabbage.CucumberExpression.match(expression, step.text)
      end

    # Reserved context keys exposing this step's gherkin table/doc-string. Injected
    # per step (not threaded) and stripped by `Helpers.remove_hidden_state/1`, so a
    # cucumber-expression step (whose `vars` is a positional list) can still read them
    # uniformly without leaking into a user's state-pattern match.
    table = Macro.escape(step.table_data)
    doc_string = Macro.escape(step.doc_string)

    quote generated: true do
      fn context ->
        context = Map.merge(context, %{__table__: unquote(table), __doc_string__: unquote(doc_string)})

        with {_type, unquote(vars)} <- {:variables, unquote(Macro.escape(matched_data))},
             {_type, state = unquote(state_pattern)} <- {:state, context} do
          new_state =
            case unquote(block) do
              {:ok, new_state} -> Map.merge(state, new_state)
              _ -> state
            end

          Logger.info([
            "\t\t",
            IO.ANSI.cyan(),
            unquote(step_type),
            " ",
            IO.ANSI.green(),
            unquote(step.text)
          ])

          # Reserved keys are per-step context, never threaded forward.
          Map.drop(new_state, [:__table__, :__doc_string__])
        else
          {type, value} ->
            metadata = unquote(Macro.escape(metadata))

            reraise """
                    ** (MatchError) Failure to match #{type} of #{inspect(Cabbage.Feature.Helpers.remove_hidden_state(value))}
                    Pattern: #{unquote(Macro.to_string(state_pattern))}
                    """,
                    Cabbage.Feature.Helpers.stacktrace(__MODULE__, metadata)
        end
      end
    end
  end

  defp compile(_, step, step_type) do
    extra_vars = %{table: step.table_data, doc_string: step.doc_string}

    raise MissingStepError, step_text: step.text, step_type: step_type, extra_vars: extra_vars
  end

  # Steps store their pattern as a quoted literal AST: either a `%Regex{}` (regex
  # and exact-string patterns) or a `{:cucumber_expression, source}` marker.
  # `eval_pattern/1` evaluates it back and tags it so callers can branch.
  defp eval_pattern(quoted) do
    case Code.eval_quoted(quoted) |> elem(0) do
      {:cucumber_expression, source} -> {:cucumber_expression, Cabbage.Feature.Helpers.compile_expression(source)}
      %Regex{} = regex -> {:regex, regex}
    end
  end

  # Does `step`'s text match a registered step definition's pattern?
  defp step_matches?(step, {:{}, _, [pattern, _, _, _, _]}) do
    case eval_pattern(pattern) do
      {:regex, regex} -> step.text =~ regex
      {:cucumber_expression, expression} -> Cabbage.CucumberExpression.match(expression, step.text) != nil
    end
  end

  defp find_implementation_of_step(step, steps), do: Enum.find(steps, &step_matches?(step, &1))

  # All registered step definitions whose pattern matches `step.text`. `find_implementation_of_step/2`
  # picks the FIRST of these (first-match-wins); this enumerates them for the opt-in ambiguity
  # check, which only cares whether there is more than one.
  defp matching_implementations_of_step(step, steps), do: Enum.filter(steps, &step_matches?(step, &1))

  # Opt-in compile-time ambiguity detection. `find_implementation_of_step/2` is silently
  # first-match-wins; some feature modules rely on that (a general pattern plus a specific
  # override), so the default is `:ignore` to preserve all shipped behaviour. `:warn` and
  # `:raise` surface the cases where more than one registered pattern matches a scenario step.
  defp check_ambiguous_steps(_scenarios, _steps, :ignore, _env), do: :ok

  defp check_ambiguous_steps(scenarios, steps, on_ambiguous, env) when on_ambiguous in [:warn, :raise] do
    for scenario <- scenarios, step <- scenario.steps do
      case matching_implementations_of_step(step, steps) do
        matches when length(matches) > 1 ->
          report_ambiguous_step(step, matches, on_ambiguous, env)

        _ ->
          :ok
      end
    end

    :ok
  end

  defp report_ambiguous_step(step, matches, on_ambiguous, env) do
    patterns =
      matches
      |> Enum.map(fn {:{}, _, [pattern, _, _, _, _]} ->
        case eval_pattern(pattern) do
          {:regex, regex} -> "    " <> inspect(Regex.source(regex))
          {:cucumber_expression, expression} -> "    " <> inspect(expression.source)
        end
      end)
      |> Enum.join("\n")

    message =
      "Ambiguous step #{inspect(step.text)}: #{length(matches)} registered step definitions " <>
        "match it (first-match-wins picks the first):\n#{patterns}"

    case on_ambiguous do
      :warn -> IO.warn(message, Macro.Env.stacktrace(env))
      :raise -> raise CompileError, description: message, file: env.file, line: env.line
    end
  end

  defp extract_named_vars(regex, step_text) do
    regex
    |> Regex.named_captures(step_text)
    |> Enum.map(fn {k, v} -> {String.to_atom(k), v} end)
    |> Enum.into(%{})
  end

  @doc """
  Brings in all the functionality available from the supplied module. Module must `use Cabbage.Feature` (with or without a `:file`).

  Same as calling both `import_steps/1` and `import_tags/1`.
  """
  defmacro import_feature(module) do
    quote do
      import_steps(unquote(module))
      import_tags(unquote(module))
    end
  end

  @doc """
  Brings in all the step definitions from the supplied module. Module must `use Cabbage.Feature` (with or without a `:file`).
  """
  defmacro import_steps(module) do
    quote do
      Cabbage.Feature.ensure_step_module!(unquote(module))

      # raw_steps/0 reads newest-first; reverse to source-definition order before
      # accumulating. The accumulator prepends and registered_steps/1 reverses it
      # back, so imported steps keep this order in the final step list.
      for step <- Enum.reverse(unquote(module).raw_steps()) do
        Module.put_attribute(__MODULE__, :imported_steps, step)
      end
    end
  end

  @doc false
  # Verifies `module` is a compiled step source (a `use Cabbage.Steps` or `use Cabbage.Feature`
  # module exposing `raw_steps/0`). Raised at the importer's compile time with a clear message
  # rather than a bare UndefinedFunctionError on `raw_steps/0`.
  def ensure_step_module!(module) do
    case Code.ensure_compiled(module) do
      {:module, ^module} ->
        unless function_exported?(module, :raw_steps, 0) do
          raise ArgumentError,
                "#{inspect(module)} is not a step module: it does not export raw_steps/0. " <>
                  "Import only modules that `use Cabbage.Steps` or `use Cabbage.Feature`."
        end

      {:error, reason} ->
        raise ArgumentError,
              "cannot import steps from #{inspect(module)}: it is not compiled (#{inspect(reason)}). " <>
                "Step modules must be compiled first — place them on elixirc_paths (e.g. test/support)."
    end
  end

  @doc """
  Brings in all the tag definitions from the supplied module. Module must `use Cabbage.Feature` (with or without a `:file`).
  """
  defmacro import_tags(module) do
    quote do
      if Code.ensure_compiled(unquote(module)) do
        for {name, block} <- unquote(module).raw_tags() do
          Cabbage.Feature.Helpers.add_tag(__MODULE__, name, block)
        end
      end
    end
  end

  defmacro defgiven(regex, vars, state, do: block) do
    add_step(__CALLER__.module, regex, vars, state, block, metadata(__CALLER__, :defgiven))
  end

  defmacro defgiven(regex, state, do: block) do
    add_step(__CALLER__.module, regex, Macro.var(:_, __MODULE__), state, block, metadata(__CALLER__, :defgiven))
  end

  defmacro defwhen(regex, vars, state, do: block) do
    add_step(__CALLER__.module, regex, vars, state, block, metadata(__CALLER__, :defwhen))
  end

  defmacro defwhen(regex, state, do: block) do
    add_step(__CALLER__.module, regex, Macro.var(:_, __MODULE__), state, block, metadata(__CALLER__, :defwhen))
  end

  defmacro defthen(regex, vars, state, do: block) do
    add_step(__CALLER__.module, regex, vars, state, block, metadata(__CALLER__, :defthen))
  end

  defmacro defthen(regex, state, do: block) do
    add_step(__CALLER__.module, regex, Macro.var(:_, __MODULE__), state, block, metadata(__CALLER__, :defthen))
  end

  @doc """
  Registers a step definition. Keyword-neutral form of `defgiven/4`/`defwhen/4`/`defthen/4`.

  Matching is by pattern only, so a `defstep` matches any Gherkin keyword (Given/When/Then/And/But).
  """
  defmacro defstep(regex, vars, state, do: block) do
    add_step(__CALLER__.module, regex, vars, state, block, metadata(__CALLER__, :defstep))
  end

  @doc """
  Registers a step definition without binding matched data. `vars` defaults to ignore.

  Every step macro has this `/3` short form: pattern, state, `do:` block.
  """
  defmacro defstep(regex, state, do: block) do
    add_step(__CALLER__.module, regex, Macro.var(:_, __MODULE__), state, block, metadata(__CALLER__, :defstep))
  end

  defmacro defand(regex, vars, state, do: block) do
    add_step(__CALLER__.module, regex, vars, state, block, metadata(__CALLER__, :defand))
  end

  defmacro defand(regex, state, do: block) do
    add_step(__CALLER__.module, regex, Macro.var(:_, __MODULE__), state, block, metadata(__CALLER__, :defand))
  end

  defmacro defbut(regex, vars, state, do: block) do
    add_step(__CALLER__.module, regex, vars, state, block, metadata(__CALLER__, :defbut))
  end

  defmacro defbut(regex, state, do: block) do
    add_step(__CALLER__.module, regex, Macro.var(:_, __MODULE__), state, block, metadata(__CALLER__, :defbut))
  end

  @doc """
  Add an ExUnit `setup/1` callback that only fires for the scenarios that are tagged. Can be
  used inside of `Cabbage.Feature`s that don't relate to a file and then imported with `import_feature/1`.

  Example usage:

      defmodule MyTest do
        use Cabbage.Feature

        tag @some_tag do
          IO.puts "Do this before the @some_tag scenario"
          on_exit fn ->
            IO.puts "Do this after the @some_tag scenario"
          end
        end
      end
  """
  defmacro tag(tag, do: block) do
    add_tag(__CALLER__.module, Macro.to_string(tag) |> String.replace(~r/\s*/, ""), block)
  end
end
