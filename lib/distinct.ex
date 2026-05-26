# SPDX-FileCopyrightText: 2024 ash_mysql contributors <https://github.com/ash-project/ash_mysql/graphs.contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshMysql.Distinct do
  @moduledoc false
  import Ecto.Query

  def distinct(query, empty, resource) when empty in [nil, []] do
    AshSql.Sort.apply_sort(query, query.__ash_bindings__[:sort], resource)
  end

  def distinct(query, distinct_on, resource) do
    sql_behaviour = AshMysql.SqlImplementation
    original_query = query
    original_sort = query.__ash_bindings__[:sort]
    distinct_sort = query.__ash_bindings__[:distinct_sort] || original_sort || []

    distinct_sort =
      if distinct_sort == [] do
        Enum.map(distinct_on, fn
          {field, direction} -> {field, direction}
          field -> {field, :asc}
        end)
      else
        distinct_sort
      end

    query =
      query
      |> Ecto.Query.exclude(:order_by)
      |> AshSql.Bindings.default_bindings(resource, sql_behaviour)

    {partition_by, query} = partition_by_exprs(query, distinct_on)

    with {:ok, query} <- AshSql.Sort.apply_sort(query, distinct_sort, resource, :direct),
         distinct_query = distinct_query_with_row_number(query, partition_by),
         {calculations_require_rewrite, aggregates_require_rewrite, distinct_query} =
           AshSql.Query.rewrite_nested_selects(distinct_query),
         deduped =
           from(row in subquery(distinct_query),
             as: ^0,
             where: row.__order__ == 1
           ),
         {:ok, deduped} <-
           deduped
           |> AshSql.Bindings.default_bindings(resource, sql_behaviour)
           |> AshSql.Sort.apply_sort(original_sort, resource) do
      {:ok,
       Map.update!(
         deduped,
         :__ash_bindings__,
         fn ash_bindings ->
           ash_bindings
           |> Map.put(
             :select_calculations,
             original_query.__ash_bindings__[:select_calculations]
           )
           |> Map.put(:select, original_query.__ash_bindings__[:select])
           |> Map.update(
             :calculations_require_rewrite,
             calculations_require_rewrite,
             &Map.merge(&1, calculations_require_rewrite)
           )
           |> Map.update(
             :aggregates_require_rewrite,
             aggregates_require_rewrite,
             &Map.merge(&1, aggregates_require_rewrite)
           )
         end
       )}
    end
  end

  defp distinct_query_with_row_number(query, partition_by) do
    order_by =
      case query.order_bys do
        [%{expr: expr} | _] -> [order_by: expr]
        _ -> []
      end

    window_expr =
      case query.order_bys do
        [template | _] ->
          %{template | expr: [partition_by: partition_by] ++ order_by}

        _ ->
          if Code.ensure_loaded?(Ecto.Query.ByExpr) do
            struct!(Ecto.Query.ByExpr, expr: [partition_by: partition_by] ++ order_by)
          else
            %Ecto.Query.QueryExpr{expr: [partition_by: partition_by] ++ order_by}
          end
      end

    query
    |> Ecto.Query.exclude(:order_by)
    |> Map.update!(:windows, &Keyword.put(&1, :distinct, window_expr))
    |> then(fn query ->
      from(row in query, select_merge: %{__order__: over(row_number(), :distinct)})
    end)
  end

  defp partition_by_exprs(query, distinct_on) do
    exprs =
      Enum.map(distinct_on, fn
        {field, _} -> partition_field_expr(query, field)
        field -> partition_field_expr(query, field)
      end)

    {exprs, query}
  end

  defp partition_field_expr(query, field) do
    case field do
      %Ash.Query.Calculation{} = calc ->
        partition_calculation_expr(query, calc)

      field when is_atom(field) ->
        binding = query.__ash_bindings__.root_binding
        dynamic = dynamic(field(as(^binding), ^field))

        dynamic
        |> then(
          &Ecto.Query.Builder.Dynamic.partially_expand(:order_by, query, &1, [], 0)
        )
        |> elem(0)

      other ->
        raise ArgumentError, "unsupported distinct field: #{inspect(other)}"
    end
  end

  defp partition_calculation_expr(query, calc) do
    resource = query.__ash_bindings__.resource

    ref = %Ash.Query.Ref{
      attribute: calc,
      relationship_path: [],
      resource: resource
    }

    bindings = Map.put(query.__ash_bindings__, :no_cast?, true)

    {dynamic, acc} = AshSql.Expr.dynamic_expr(query, ref, bindings)

    {expr, _, _, _query} =
      case dynamic do
        %Ecto.Query.DynamicExpr{} = dynamic ->
          result =
            Ecto.Query.Builder.Dynamic.partially_expand(
              :order_by,
              query,
              dynamic,
              [],
              0
            )

          {elem(result, 0), elem(result, 1), elem(result, 2),
           AshSql.Expr.merge_accumulator(query, acc)}

        other ->
          {other, [], 0, AshSql.Expr.merge_accumulator(query, acc)}
      end

    expr
  end
end
