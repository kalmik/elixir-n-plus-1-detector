defmodule NPlusOneDetector do
  @moduledoc """
  N+1 query detector for Ecto, designed for the test environment.

  Tracks repeated identical query shapes within a process via Ecto's
  `prepare_query/3` hook. When the threshold is crossed, it warns and
  optionally fails the test if the offending line is in code changed on
  the current branch.

  ## Setup

  Add to your `mix.exs` (test only):

      {:n_plus_one_detector, "~> 0.1", only: :test}

  Call `NPlusOneDetector.TestHelper.setup/1` at the top of your
  `test/test_helper.exs`:

      NPlusOneDetector.TestHelper.setup(otp_app: :my_app)

  Add a `prepare_query/3` callback to your `Repo` (or extend your existing one):

      if Mix.env() == :test do
        @impl Ecto.Repo
        def prepare_query(operation, query, opts) do
          NPlusOneDetector.track(operation, query, :my_app)
          {query, opts}
        end
      end

  ## Opting out

  Add `# n+1:skip` on the line immediately before a query call to suppress
  the warning and test failure for that specific callsite:

      # n+1:skip
      Repo.preload(items, [:location])

  ## Configuration

      config :n_plus_one_detector,
        threshold: 5,         # queries before warning (default: 5)
        cap_multiplier: 3     # stop tracking at threshold * multiplier (default: 3)
  """

  require Logger

  @skip_marker "# n+1:skip"
  @process_key :n_plus_one_tracker

  @doc """
  Tracks a query execution. Call this from your Repo's `prepare_query/3`.

  `otp_app` is used to identify your app's frames in the stacktrace —
  pass the same atom you use in `use Ecto.Repo, otp_app: :my_app`.
  """
  @spec track(atom(), Ecto.Query.t(), atom()) :: :ok
  def track(operation, query, otp_app) do
    threshold = Application.get_env(:n_plus_one_detector, :threshold, 5)
    multiplier = Application.get_env(:n_plus_one_detector, :cap_multiplier, 3)
    cap = threshold * multiplier

    source = source_name(query)
    key = fingerprint(operation, query, otp_app)
    tracker = Process.get(@process_key, %{})
    entry = Map.get(tracker, key, %{count: 0})
    count = entry.count + 1

    if entry.count < cap do
      Process.put(@process_key, Map.put(tracker, key, %{entry | count: count}))
    end

    if count >= threshold do
      trace = capture_stacktrace(otp_app)
      frames = extract_frames(trace, otp_app)

      unless skip_annotated?(frames) do
        {trigger_file, trigger_line} = find_trigger_frame(frames, trace, otp_app)

        Logger.warning("""
        [N+1 Detector] #{count}x `#{operation}` on `#{source}`
        Triggered at #{trigger_file}:#{trigger_line}
        To skip: add `#{@skip_marker}` on line #{trigger_line - 1} of #{trigger_file}

        #{trace}
        """)

        maybe_fail(count, source, operation, frames)
      end
    end

    :ok
  end

  defp maybe_fail(count, source, operation, frames) do
    changed_lines = Application.get_env(:n_plus_one_detector, :changed_lines, %{})

    if map_size(changed_lines) > 0 do
      match =
        Enum.find(frames, fn {file, line} ->
          changed_lines |> Map.get(file, MapSet.new()) |> MapSet.member?(line)
        end)

      if match do
        {file, line} = match

        raise """
        N+1 detected on changed line `#{file}:#{line}`:
        #{count}x `#{operation}` on `#{source}`

        Hint: preload the association before the loop instead of inside it.
        To silence intentionally: add `#{@skip_marker}` on line #{line - 1} of #{file}
        """
      end
    end
  end

  # Prefers anonymous fn frames — they indicate the loop callback where the
  # N+1 call happens, which is more actionable than the innermost DB query frame.
  defp find_trigger_frame(frames, trace, otp_app) do
    anon_frame =
      ~r/\(#{otp_app}[^)]+\) ([^:]+):(\d+): anonymous fn/
      |> Regex.scan(trace)
      |> case do
        [[_, file, line] | _] -> {file, String.to_integer(line)}
        [] -> nil
      end

    anon_frame || List.first(frames, {"unknown", 0})
  end

  # Checks if any frame has `# n+1:skip` on the preceding line.
  defp skip_annotated?(frames) do
    Enum.any?(frames, fn {file, line} ->
      file
      |> File.stream!()
      |> Enum.at(line - 2)
      |> case do
        nil -> false
        content -> String.contains?(content, @skip_marker)
      end
    end)
  rescue
    _ -> false
  end

  defp extract_frames(trace, otp_app) do
    # Capture the function name to exclude `prepare_query` frames — they are
    # always in the stacktrace as the hook point, never the N+1 source.
    ~r/\(#{otp_app}[^)]+\) ([^:]+):(\d+): ([^\n]+)/
    |> Regex.scan(trace)
    |> Enum.reject(fn [_, _file, _line, fun] -> String.contains?(fun, "prepare_query") end)
    |> Enum.map(fn [_, file, line, _fun] -> {file, String.to_integer(line)} end)
  end

  defp capture_stacktrace(otp_app) do
    self()
    |> Process.info(:current_stacktrace)
    |> elem(1)
    |> Exception.format_stacktrace()
    |> String.split("\n")
    |> Enum.filter(&String.contains?(&1, "(#{otp_app} "))
    |> Enum.take(20)
    |> Enum.join("\n")
  end

  # Ecto represents params as {:^, [], [index]} in the AST — the index, not the
  # value — so two queries with the same shape but different param values produce
  # the same fingerprint without any normalization.
  #
  # The full app-level call chain hash is included so that independent top-level
  # operations that route through the same DB callsite get separate counters.
  # A real N+1 loop produces an identical chain on every iteration, so it
  # accumulates and fires. Independent operations have different chains (the
  # caller frame differs), so they stay isolated.
  defp fingerprint(operation, query, otp_app) do
    {
      operation,
      query.from,
      Enum.map(query.wheres, & &1.expr),
      Enum.map(query.joins, &{&1.qual, &1.on.expr}),
      callchain_hash(otp_app)
    }
  end

  # Reads the raw stacktrace (no string formatting), filters to frames belonging
  # to otp_app (skipping the detector itself and the prepare_query hook), maps
  # to {file, line} pairs, and hashes the whole list. Two calls with identical
  # app-level chains produce the same hash; calls from different callers do not.
  #
  # Module membership is determined by prefix-matching the atom string against
  # the CamelCase equivalent of otp_app (e.g. :my_app → "Elixir.MyApp").
  # This mirrors how capture_stacktrace/1 identifies app frames from formatted
  # output, but works directly on the raw stacktrace without string formatting.
  defp callchain_hash(otp_app) do
    prefix = "Elixir." <> (otp_app |> Atom.to_string() |> Macro.camelize())

    self()
    |> Process.info(:current_stacktrace)
    |> elem(1)
    |> Enum.drop_while(fn {mod, _fun, _arity, _loc} -> mod == __MODULE__ end)
    |> Enum.filter(fn {mod, fun, _arity, _loc} ->
      Atom.to_string(mod) |> String.starts_with?(prefix) and fun != :prepare_query
    end)
    |> Enum.map(fn {_mod, _fun, _arity, location} ->
      {Keyword.get(location, :file, ""), Keyword.get(location, :line, 0)}
    end)
    |> :erlang.phash2()
  end

  defp source_name(%{from: %{source: {table, _}}}), do: table
  defp source_name(_), do: "unknown"
end
