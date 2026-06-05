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

  alias Cabbage.Messages.{Ids, Matcher, StepRegistry}
  alias Gherkin.Message

  @type envelope :: map()

  @doc """
  Run a single `feature_source` against `registry`, returning the ordered envelope list.

  Options:

    * `:uri` — the source uri embedded in Source/GherkinDocument/Pickle (default `""`);
    * `:format` — `:plain` (default) or `:markdown` for the Source media type.
  """
  @spec run(String.t(), StepRegistry.t(), keyword()) :: [envelope()]
  def run(feature_source, %StepRegistry{} = registry, opts \\ []) do
    run_features([{feature_source, opts}], registry)
  end

  @doc """
  Run several features as one test run.

  `features` is a list of `{feature_source, opts}` (same opts as `run/3`). The parser-side
  envelopes are emitted per feature (Source, GherkinDocument, Pickles), then a single set of
  StepDefinition / TestRun* / TestCase* / execution envelopes spans all pickles — matching
  the `multiple-features` golden.
  """
  @spec run_features([{String.t(), keyword()}], StepRegistry.t(), keyword()) :: [envelope()]
  def run_features(features, registry, run_opts \\ [])

  def run_features(features, %StepRegistry{} = registry, run_opts) do
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

    # 2. StepDefinition envelopes (one per registered definition, registration order).
    {step_def_envelopes, def_ids} = step_definition_envelopes(registry, ids)
    ids = def_ids.ids

    # 3. TestRunStarted.
    {test_run_started_id, ids} = Ids.next(ids)
    test_run_started = test_run_started_envelope(test_run_started_id)

    # 4. Plan every pickle into a TestCase (all emitted before execution begins).
    {test_cases, ids} =
      Enum.map_reduce(pickles, ids, fn pickle, ids ->
        plan_test_case(pickle, registry, def_ids.by_definition, test_run_started_id, ids)
      end)

    test_case_envelopes = Enum.map(test_cases, & &1.envelope)

    # 5. Execute each planned test case, threading a per-scenario world.
    {execution_envelopes, _ids} =
      Enum.flat_map_reduce(test_cases, ids, fn test_case, ids ->
        execute_test_case(test_case, ids)
      end)

    success = run_success?(execution_envelopes)

    parser_envelopes ++
      step_def_envelopes ++
      [test_run_started] ++
      test_case_envelopes ++
      execution_envelopes ++
      [test_run_finished_envelope(test_run_started_id, success)]
  end

  @doc "Serialize an envelope list to NDJSON using the gherkin key-sorted serializer."
  @spec to_ndjson([envelope()]) :: String.t()
  def to_ndjson(envelopes), do: Message.to_ndjson(envelopes)

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

  defp plan_test_case(pickle, registry, def_ids, test_run_started_id, ids) do
    {test_case_id, ids} = Ids.next(ids)

    {planned_steps, ids} =
      Enum.map_reduce(pickle.steps, ids, fn pickle_step, ids ->
        {test_step_id, ids} = Ids.next(ids)
        matches = Matcher.matches(registry, pickle_step.text)

        {%{
           id: test_step_id,
           pickle_step: pickle_step,
           matches: matches,
           definition_ids: Enum.map(matches, fn m -> Map.fetch!(def_ids, m.definition) end)
         }, ids}
      end)

    test_steps_json = Enum.map(planned_steps, &test_step_json/1)

    envelope = %{
      "testCase" => %{
        "id" => test_case_id,
        "pickleId" => pickle.id,
        "testRunStartedId" => test_run_started_id,
        "testSteps" => test_steps_json
      }
    }

    {%{id: test_case_id, steps: planned_steps, envelope: envelope}, ids}
  end

  defp test_step_json(planned_step) do
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

    # Thread two skip-propagation flags across the scenario's steps (cucumber-js semantics,
    # see the CCK `failedish-combinations` sample):
    #
    #   * `failed_ish?`    — a prior step reported a non-PASSED status. This skips later
    #                        *executable* steps (a single match that would run a def) but
    #                        leaves UNDEFINED/AMBIGUOUS steps reporting their own status.
    #   * `intrinsic_skip?` — a prior step's *intrinsic* status was SKIPPED (a `"skipped"`
    #                        return or a raised `Cabbage.SkippedError`). A real skip
    #                        cascades to *every* later step, even undefined/ambiguous ones.
    acc0 = %{envelopes: [], world: %{}, failed_ish?: false, intrinsic_skip?: false, ids: ids}

    acc =
      Enum.reduce(test_case.steps, acc0, fn planned_step, acc ->
        execute_step(planned_step, test_case_started_id, acc)
      end)

    finished = test_case_finished_envelope(test_case_started_id, acc.ids)
    {[started] ++ acc.envelopes ++ [finished], acc.ids}
  end

  # Execute (or skip) one planned step, returning the updated accumulator.
  defp execute_step(planned_step, test_case_started_id, acc) do
    {intrinsic, new_world} = intrinsic_status(planned_step, acc.world)
    reported = report_status(intrinsic, acc)

    suggestions =
      if reported == :undefined,
        do: suggestion_snippets(planned_step.pickle_step.text),
        else: []

    {step_envelopes, ids} =
      emit_step(planned_step, test_case_started_id, acc.ids, reported, suggestions)

    %{
      acc
      | envelopes: acc.envelopes ++ step_envelopes,
        world: new_world,
        ids: ids,
        failed_ish?: acc.failed_ish? or reported != :passed,
        intrinsic_skip?: acc.intrinsic_skip? or intrinsic_skip?(intrinsic)
    }
  end

  # The status a step would have *on its own*, ignoring prior steps: UNDEFINED when no
  # definition matches, AMBIGUOUS when more than one does, otherwise the run result.
  defp intrinsic_status(planned_step, world) do
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

    case result do
      "pending" -> {:pending, world}
      :pending -> {:pending, world}
      "skipped" -> {:skipped, world}
      :skipped -> {:skipped, world}
      {:ok, new_world} when is_map(new_world) -> {:passed, new_world}
      _ -> {:passed, world}
    end
  rescue
    # Dedicated pending/skip exceptions carry the reference type names so the message
    # stream distinguishes "pending via exception" from "pending via return value".
    _error in Cabbage.PendingError -> {{:pending, "PendingException"}, world}
    _error in Cabbage.SkippedError -> {{:skipped, "SkippedException"}, world}
    error -> {{:failed, exception_type(error)}, world}
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
    result =
      %{"status" => status_string(status), "duration" => timestamp(0)}
      |> maybe_put_exception(status)

    %{
      "testStepFinished" => %{
        "testCaseStartedId" => test_case_started_id,
        "testStepId" => test_step_id,
        "testStepResult" => result,
        "timestamp" => timestamp(Ids.tick(ids))
      }
    }
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
