# SPDX-FileCopyrightText: 2024 ash_mysql contributors <https://github.com/ash-project/ash_mysql/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshMysql.Query do
  @moduledoc false

  import Ecto.Query

  # SQL Server requires TOP or OFFSET when ORDER BY appears in subqueries.
  @sentinel_limit 9_223_372_036_854_775_807

  def prepare_for_mssql(%Ecto.Query{} = query) do
    fix_query(query)
  end

  def prepare_for_mssql(other), do: other

  defp fix_query(%Ecto.Query{} = query) do
    query
    |> fix_from()
    |> fix_joins()
    |> fix_combinations()
    |> maybe_add_limit_for_order_by()
  end

  defp fix_from(%{from: %Ecto.Query.FromExpr{} = from} = query) do
    %{query | from: %{from | source: fix_source(from.source)}}
  end

  defp fix_from(query), do: query

  defp fix_joins(%{joins: joins} = query) when is_list(joins) do
    %{query | joins: Enum.map(joins, &fix_join/1)}
  end

  defp fix_joins(query), do: query

  defp fix_join(%{source: source} = join) do
    %{join | source: fix_source(source)}
  end

  defp fix_combinations(%{combinations: combinations} = query) when is_list(combinations) do
    %{
      query
      | combinations:
          Enum.map(combinations, fn {type, comb_query} ->
            {type, fix_query(comb_query)}
          end)
    }
  end

  defp fix_combinations(query), do: query

  defp fix_source(%Ecto.Query{} = query), do: fix_query(query)

  defp fix_source({prefix, %Ecto.Query{} = query}) do
    {prefix, fix_query(query)}
  end

  defp fix_source({prefix, %Ecto.SubQuery{query: subquery} = sub}) do
    {prefix, %{sub | query: fix_query(subquery)}}
  end

  defp fix_source(source), do: source

  defp maybe_add_limit_for_order_by(%{limit: _, offset: _} = query), do: query

  defp maybe_add_limit_for_order_by(%{limit: nil, offset: nil} = query) do
    if needs_limit_for_order_by?(query) do
      from(row in query, limit: ^@sentinel_limit)
    else
      query
    end
  end

  defp maybe_add_limit_for_order_by(query), do: query

  defp needs_limit_for_order_by?(%{order_bys: [_ | _]}), do: true

  defp needs_limit_for_order_by?(%{windows: windows}) when windows != [] and not is_nil(windows),
    do: true

  defp needs_limit_for_order_by?(_), do: false
end
