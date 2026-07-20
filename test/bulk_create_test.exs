# SPDX-FileCopyrightText: 2024 ash_mysql contributors <https://github.com/ash-project/ash_mysql/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshMysql.BulkCreateTest do
  use AshMysql.RepoCase, async: false
  alias AshMysql.Test.Post

  describe "bulk creates" do
    test "bulk creates insert each input" do
      Ash.bulk_create!([%{title: "fred"}, %{title: "george"}], Post, :create)

      assert [%{title: "fred"}, %{title: "george"}] =
               Post
               |> Ash.Query.sort(:title)
               |> Ash.read!()
    end

    test "bulk creates can be streamed" do
      assert [{:ok, %{title: "fred"}}, {:ok, %{title: "george"}}] =
               Ash.bulk_create!([%{title: "fred"}, %{title: "george"}], Post, :create,
                 return_stream?: true,
                 return_records?: true
               )
               |> Enum.sort_by(fn {:ok, result} -> result.title end)
    end

    test "bulk creates with upsert?: true return a clear error instead of plain-inserting" do
      assert %Ash.BulkResult{status: :error, errors: [error]} =
               Ash.bulk_create([%{title: "fred"}], Post, :create,
                 upsert?: true,
                 upsert_fields: [:title],
                 return_errors?: true
               )

      assert Exception.message(error) =~ "Upsert is not supported by the data layer"

      assert [] = Ash.read!(Post)
    end

    test "bulk creates with upsert?: true and return_skipped_upsert?: true return a clear error" do
      # This combination makes ash core fall back to per-changeset
      # `Ash.DataLayer.upsert/3` calls, bypassing `bulk_create` entirely.
      assert %Ash.BulkResult{status: :error, errors: [error]} =
               Ash.bulk_create([%{title: "fred"}], Post, :create,
                 upsert?: true,
                 upsert_fields: [:title],
                 return_skipped_upsert?: true,
                 return_errors?: true
               )

      assert Exception.message(error) =~ "Upsert is not supported by the data layer"

      assert [] = Ash.read!(Post)
    end

    test "bulk creates against a schema-scoped table reload from that schema" do
      # DDL is transactional on SQL Server, so these roll back with the sandbox.
      TestRepo.query!("CREATE SCHEMA other_schema")
      TestRepo.query!("SELECT * INTO other_schema.posts FROM dbo.posts WHERE 1 = 0")

      result =
        Ash.bulk_create!([%{title: "fred"}, %{title: "george"}], Post, :create,
          return_records?: true,
          context: %{data_layer: %{schema: "other_schema"}}
        )

      # The reload must run against other_schema.posts — before threading the
      # insert opts into the reload queries this crashed (reload against
      # dbo.posts found no rows).
      assert [%{title: "fred"}, %{title: "george"}] =
               Enum.sort_by(result.records, & &1.title)

      assert %{rows: [[2]]} = TestRepo.query!("SELECT COUNT(*) FROM other_schema.posts")
      assert [] = Ash.read!(Post)
    end

    test "bulk creates accept a tenant on non-context-multitenant resources" do
      # repo_opts/3 used to only have a nil-tenant clause, so any non-nil
      # tenant crashed with a FunctionClauseError before reaching the insert.
      assert %Ash.BulkResult{status: :success} =
               Ash.bulk_create([%{title: "fred"}], Post, :create,
                 tenant: "some_tenant",
                 return_errors?: true
               )
    end

    # no upserts for now. hopefully later
    @tag :skip
    test "bulk creates can upsert" do
      assert [
               {:ok, %{title: "fred", uniq_one: "one", uniq_two: "two", price: 10}},
               {:ok, %{title: "george", uniq_one: "three", uniq_two: "four", price: 20}}
             ] =
               Ash.bulk_create!(
                 [
                   %{title: "fred", uniq_one: "one", uniq_two: "two", price: 10},
                   %{title: "george", uniq_one: "three", uniq_two: "four", price: 20}
                 ],
                 Post,
                 :create,
                 return_stream?: true,
                 return_records?: true
               )
               |> Enum.sort_by(fn {:ok, result} -> result.title end)

      assert [
               {:ok, %{title: "fred", uniq_one: "one", uniq_two: "two", price: 1000}},
               {:ok, %{title: "george", uniq_one: "three", uniq_two: "four", price: 20_000}}
             ] =
               Ash.bulk_create!(
                 [
                   %{title: "something", uniq_one: "one", uniq_two: "two", price: 1000},
                   %{title: "else", uniq_one: "three", uniq_two: "four", price: 20_000}
                 ],
                 Post,
                 :create,
                 upsert?: true,
                 upsert_identity: :uniq_one_and_two,
                 upsert_fields: [:price],
                 return_stream?: true,
                 return_records?: true
               )
               |> Enum.sort_by(fn
                 {:ok, result} ->
                   result.title

                 _ ->
                   nil
               end)
    end

    test "bulk creates can create relationships" do
      Ash.bulk_create!(
        [%{title: "fred", rating: %{score: 5}}, %{title: "george", rating: %{score: 0}}],
        Post,
        :create
      )

      assert [
               %{title: "fred", ratings: [%{score: 5}]},
               %{title: "george", ratings: [%{score: 0}]}
             ] =
               Post
               |> Ash.Query.sort(:title)
               |> Ash.Query.load(:ratings)
               |> Ash.read!()
    end
  end

  describe "validation errors" do
    test "skips invalid by default" do
      assert %{records: [_], errors: [_]} =
               Ash.bulk_create([%{title: "fred"}, %{title: "not allowed"}], Post, :create,
                 return_records?: true,
                 return_errors?: true
               )
    end

    test "returns errors in the stream" do
      assert [{:ok, _}, {:error, _}] =
               Ash.bulk_create!([%{title: "fred"}, %{title: "not allowed"}], Post, :create,
                 return_records?: true,
                 return_stream?: true,
                 return_errors?: true
               )
               |> Enum.to_list()
    end
  end

  describe "database errors" do
    test "database errors affect the entire batch" do
      org =
        AshMysql.Test.Organization
        |> Ash.Changeset.for_create(:create, %{name: "foo"})
        |> Ash.create!()

      Ash.bulk_create(
        [
          %{title: "fred", organization_id: org.id},
          %{title: "george", organization_id: Ash.UUID.generate()}
        ],
        Post,
        :create,
        return_records?: true
      )

      assert [] =
               Post
               |> Ash.Query.sort(:title)
               |> Ash.read!()
    end

    test "database errors don't affect other batches" do
      Ash.bulk_create(
        [%{title: "george", organization_id: Ash.UUID.generate()}, %{title: "fred"}],
        Post,
        :create,
        return_records?: true,
        batch_size: 1
      )

      assert [%{title: "fred"}] =
               Post
               |> Ash.Query.sort(:title)
               |> Ash.read!()
    end
  end
end
