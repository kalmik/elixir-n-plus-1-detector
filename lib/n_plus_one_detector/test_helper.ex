defmodule NPlusOneDetector.TestHelper do
  @moduledoc """
  Setup helper for `test/test_helper.exs`.

  Increases the Erlang stacktrace depth and computes the set of lines changed
  on the current branch (via `git diff`), storing them in application config
  so `NPlusOneDetector` can fail tests that introduce new N+1s.

  ## Usage

      # test/test_helper.exs
      NPlusOneDetector.TestHelper.setup(otp_app: :my_app)
      ExUnit.start()
  """

  @doc """
  Configures the detector for the current test run.

  Options:
  - `:otp_app` — required. Your application's OTP app name.
  - `:backtrace_depth` — number of stack frames to capture (default: 30).
  - `:base_branch` — git branch to diff against (default: `"origin/main"`).
  """
  def setup(opts \\ []) do
    depth = Keyword.get(opts, :backtrace_depth, 30)
    base = Keyword.get(opts, :base_branch, "origin/main")

    :erlang.system_flag(:backtrace_depth, depth)

    changed_lines = compute_changed_lines(base)
    Application.put_env(:n_plus_one_detector, :changed_lines, changed_lines)
  end

  @doc """
  Parses `git diff --unified=0` output into a map of
  `%{"lib/foo.ex" => MapSet.t(line_number)}`.

  Each `@@ -old +new_start,count @@` hunk header tells us which lines in the
  new file were added or modified. Deletion-only hunks (count 0) are skipped.
  """
  def parse_diff(diff) do
    diff
    |> String.split("\n")
    |> Enum.reduce({%{}, nil}, fn line, {acc, current_file} ->
      cond do
        String.starts_with?(line, "+++ b/") ->
          {acc, String.slice(line, 6..-1//1)}

        String.starts_with?(line, "@@ ") && current_file != nil ->
          case Regex.run(~r/@@ -\d+(?:,\d+)? \+(\d+)(?:,(\d+))? @@/, line) do
            [_, _, "0"] ->
              {acc, current_file}

            [_, start_str, count_str] ->
              start = String.to_integer(start_str)
              count = String.to_integer(count_str)
              lines = MapSet.new(start..(start + count - 1)//1)
              {Map.update(acc, current_file, lines, &MapSet.union(&1, lines)), current_file}

            [_, start_str] ->
              start = String.to_integer(start_str)
              lines = MapSet.new([start])
              {Map.update(acc, current_file, lines, &MapSet.union(&1, lines)), current_file}

            _ ->
              {acc, current_file}
          end

        true ->
          {acc, current_file}
      end
    end)
    |> elem(0)
  end

  defp compute_changed_lines(base) do
    # In CI, N_PLUS_ONE_BASE_SHA is set to github.event.pull_request.base.sha,
    # which gives the exact base commit without needing merge-base computation.
    # This avoids the three-dot diff failing on shallow clones.
    base_ref = System.get_env("N_PLUS_ONE_BASE_SHA") || base

    # credo:disable-for-this-file Credo.Check.Warning.UnsafeExec
    case System.cmd("git", ["diff", "--unified=0", "#{base_ref}...HEAD"],
           env: [],
           stderr_to_stdout: true
         ) do
      {output, 0} -> parse_diff(output)
      _ -> %{}
    end
  end
end
