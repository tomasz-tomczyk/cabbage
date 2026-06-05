defmodule Cabbage.Messages do
  @moduledoc """
  A direct, message-emitting Cucumber runner: parse a feature to pickles, execute each
  pickle's steps against a step registry, and emit the full cucumber-messages
  `Envelope` stream (the same stream a future `message` formatter would produce).

  This is deliberately a *separate execution path* from `Cabbage.Feature`. `Cabbage.Feature`
  generates ExUnit tests at compile time and is coupled to ExUnit's lifecycle, regex-only
  matching, and "raise on missing step" semantics. A conformance runner instead needs to
  observe every status (`passed | failed | undefined | pending | ambiguous | skipped`) and
  serialize a precise, ordered envelope stream — so it interprets pickle steps directly.

  ## Pipeline

      feature source --(Gherkin.parse/pickles)--> envelopes
                       Source, GherkinDocument, Pickle      (reused from the gherkin dep)
                     + StepDefinition*                      (one per registered step def)
                     + TestRunStarted
                     + TestCase*                            (one per pickle, all emitted first)
                     + per pickle: TestCaseStarted,
                         (TestStepStarted, [Suggestion], TestStepFinished)*,
                         TestCaseFinished
                     + TestRunFinished

  The envelope *order* mirrors fake-cucumber / cucumber-js: every `testCase` is emitted
  before any `testCaseStarted`. `run/3` accepts one feature; `run_features/2` aggregates
  several features into a single run (the `multiple-features` CCK shape).

  ## Step outcome protocol

  A step definition's run function may return `:ok`, `nil`, `{:ok, world}`, the strings
  `"pending"`/`"skipped"`, or raise. The runner maps these to step statuses:

    * `:ok` / `nil` / `{:ok, world}` -> `PASSED`
    * `"pending"` / `"skipped"`       -> `PENDING` / `SKIPPED` (no `exception`)
    * `raise Cabbage.PendingError`    -> `PENDING` with `exception.type = "PendingException"`
    * `raise Cabbage.SkippedError`    -> `SKIPPED` with `exception.type = "SkippedException"`
    * any other raise                 -> `FAILED` (`AssertionError` for a failed match /
      ExUnit assertion, otherwise `Error`)

  Match count decides the rest: 0 matches -> `UNDEFINED` (+ a `suggestion` envelope),
  >1 -> `AMBIGUOUS`.

  ## Skip propagation (cucumber-js / CCK `failedish-combinations` semantics)

  A step's *intrinsic* status is computed first, then two flags thread through the
  scenario:

    * a prior step reported a non-`PASSED` status -> later *executable* steps (single
      match, would run a def) become `SKIPPED`, but `UNDEFINED`/`AMBIGUOUS` steps keep
      their intrinsic status;
    * a prior step's intrinsic status was `SKIPPED` (a `"skipped"` return or a raised
      `Cabbage.SkippedError`) -> *every* later step becomes `SKIPPED`, including
      `UNDEFINED`/`AMBIGUOUS` ones.

  The run is `success: true` iff every step is `PASSED` or `SKIPPED` (a scenario that only
  skips is still a successful run).

  ## Status / extension notes

  Run-structure envelopes are assembled here; Source/GherkinDocument/Pickle and NDJSON
  serialization are reused from `Gherkin.Message`. Hooks, attachments, parameter-type and
  retry envelopes are *not* emitted yet.

  Ambiguity (cabbage-ex/cabbage#88) is detected here via the match count. It is **not**
  surfaced in the compile-time `Cabbage.Feature` runner: that path's
  `find_implementation_of_step/2` uses first-match-wins, and existing feature modules may
  rely on that (general pattern + specific override). Turning first-match into a
  compile-time ambiguity error is a behavioural change for shipped code and is left to a
  dedicated change rather than this result-semantics wave.
  """

  alias Cabbage.Messages.{HookRegistry, Ids, Matcher, StepRegistry}
  alias Gherkin.Message

  @type envelope :: map()

  @doc """
  Run a single `feature_source` against `registry`, returning the ordered envelope list.

  Options:

    * `:uri` — the source uri embedded in Source/GherkinDocument/Pickle (default `""`);
    * `:format` — `:plain` (default) or `:markdown` for the Source media type;
    * `:hooks` — a `Cabbage.Messages.HookRegistry` of before/after-scenario and
      BeforeAll/AfterAll hooks (default: no hooks).
  """
  @spec run(String.t(), StepRegistry.t(), keyword()) :: [envelope()]
  def run(feature_source, %StepRegistry{} = registry, opts \\ []) do
    {hooks, feature_opts} = Keyword.pop(opts, :hooks)
    run_opts = if hooks, do: [hooks: hooks], else: []
    run_features([{feature_source, feature_opts}], registry, run_opts)
  end

  @doc """
  Run several features as one test run.

  `features` is a list of `{feature_source, opts}` (same per-feature opts as `run/3`,
  i.e. `:uri`/`:format`). `run_opts` may carry `:order` (`:reverse`) and `:hooks` (a
  `Cabbage.Messages.HookRegistry`). The parser-side envelopes are emitted per feature
  (Source, GherkinDocument, Pickles), then a single set of Hook / StepDefinition / TestRun*
  / TestCase* / execution envelopes spans all pickles — matching the `multiple-features`
  golden.
  """
  @spec run_features([{String.t(), keyword()}], StepRegistry.t(), keyword()) :: [envelope()]
  def run_features(features, registry, run_opts \\ [])

  def run_features(features, %StepRegistry{} = registry, run_opts) do
    hook_registry = Keyword.get(run_opts, :hooks) || HookRegistry.new()
    ids = Ids.new()

    # 1. Parser-side envelopes per feature, collecting pickles in document order.
    {parser_envelopes, pickles, ids} =
      Enum.reduce(features, {[], [], ids}, fn {source, opts}, {env_acc, pickle_acc, ids} ->
        uri = Keyword.get(opts, :uri, "")
        format = Keyword.get(opts, :format, :plain)
        parse_opts = [uri: uri, markdown: format == :markdown]
        document = Gherkin.parse!(source, parse_opts)
        feature_pickles = Gherkin.pickles(source, parse_opts)

        envelopes = [
          Message.source_envelope(uri, source, format),
          Message.gherkin_document_envelope(document)
          | Enum.map(feature_pickles, &Message.pickle_envelope/1)
        ]

        {env_acc ++ envelopes, pickle_acc ++ feature_pickles, ids}
      end)

    # `--order reverse`: the planning (testCase) and execution order both reverse, while the
    # parser-side envelopes keep document order.
    pickles = if run_opts[:order] == :reverse, do: Enum.reverse(pickles), else: pickles

    # 2a. Hook definition envelopes (one per registered hook) — assigned ids the test steps
    # and testRunHook* envelopes reference back. The reference emits the registration section
    # in source order (before/beforeAll hooks, then step defs, then after/afterAll hooks), so
    # we split the hook defs into a "before" block (emitted ahead of step defs) and an "after"
    # block (after them). The normalizer sorts each contiguous block by type+tag expression.
    {before_hook_defs, after_hook_defs, hook_ids, ids} =
      hook_definition_envelopes(hook_registry, ids)

    # 2b. StepDefinition envelopes (one per registered definition, registration order).
    {step_def_envelopes, def_ids} = step_definition_envelopes(registry, ids)
    ids = def_ids.ids

    # 3. TestRunStarted.
    {test_run_started_id, ids} = Ids.next(ids)
    test_run_started = test_run_started_envelope(test_run_started_id)

    # 4. BeforeAll global hooks, in registration order, right after testRunStarted. A failed
    # BeforeAll fails the run and suppresses all test-case execution (cleanup hooks still run).
    {before_all_envelopes, before_all_ok?, ids} =
      run_global_hooks(:before_test_run, hook_registry, hook_ids, test_run_started_id, ids)

    # 5/6. When a BeforeAll failed, the run is aborted: no TestCase is planned or executed
    # (the pickles are still emitted in the parser section, but they never become test cases).
    # Otherwise plan every pickle into a TestCase — weaving in applicable before/after scenario
    # hooks as `hookId` test steps — then execute each.
    {test_case_envelopes, execution_envelopes, ids} =
      if before_all_ok? do
        {test_cases, ids} =
          Enum.map_reduce(pickles, ids, fn pickle, ids ->
            plan_test_case(pickle, registry, def_ids.by_definition, hook_registry, hook_ids, test_run_started_id, ids)
          end)

        {execution, ids} =
          Enum.flat_map_reduce(test_cases, ids, fn test_case, ids ->
            execute_test_case(test_case, ids)
          end)

        {Enum.map(test_cases, & &1.envelope), execution, ids}
      else
        {[], [], ids}
      end

    # 7. AfterAll global hooks, in *reverse* registration order, before testRunFinished.
    {after_all_envelopes, after_all_ok?, _ids} =
      run_global_hooks(:after_test_run, hook_registry, hook_ids, test_run_started_id, ids)

    success =
      before_all_ok? and after_all_ok? and run_success?(execution_envelopes)

    parser_envelopes ++
      before_hook_defs ++
      step_def_envelopes ++
      after_hook_defs ++
      [test_run_started] ++
      before_all_envelopes ++
      test_case_envelopes ++
      execution_envelopes ++
      after_all_envelopes ++
      [test_run_finished_envelope(test_run_started_id, success)]
  end

  @doc "Serialize an envelope list to NDJSON using the gherkin key-sorted serializer."
  @spec to_ndjson([envelope()]) :: String.t()
  def to_ndjson(envelopes), do: Message.to_ndjson(envelopes)

  # ---- Hook definition envelopes ---------------------------------------------

  # Assign an id to every registered hook (registration order) and emit its `hook` envelope.
  # Returns the "before" block (before/beforeAll hook defs), the "after" block (after/afterAll
  # hook defs), and a hook->id map. The before/after split mirrors the reference's source-order
  # registration section: before hooks precede step defs, after hooks follow them.
  defp hook_definition_envelopes(hook_registry, ids) do
    {pairs, ids} =
      hook_registry
      |> HookRegistry.hooks()
      |> Enum.map_reduce(ids, fn hook, ids ->
        {id, ids} = Ids.next(ids)
        {{hook, id}, ids}
      end)

    {before_pairs, after_pairs} =
      Enum.split_with(pairs, fn {hook, _id} ->
        hook.type in [:before_test_case, :before_test_run]
      end)

    to_envelopes = fn list -> Enum.map(list, fn {hook, id} -> hook_definition_envelope(hook, id) end) end
    {to_envelopes.(before_pairs), to_envelopes.(after_pairs), Map.new(pairs), ids}
  end

  defp hook_definition_envelope(hook, id) do
    inner =
      %{"id" => id, "type" => hook_type_string(hook.type), "sourceReference" => source_reference(hook)}
      |> maybe_put("name", hook.name)
      |> maybe_put("tagExpression", hook.tag_expression)

    %{"hook" => inner}
  end

  defp hook_type_string(:before_test_case), do: "BEFORE_TEST_CASE"
  defp hook_type_string(:after_test_case), do: "AFTER_TEST_CASE"
  defp hook_type_string(:before_test_run), do: "BEFORE_TEST_RUN"
  defp hook_type_string(:after_test_run), do: "AFTER_TEST_RUN"

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  # ---- Global (BeforeAll/AfterAll) hooks -------------------------------------

  # Run every global hook of `type` and emit a testRunHookStarted/testRunHookFinished pair
  # per hook. BeforeAll runs in registration order; AfterAll in *reverse*. Every hook runs
  # even if an earlier one failed (cleanup semantics); the boolean reports whether all
  # passed-or-skipped, which feeds testRunFinished.success.
  defp run_global_hooks(type, hook_registry, hook_ids, test_run_started_id, ids) do
    hooks =
      hook_registry
      |> HookRegistry.global_hooks()
      |> Enum.filter(&(&1.type == type))

    hooks = if type == :after_test_run, do: Enum.reverse(hooks), else: hooks

    {envelopes, {all_ok?, ids}} =
      Enum.flat_map_reduce(hooks, {true, ids}, fn hook, {all_ok?, ids} ->
        {status, _world} = run_hook(hook, [], %{})
        {pair, ids} = test_run_hook_envelopes(test_run_started_id, hook_ids[hook], status, ids)
        {pair, {all_ok? and hook_success?(status), ids}}
      end)

    {envelopes, all_ok?, ids}
  end

  defp test_run_hook_envelopes(test_run_started_id, hook_id, status, ids) do
    {started_id, ids} = Ids.next(ids)

    started = %{
      "testRunHookStarted" => %{
        "testRunStartedId" => test_run_started_id,
        "id" => started_id,
        "hookId" => hook_id,
        "timestamp" => timestamp(Ids.tick(ids))
      }
    }

    finished = %{
      "testRunHookFinished" => %{
        "testRunHookStartedId" => started_id,
        "timestamp" => timestamp(Ids.tick(ids)),
        "result" => step_result(status)
      }
    }

    {[started, finished], ids}
  end

  defp hook_success?({:failed, _type}), do: false
  defp hook_success?(_other), do: true

  # ---- StepDefinition envelopes ----------------------------------------------

  defp step_definition_envelopes(registry, ids) do
    {envelopes_and_ids, ids} =
      registry
      |> StepRegistry.definitions()
      |> Enum.map_reduce(ids, fn definition, ids ->
        {id, ids} = Ids.next(ids)
        {{definition, id, step_definition_envelope(definition, id)}, ids}
      end)

    by_definition =
      envelopes_and_ids
      |> Enum.map(fn {definition, id, _env} -> {definition, id} end)
      |> Map.new()

    envelopes = Enum.map(envelopes_and_ids, fn {_def, _id, env} -> env end)
    {envelopes, %{ids: ids, by_definition: by_definition}}
  end

  defp step_definition_envelope(definition, id) do
    %{
      "stepDefinition" => %{
        "id" => id,
        "pattern" => %{
          "source" => definition.source,
          "type" => pattern_type(definition.pattern_kind)
        },
        "sourceReference" => source_reference(definition)
      }
    }
  end

  defp pattern_type(:cucumber_expression), do: "CUCUMBER_EXPRESSION"
  defp pattern_type(:regular_expression), do: "REGULAR_EXPRESSION"

  defp source_reference(%{uri: nil}), do: %{}

  defp source_reference(%{uri: uri, line: nil}), do: %{"uri" => uri}

  defp source_reference(%{uri: uri, line: line}),
    do: %{"uri" => uri, "location" => %{"line" => line}}

  # ---- TestCase planning -----------------------------------------------------

  defp plan_test_case(pickle, registry, def_ids, hook_registry, hook_ids, test_run_started_id, ids) do
    {test_case_id, ids} = Ids.next(ids)

    pickle_tags = Enum.map(pickle.tags, & &1.name)
    {before_hooks, after_hooks} = applicable_scenario_hooks(hook_registry, pickle_tags)

    # Before scenario hooks -> hook test steps; pickle steps -> step test steps; After
    # scenario hooks -> hook test steps. Each gets its own test step id, in this order.
    {before_planned, ids} = plan_hook_steps(before_hooks, hook_ids, ids)
    {step_planned, ids} = plan_pickle_steps(pickle.steps, registry, def_ids, ids)
    {after_planned, ids} = plan_hook_steps(after_hooks, hook_ids, ids)

    planned_steps = before_planned ++ step_planned ++ after_planned
    test_steps_json = Enum.map(planned_steps, &test_step_json/1)

    envelope = %{
      "testCase" => %{
        "id" => test_case_id,
        "pickleId" => pickle.id,
        "testRunStartedId" => test_run_started_id,
        "testSteps" => test_steps_json
      }
    }

    {%{
       id: test_case_id,
       before_hooks: before_planned,
       steps: step_planned,
       after_hooks: after_planned,
       envelope: envelope
     }, ids}
  end

  # Scenario hooks that apply to a pickle: before hooks (registration order) and after hooks
  # (registration order), each filtered by its tag expression against the pickle's tags.
  defp applicable_scenario_hooks(hook_registry, pickle_tags) do
    hooks =
      hook_registry
      |> HookRegistry.scenario_hooks()
      |> Enum.filter(&hook_applies?(&1, pickle_tags))

    Enum.split_with(hooks, &(&1.type == :before_test_case))
  end

  defp hook_applies?(%{tag_expression: nil}, _tags), do: true
  defp hook_applies?(%{tag_expression: expr}, tags), do: Cabbage.TagExpression.evaluate(expr, tags)

  defp plan_hook_steps(hooks, hook_ids, ids) do
    Enum.map_reduce(hooks, ids, fn hook, ids ->
      {test_step_id, ids} = Ids.next(ids)
      {%{id: test_step_id, kind: :hook, hook: hook, hook_id: hook_ids[hook]}, ids}
    end)
  end

  defp plan_pickle_steps(pickle_steps, registry, def_ids, ids) do
    Enum.map_reduce(pickle_steps, ids, fn pickle_step, ids ->
      {test_step_id, ids} = Ids.next(ids)
      matches = Matcher.matches(registry, pickle_step.text)

      {%{
         id: test_step_id,
         kind: :step,
         pickle_step: pickle_step,
         matches: matches,
         definition_ids: Enum.map(matches, fn m -> Map.fetch!(def_ids, m.definition) end)
       }, ids}
    end)
  end

  defp test_step_json(%{kind: :hook} = planned_step) do
    %{"id" => planned_step.id, "hookId" => planned_step.hook_id}
  end

  defp test_step_json(%{kind: :step} = planned_step) do
    %{
      "id" => planned_step.id,
      "pickleStepId" => planned_step.pickle_step.id,
      "stepDefinitionIds" => planned_step.definition_ids,
      "stepMatchArgumentsLists" => step_match_arguments_lists(planned_step.matches)
    }
  end

  # undefined: no matches -> empty list. defined/ambiguous: one entry per matching def.
  defp step_match_arguments_lists(matches) do
    Enum.map(matches, fn match -> %{"stepMatchArguments" => match.arguments} end)
  end

  # ---- TestCase execution ----------------------------------------------------

  defp execute_test_case(test_case, ids) do
    {test_case_started_id, ids} = Ids.next(ids)
    started = test_case_started_envelope(test_case_started_id, test_case.id, ids)

    # Thread two skip-propagation flags across the scenario's Before hooks + steps
    # (cucumber-js semantics, see the CCK `failedish-combinations` and `hooks-skipped`
    # samples):
    #
    #   * `failed_ish?`    — a prior step/hook reported a non-PASSED status. This skips later
    #                        *executable* steps (a single match / a runnable hook) but leaves
    #                        UNDEFINED/AMBIGUOUS steps reporting their own status.
    #   * `intrinsic_skip?` — a prior step/hook's *intrinsic* status was SKIPPED (a `"skipped"`
    #                        return or a raised `Cabbage.SkippedError`). A real skip cascades
    #                        to *every* later step in this chain, even undefined/ambiguous ones.
    #
    # Before hooks and pickle steps share one skip chain; After hooks always run, each in its
    # own fresh chain (a skipped/failing After does not cascade to later After hooks).
    acc0 = %{envelopes: [], world: %{}, failed_ish?: false, intrinsic_skip?: false, ids: ids}

    acc =
      Enum.reduce(test_case.before_hooks ++ test_case.steps, acc0, fn planned, acc ->
        execute_step(planned, test_case_started_id, acc)
      end)

    acc =
      Enum.reduce(test_case.after_hooks, acc, fn planned, acc ->
        fresh = %{acc | failed_ish?: false, intrinsic_skip?: false}
        execute_step(planned, test_case_started_id, fresh)
      end)

    finished = test_case_finished_envelope(test_case_started_id, acc.ids)
    {[started] ++ acc.envelopes ++ [finished], acc.ids}
  end

  # Execute (or skip) one planned step or hook, returning the updated accumulator.
  defp execute_step(planned, test_case_started_id, acc) do
    {intrinsic, new_world} = intrinsic_status(planned, acc.world)
    reported = report_status(intrinsic, acc)

    suggestions =
      if reported == :undefined,
        do: suggestion_snippets(planned.pickle_step.text),
        else: []

    {step_envelopes, ids} =
      emit_step(planned, test_case_started_id, acc.ids, reported, suggestions)

    %{
      acc
      | envelopes: acc.envelopes ++ step_envelopes,
        world: new_world,
        ids: ids,
        failed_ish?: acc.failed_ish? or reported != :passed,
        intrinsic_skip?: acc.intrinsic_skip? or intrinsic_skip?(intrinsic)
    }
  end

  # The status a hook would have *on its own* — hooks have no match concept, they just run.
  defp intrinsic_status(%{kind: :hook} = planned, world), do: run_hook(planned.hook, [], world)

  # The status a step would have *on its own*, ignoring prior steps: UNDEFINED when no
  # definition matches, AMBIGUOUS when more than one does, otherwise the run result.
  defp intrinsic_status(%{kind: :step} = planned_step, world) do
    case planned_step.matches do
      [] -> {:undefined, world}
      [match] -> run_step(match, planned_step.pickle_step, world)
      _ambiguous -> {:ambiguous, world}
    end
  end

  # Apply the skip-propagation rule to turn an intrinsic status into the reported one.
  # A real (intrinsic) skip earlier cascades to everything; otherwise a prior failed-ish
  # step only skips later *executable* steps, leaving undefined/ambiguous intact.
  defp report_status(_intrinsic, %{intrinsic_skip?: true}), do: :skipped

  defp report_status(intrinsic, %{failed_ish?: true}) do
    if executable?(intrinsic), do: :skipped, else: intrinsic
  end

  defp report_status(intrinsic, _acc), do: intrinsic

  # Executable steps are the ones that actually invoke a step definition; undefined and
  # ambiguous steps never run, so they are not skippable by a prior failed-ish step.
  defp executable?(:undefined), do: false
  defp executable?(:ambiguous), do: false
  defp executable?(_runnable), do: true

  # Only a genuine SKIPPED outcome (return value or raised SkippedError) cascades fully.
  defp intrinsic_skip?(:skipped), do: true
  defp intrinsic_skip?({:skipped, _type}), do: true
  defp intrinsic_skip?(_other), do: false

  defp run_step(match, pickle_step, world) do
    step_argument = step_argument(pickle_step)
    result = apply_step_fun(match.definition.fun, match.values, step_argument, world)
    classify_outcome(result, world)
  rescue
    error -> rescue_outcome(error, world)
  end

  # A hook runs its 0..3-arity function the same way a step does (no match args / step
  # argument), and maps its return/raise through the same outcome protocol.
  defp run_hook(hook, args, world) do
    result = apply_step_fun(hook.fun, args, nil, world)
    classify_outcome(result, world)
  rescue
    error -> rescue_outcome(error, world)
  end

  defp classify_outcome(result, world) do
    case result do
      "pending" -> {:pending, world}
      :pending -> {:pending, world}
      "skipped" -> {:skipped, world}
      :skipped -> {:skipped, world}
      {:ok, new_world} when is_map(new_world) -> {:passed, new_world}
      _ -> {:passed, world}
    end
  end

  # Dedicated pending/skip exceptions carry the reference type names so the message stream
  # distinguishes "pending via exception" from "pending via return value".
  defp rescue_outcome(error, world) do
    case error do
      %Cabbage.PendingError{} -> {{:pending, "PendingException"}, world}
      %Cabbage.SkippedError{} -> {{:skipped, "SkippedException"}, world}
      _ -> {{:failed, exception_type(error)}, world}
    end
  end

  # Map an Elixir exception to the cucumber-messages `exception.type` the goldens carry.
  # Assertion-style failures (a failed `^pattern =` match or an ExUnit assertion) are
  # reported as `AssertionError`; any other raise is a generic `Error`, matching how
  # fake-cucumber labels thrown JS errors. (`message`/`stackTrace` are dropped by the
  # normalizer, so only the type is compared.)
  defp exception_type(%MatchError{}), do: "AssertionError"
  defp exception_type(%{__struct__: ExUnit.AssertionError}), do: "AssertionError"
  defp exception_type(_other), do: "Error"

  # Step funs may accept arity 0..3. We pass (args, step_argument, world) and adapt.
  defp apply_step_fun(fun, args, step_argument, world) do
    case Function.info(fun, :arity) do
      {:arity, 0} -> fun.()
      {:arity, 1} -> fun.(args)
      {:arity, 2} -> fun.(args, step_argument)
      {:arity, 3} -> fun.(args, step_argument, world)
    end
  end

  defp step_argument(%{argument: {:data_table, %{rows: rows}}}), do: {:data_table, rows}
  defp step_argument(%{argument: {:doc_string, %{content: content}}}), do: {:doc_string, content}
  defp step_argument(_), do: nil

  defp emit_step(planned_step, test_case_started_id, ids, status, suggestion_snippets) do
    started = test_step_started_envelope(test_case_started_id, planned_step.id, ids)

    {suggestion_envelopes, ids} =
      emit_suggestions(planned_step, suggestion_snippets, ids)

    finished =
      test_step_finished_envelope(test_case_started_id, planned_step.id, status, ids)

    {[started] ++ suggestion_envelopes ++ [finished], ids}
  end

  defp emit_suggestions(_planned_step, [], ids), do: {[], ids}

  defp emit_suggestions(planned_step, snippets, ids) do
    {id, ids} = Ids.next(ids)

    envelope = %{
      "suggestion" => %{
        "id" => id,
        "pickleStepId" => planned_step.pickle_step.id,
        "snippets" => snippets
      }
    }

    {[envelope], ids}
  end

  # cucumber-js generates one snippet per plausible parameter-type interpretation of the
  # undefined step text. Normalization strips snippet `code`/`language`, so only the COUNT
  # is compared: a numeric token yields both an {int} and a {float} snippet (2); otherwise 1.
  defp suggestion_snippets(text) do
    count = if Regex.match?(~r/\d/, text), do: 2, else: 1
    for _ <- 1..count, do: %{"code" => "", "language" => "elixir"}
  end

  # ---- Run-structure envelope builders ---------------------------------------

  defp test_run_started_envelope(id) do
    %{"testRunStarted" => %{"id" => id, "timestamp" => timestamp(0)}}
  end

  defp test_run_finished_envelope(test_run_started_id, success) do
    %{
      "testRunFinished" => %{
        "testRunStartedId" => test_run_started_id,
        "timestamp" => timestamp(0),
        "success" => success
      }
    }
  end

  defp test_case_started_envelope(id, test_case_id, ids) do
    %{
      "testCaseStarted" => %{
        "id" => id,
        "testCaseId" => test_case_id,
        "attempt" => 0,
        "timestamp" => timestamp(Ids.tick(ids))
      }
    }
  end

  defp test_case_finished_envelope(test_case_started_id, ids) do
    %{
      "testCaseFinished" => %{
        "testCaseStartedId" => test_case_started_id,
        "timestamp" => timestamp(Ids.tick(ids)),
        "willBeRetried" => false
      }
    }
  end

  defp test_step_started_envelope(test_case_started_id, test_step_id, ids) do
    %{
      "testStepStarted" => %{
        "testCaseStartedId" => test_case_started_id,
        "testStepId" => test_step_id,
        "timestamp" => timestamp(Ids.tick(ids))
      }
    }
  end

  defp test_step_finished_envelope(test_case_started_id, test_step_id, status, ids) do
    %{
      "testStepFinished" => %{
        "testCaseStartedId" => test_case_started_id,
        "testStepId" => test_step_id,
        "testStepResult" => step_result(status),
        "timestamp" => timestamp(Ids.tick(ids))
      }
    }
  end

  # A cucumber-messages `TestStepResult`/`Hook` result: a status, a (dropped) duration, and
  # an optional `exception` (present for failures and exception-raised pending/skipped).
  defp step_result(status) do
    %{"status" => status_string(status), "duration" => timestamp(0)}
    |> maybe_put_exception(status)
  end

  # Failed steps, and pending/skipped raised *via an exception*, carry an `exception`
  # object whose `type` matches the reference (`Error`/`AssertionError`, `PendingException`,
  # `SkippedException`). Pending/skipped reached via a *return value* carry none.
  defp maybe_put_exception(result, {status, type}) when status in [:failed, :pending, :skipped],
    do: Map.put(result, "exception", %{"type" => type})

  defp maybe_put_exception(result, _status), do: result

  defp status_string({:failed, _type}), do: "FAILED"
  defp status_string({:pending, _type}), do: "PENDING"
  defp status_string({:skipped, _type}), do: "SKIPPED"
  defp status_string(:passed), do: "PASSED"
  defp status_string(:undefined), do: "UNDEFINED"
  defp status_string(:pending), do: "PENDING"
  defp status_string(:skipped), do: "SKIPPED"
  defp status_string(:ambiguous), do: "AMBIGUOUS"

  defp timestamp(_n), do: %{"seconds" => 0, "nanos" => 0}

  # The run is unsuccessful if any step finished with a non-PASSED/SKIPPED status.
  defp run_success?(execution_envelopes) do
    execution_envelopes
    |> Enum.filter(&Map.has_key?(&1, "testStepFinished"))
    |> Enum.all?(fn env ->
      status = get_in(env, ["testStepFinished", "testStepResult", "status"])
      status in ["PASSED", "SKIPPED"]
    end)
  end
end
