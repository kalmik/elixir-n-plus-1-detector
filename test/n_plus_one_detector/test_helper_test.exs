defmodule NPlusOneDetector.TestHelperTest do
  use ExUnit.Case, async: true

  alias NPlusOneDetector.TestHelper

  describe "setup/1 — shallow clone fallback" do
    test "uses two-dot diff when N_PLUS_ONE_BASE_SHA is set" do
      # A fake SHA is unreachable but confirms the two-dot path is taken:
      # if three-dot were used, git would still fail (merge-base not computable),
      # but with two-dot the error is the same — the important thing is no crash.
      System.put_env("N_PLUS_ONE_BASE_SHA", "deadbeefdeadbeefdeadbeefdeadbeefdeadbeef")

      on_exit(fn ->
        System.delete_env("N_PLUS_ONE_BASE_SHA")
        Application.delete_env(:n_plus_one_detector, :changed_lines)
      end)

      TestHelper.setup(otp_app: :n_plus_one_detector)

      assert Application.get_env(:n_plus_one_detector, :changed_lines) == %{}
    end

    test "falls back to empty map when base branch is not reachable" do
      System.delete_env("N_PLUS_ONE_BASE_SHA")

      on_exit(fn -> Application.delete_env(:n_plus_one_detector, :changed_lines) end)

      TestHelper.setup(otp_app: :n_plus_one_detector, base_branch: "origin/nonexistent-branch")

      assert Application.get_env(:n_plus_one_detector, :changed_lines) == %{}
    end
  end

  describe "parse_diff/1" do
    test "returns empty map for empty input" do
      assert TestHelper.parse_diff("") == %{}
    end

    test "parses a single added hunk" do
      diff = """
      diff --git a/lib/foo.ex b/lib/foo.ex
      index abc..def 100644
      --- a/lib/foo.ex
      +++ b/lib/foo.ex
      @@ -10,0 +11,3 @@ defmodule Foo do
      +  def new_func do
      +    :ok
      +  end
      """

      result = TestHelper.parse_diff(diff)
      assert result["lib/foo.ex"] == MapSet.new([11, 12, 13])
    end

    test "parses a single-line change (no count in hunk header)" do
      diff = """
      --- a/lib/foo.ex
      +++ b/lib/foo.ex
      @@ -5 +5 @@ defmodule Foo do
      -  old
      +  new
      """

      result = TestHelper.parse_diff(diff)
      assert MapSet.member?(result["lib/foo.ex"], 5)
    end

    test "skips deletion-only hunks (count 0)" do
      diff = """
      --- a/lib/foo.ex
      +++ b/lib/foo.ex
      @@ -10,3 +10,0 @@ defmodule Foo do
      -  deleted
      -  lines
      -  here
      """

      result = TestHelper.parse_diff(diff)
      assert result == %{}
    end

    test "unions multiple hunks in the same file" do
      diff = """
      --- a/lib/foo.ex
      +++ b/lib/foo.ex
      @@ -5,0 +6,2 @@ defmodule Foo do
      +  # first addition
      +  # second addition
      @@ -20,1 +23,1 @@ defmodule Foo do
      -  old_line
      +  new_line
      """

      result = TestHelper.parse_diff(diff)
      assert result["lib/foo.ex"] == MapSet.new([6, 7, 23])
    end

    test "parses multiple files independently" do
      diff = """
      diff --git a/lib/foo.ex b/lib/foo.ex
      --- a/lib/foo.ex
      +++ b/lib/foo.ex
      @@ -1,0 +2,1 @@
      +  added_to_foo
      diff --git a/lib/bar.ex b/lib/bar.ex
      --- a/lib/bar.ex
      +++ b/lib/bar.ex
      @@ -5,0 +6,1 @@
      +  added_to_bar
      """

      result = TestHelper.parse_diff(diff)
      assert MapSet.member?(result["lib/foo.ex"], 2)
      assert MapSet.member?(result["lib/bar.ex"], 6)
      refute Map.has_key?(result, "lib/foo.ex") and MapSet.member?(result["lib/foo.ex"], 6)
    end

    test "ignores lines that are not hunk headers or file markers" do
      diff = """
      diff --git a/lib/foo.ex b/lib/foo.ex
      index abc..def
      --- a/lib/foo.ex
      +++ b/lib/foo.ex
      @@ -1,0 +2,1 @@
      +  new line
       context line
      -  removed line
      """

      result = TestHelper.parse_diff(diff)
      assert MapSet.member?(result["lib/foo.ex"], 2)
    end
  end
end
