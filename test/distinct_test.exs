# SPDX-FileCopyrightText: 2024 ash_mysql contributors <https://github.com/ash-project/ash_mysql/graphs.contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshMysql.DistinctTest do
  @moduledoc false
  use AshMysql.RepoCase, async: false
  alias AshMysql.Test.Post

  require Ash.Query

  # distinct requires `DISTINCT ON` or window functions, and ecto_sql's TDS
  # connection renders neither, so the data layer declares distinct unsupported.
  # Unskip once ecto_sql can render windows for MSSQL.
  @moduletag :skip

  setup do
    # MSSQL unique indexes treat multiple NULLs as duplicates, so each row needs
    # distinct values for the optional unique columns.
    for {title, score, n} <- [
          {"title", 1, 1},
          {"title", 1, 2},
          {"foo", 2, 3},
          {"foo", 2, 4}
        ] do
      Post
      |> Ash.Changeset.for_create(:create, %{
        title: title,
        score: score,
        uniq_one: "distinct-#{n}",
        uniq_two: "distinct-#{n}",
        uniq_custom_one: "distinct-#{n}",
        uniq_custom_two: "distinct-#{n}"
      })
      |> Ash.create!()
    end

    :ok
  end

  test "records returned are distinct on the provided field" do
    results =
      Post
      |> Ash.Query.distinct(:title)
      |> Ash.Query.sort(:title)
      |> Ash.read!()

    assert [%{title: "foo"}, %{title: "title"}] = results
  end

  test "distinct pairs well with sort" do
    results =
      Post
      |> Ash.Query.distinct(:title)
      |> Ash.Query.sort(title: :desc)
      |> Ash.read!()

    assert [%{title: "title"}, %{title: "foo"}] = results
  end

  test "distinct pairs well with sort that does not match the distinct" do
    results =
      Post
      |> Ash.Query.distinct(:title)
      |> Ash.Query.sort(id: :desc)
      |> Ash.Query.limit(3)
      |> Ash.read!()

    assert [_, _] = results
  end

  test "distinct pairs well with sort that does not match the distinct using a limit" do
    results =
      Post
      |> Ash.Query.distinct(:title)
      |> Ash.Query.sort(id: :desc)
      |> Ash.Query.limit(1)
      |> Ash.read!()

    assert [_] = results
  end
end
