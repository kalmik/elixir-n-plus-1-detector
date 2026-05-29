# NPlusOneDetector

N+1 query detector for Ecto test suites. Tracks repeated identical query shapes
via `prepare_query/3` and fails tests that introduce new N+1s — but only for lines
changed on the current branch, so pre-existing issues don't block your PR.

## Installation

```elixir
# mix.exs
def deps do
  [
    {:n_plus_one_detector, "~> 0.1", only: :test}
  ]
end
```

## Setup

**1. `test/test_helper.exs`** — add before `ExUnit.start()`:

```elixir
NPlusOneDetector.TestHelper.setup(otp_app: :my_app)
ExUnit.start()
```

**2. Your Repo** — call `track/3` from `prepare_query/3`:

```elixir
defmodule MyApp.Repo do
  use Ecto.Repo, otp_app: :my_app, adapter: Ecto.Adapters.Postgres

  if Mix.env() == :test do
    @impl Ecto.Repo
    def prepare_query(operation, query, opts) do
      NPlusOneDetector.track(operation, query, :my_app)
      {query, opts}
    end
  end
end
```

If you already have a `prepare_query/3`, just add the `track/3` call to it.

## How it works

- Every query goes through `track/3`, which fingerprints the query shape (operation + table + where/join AST) and increments a per-shape counter in the process dictionary.
- When the counter hits the threshold (default: 5), it captures a stacktrace and logs a warning with the exact file and line to annotate.
- If that line belongs to a file changed on the current branch (`git diff origin/main...HEAD`), the test **fails**. Pre-existing N+1s on untouched lines only warn.
- The anonymous-fn heuristic points the "trigger" at the loop callsite rather than the innermost DB query, making the warning immediately actionable.

## Example output

```
[warning] [N+1 Detector] 6x `all` on `locations`
Triggered at lib/my_app/orders.ex:142
To skip: add `# n+1:skip` on line 141 of lib/my_app/orders.ex

    (my_app 1.0.0) lib/my_app/orders.ex:142: anonymous fn/3 in MyApp.Orders.ship/2
    (my_app 1.0.0) lib/my_app/orders.ex:138: MyApp.Orders.ship/2
```

## Opting out

When an N+1 is intentional (e.g. inside a transaction where batching isn't possible),
add `# n+1:skip` on the line before the query call:

```elixir
# n+1:skip
Repo.preload(record, [:association])
```

This suppresses both the warning and the test failure for that callsite.

## Configuration

```elixir
# config/test.exs
config :n_plus_one_detector,
  threshold: 5,        # queries before triggering (default: 5)
  cap_multiplier: 3    # stop tracking at threshold × multiplier (default: 3)
```

`TestHelper.setup/1` also accepts:

```elixir
NPlusOneDetector.TestHelper.setup(
  otp_app: :my_app,
  backtrace_depth: 30,        # erlang stacktrace depth (default: 30)
  base_branch: "origin/main"  # git base for diff (default: "origin/main")
)
```
