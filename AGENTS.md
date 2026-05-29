# AGENTS.md — NPlusOneDetector Integration Guide

This file tells AI assistants how to integrate `NPlusOneDetector` into an Elixir/Phoenix project that uses Ecto.

## What this library does

Detects N+1 queries during the test suite by hooking into Ecto's `prepare_query/3` callback. When the same query shape fires N times in the same process, it logs a warning and — if the offending line is in code changed on the current branch — fails the test. Pre-existing N+1s in untouched code only warn.

## When to integrate

Integrate this whenever you find an Elixir/Phoenix project that:
- Uses Ecto for database access
- Has a test suite (`test/test_helper.exs` exists)
- Has a `Repo` module with (or without) an existing `prepare_query/3`

Do not integrate into non-Ecto projects or projects without tests.

## Integration steps

### 1. Add the dependency

In `mix.exs`, add to the `deps` list **as test-only**:

```elixir
{:n_plus_one_detector, "~> 0.1", only: :test}
```

Then run:

```bash
mix deps.get
```

### 2. Wire into the Repo

Find the project's main Repo module (usually `lib/<app_name>/repo.ex`). It looks like:

```elixir
defmodule MyApp.Repo do
  use Ecto.Repo, otp_app: :my_app, adapter: Ecto.Adapters.Postgres
  ...
end
```

Add this directive to suppress the compiler warning that appears when `NPlusOneDetector`
is not available in non-test builds:

```elixir
@compile {:no_warn_undefined, NPlusOneDetector}
```

**Case A — No existing `prepare_query/3`:** add this block inside the module:

```elixir
if Mix.env() == :test do
  @impl Ecto.Repo
  def prepare_query(operation, query, opts) do
    NPlusOneDetector.track(operation, query, :my_app)
    {query, opts}
  end
end
```

**Case B — `prepare_query/3` already exists:** add one line at the top of the existing implementation:

```elixir
@impl Ecto.Repo
def prepare_query(operation, query, opts) do
  if Mix.env() == :test, do: NPlusOneDetector.track(operation, query, :my_app)

  # ... existing logic below, e.g. timeout handling ...
  case Process.get(:force_db_timeout) do
    nil -> {query, opts}
    timeout -> {query, Keyword.put(opts, :timeout, timeout)}
  end
end
```

Replace `:my_app` with the actual OTP app atom from `use Ecto.Repo, otp_app: :...`.

### 3. Set up the test helper

Open `test/test_helper.exs`. Add this **before** `ExUnit.start()`:

```elixir
NPlusOneDetector.TestHelper.setup(otp_app: :my_app)
```

Replace `:my_app` with the same OTP app atom used in step 2.

### 4. Verify the integration

Run any controller or context test that touches the database:

```bash
mix test test/my_app_web/controllers/some_controller_test.exs --no-color 2>&1 | grep "N+1 Detector"
```

If integration is working, N+1s will appear as:

```
[warning] [N+1 Detector] 6x `all` on `locations`
Triggered at lib/my_app/orders.ex:142
To skip: add `# n+1:skip` on line 141 of lib/my_app/orders.ex
```

If nothing appears, either there are no N+1s in the tested code (good!) or the integration isn't firing. Check step 2 — the most common mistake is passing the wrong `otp_app` atom.

### 5. Run the full suite to find all N+1s

```bash
mix test --no-color 2>&1 | grep "N+1 Detector" | sort -u
```

This gives a deduplicated list of all detected N+1 patterns across the entire codebase.

## Opting out of a specific check

When an N+1 is intentional (e.g. inside a transaction where batching isn't possible, or a known pre-existing pattern you're not fixing in this PR), add `# n+1:skip` on the line immediately before the query call:

```elixir
# n+1:skip
Repo.preload(record, [:association])
```

This suppresses both the warning and any test failure for that callsite.

## Configuration (optional)

Add to `config/test.exs` to override defaults:

```elixir
config :n_plus_one_detector,
  threshold: 5,       # number of identical queries before triggering (default: 5)
  cap_multiplier: 3   # stop counting at threshold × cap_multiplier (default: 3)
```

Pass extra options to `setup/1` if needed:

```elixir
NPlusOneDetector.TestHelper.setup(
  otp_app: :my_app,
  backtrace_depth: 30,        # Erlang stack depth (default: 30)
  base_branch: "origin/main"  # branch to diff against (default: "origin/main")
)
```

## How the CI failure works

`TestHelper.setup/1` runs `git diff --unified=0 origin/main...HEAD` at test startup and stores a map of `%{"lib/file.ex" => MapSet.t(changed_line_numbers)}` in application config.

When an N+1 is detected, the stacktrace is checked against that map. If any frame lands on a changed line, the test **fails**. If all frames are in untouched code, it **only warns**. This means:

- Your PR introducing a new N+1 → test fails, you fix it before merging
- Pre-existing N+1s in unrelated code → warning only, your PR is not blocked

## Files to check after integration

- `mix.exs` — dep added under `only: :test`
- `lib/<app>/repo.ex` — `prepare_query/3` calls `NPlusOneDetector.track/3`
- `test/test_helper.exs` — `NPlusOneDetector.TestHelper.setup/1` called before `ExUnit.start()`
