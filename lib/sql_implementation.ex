# SPDX-FileCopyrightText: 2024 ash_mysql contributors <https://github.com/ash-project/ash_mysql/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshMysql.SqlImplementation do
  @moduledoc false
  use AshSql.Implementation

  require Ecto.Query

  @impl true
  def manual_relationship_function, do: :ash_mysql_join

  @impl true
  def manual_relationship_subquery_function, do: :ash_mysql_subquery

  @impl true
  def strpos_function, do: "CHARINDEX"

  @impl true
  def ilike?, do: true

  @impl true
  def expr(
        query,
        %like{arguments: [arg1_source, arg2_source], embedded?: pred_embedded?},
        bindings,
        embedded?,
        acc,
        type
      )
      when like in [AshMysql.Functions.Like, AshMysql.Functions.ILike] do
    {arg1, acc} =
      AshSql.Expr.dynamic_expr(
        query,
        arg1_source,
        bindings,
        pred_embedded? || embedded?,
        :string,
        acc
      )

    {arg2, acc} =
      AshSql.Expr.dynamic_expr(
        query,
        arg2_source,
        bindings,
        pred_embedded? || embedded?,
        :string,
        acc
      )

    # `like` on a ci_string matches case-insensitively, mirroring postgres citext
    inner_dyn =
      if like == AshMysql.Functions.Like and not ci_string_expr?(arg1_source) do
        Ecto.Query.dynamic(
          fragment(
            "? COLLATE Latin1_General_CS_AS LIKE ? COLLATE Latin1_General_CS_AS",
            ^arg1,
            ^arg2
          )
        )
      else
        Ecto.Query.dynamic(like(fragment("LOWER(?)", ^arg1), fragment("LOWER(?)", ^arg2)))
      end

    if type != Ash.Type.Boolean do
      {:ok, inner_dyn, acc}
    else
      {:ok, Ecto.Query.dynamic(type(^inner_dyn, ^type)), acc}
    end
  end

  # ash_sql's default handling of these builds patterns for postgres semantics:
  # backslash-escaped LIKE patterns (SQL Server has no default escape character and
  # treats `[` as a wildcard), `strpos(haystack, needle)` (CHARINDEX takes its
  # arguments in the opposite order), and `||` concatenation.
  def expr(
        query,
        %mod{arguments: [left, right], embedded?: pred_embedded?},
        bindings,
        embedded?,
        acc,
        type
      )
      when mod in [
             Ash.Query.Function.Contains,
             Ash.Query.Function.StringStartsWith,
             Ash.Query.Function.StringEndsWith
           ] do
    {left_expr, acc} =
      AshSql.Expr.dynamic_expr(query, left, bindings, pred_embedded? || embedded?, :string, acc)

    # a ci_string on either side matches case-insensitively, mirroring postgres citext
    ci? = match?(%Ash.CiString{}, right) or ci_string_expr?(left)

    {inner_dyn, acc} =
      case right do
        string_or_ci when is_binary(string_or_ci) or is_struct(string_or_ci, Ash.CiString) ->
          string =
            case string_or_ci do
              %Ash.CiString{string: string} -> string
              string -> string
            end

          pattern = like_pattern(mod, string)

          if ci? do
            {Ecto.Query.dynamic(
               like(fragment("LOWER(?)", ^left_expr), fragment("LOWER(?)", ^pattern))
             ), acc}
          else
            {Ecto.Query.dynamic(
               fragment(
                 "? COLLATE Latin1_General_CS_AS LIKE ? COLLATE Latin1_General_CS_AS",
                 ^left_expr,
                 ^pattern
               )
             ), acc}
          end

        other ->
          {right_expr, acc} =
            AshSql.Expr.dynamic_expr(
              query,
              other,
              bindings,
              pred_embedded? || embedded?,
              :string,
              acc
            )

          dyn =
            case {mod, ci?} do
              {Ash.Query.Function.Contains, false} ->
                Ecto.Query.dynamic(
                  fragment(
                    "CHARINDEX(? COLLATE Latin1_General_CS_AS, ? COLLATE Latin1_General_CS_AS) > 0",
                    ^right_expr,
                    ^left_expr
                  )
                )

              {Ash.Query.Function.Contains, true} ->
                Ecto.Query.dynamic(
                  fragment("CHARINDEX(LOWER(?), LOWER(?)) > 0", ^right_expr, ^left_expr)
                )

              {Ash.Query.Function.StringStartsWith, false} ->
                Ecto.Query.dynamic(
                  fragment(
                    "CHARINDEX(? COLLATE Latin1_General_CS_AS, ? COLLATE Latin1_General_CS_AS) = 1",
                    ^right_expr,
                    ^left_expr
                  )
                )

              {Ash.Query.Function.StringStartsWith, true} ->
                Ecto.Query.dynamic(
                  fragment("CHARINDEX(LOWER(?), LOWER(?)) = 1", ^right_expr, ^left_expr)
                )

              {Ash.Query.Function.StringEndsWith, false} ->
                Ecto.Query.dynamic(
                  fragment(
                    "CHARINDEX(REVERSE(? COLLATE Latin1_General_CS_AS), REVERSE(? COLLATE Latin1_General_CS_AS)) = 1",
                    ^right_expr,
                    ^left_expr
                  )
                )

              {Ash.Query.Function.StringEndsWith, true} ->
                Ecto.Query.dynamic(
                  fragment(
                    "CHARINDEX(REVERSE(LOWER(?)), REVERSE(LOWER(?))) = 1",
                    ^right_expr,
                    ^left_expr
                  )
                )
            end

          {dyn, acc}
      end

    if type != Ash.Type.Boolean do
      {:ok, inner_dyn, acc}
    else
      {:ok, Ecto.Query.dynamic(type(^inner_dyn, ^type)), acc}
    end
  end

  def expr(
        query,
        %Ash.Query.Function.StringPosition{arguments: [left, right], embedded?: pred_embedded?},
        bindings,
        embedded?,
        acc,
        _type
      ) do
    {left_expr, acc} =
      AshSql.Expr.dynamic_expr(query, left, bindings, pred_embedded? || embedded?, :string, acc)

    {right_expr, acc} =
      AshSql.Expr.dynamic_expr(query, right, bindings, pred_embedded? || embedded?, :string, acc)

    {:ok,
     Ecto.Query.dynamic(
       fragment(
         "CHARINDEX(? COLLATE Latin1_General_CS_AS, ? COLLATE Latin1_General_CS_AS)",
         ^right_expr,
         ^left_expr
       )
     ), acc}
  end

  def expr(
        query,
        %Ash.Query.Function.StringLength{arguments: [value], embedded?: pred_embedded?},
        bindings,
        embedded?,
        acc,
        _type
      ) do
    {value_expr, acc} =
      AshSql.Expr.dynamic_expr(query, value, bindings, pred_embedded? || embedded?, :string, acc)

    {:ok, Ecto.Query.dynamic(fragment("LEN(?)", ^value_expr)), acc}
  end

  def expr(
        query,
        %Ash.Query.Function.StringTrim{arguments: [value], embedded?: pred_embedded?},
        bindings,
        embedded?,
        acc,
        _type
      ) do
    {value_expr, acc} =
      AshSql.Expr.dynamic_expr(query, value, bindings, pred_embedded? || embedded?, :string, acc)

    {:ok, Ecto.Query.dynamic(fragment("LTRIM(RTRIM(?))", ^value_expr)), acc}
  end

  def expr(
        query,
        %Ash.Query.Function.GetPath{
          arguments: [%Ash.Query.Ref{attribute: %{type: type}}, right]
        } = get_path,
        bindings,
        embedded?,
        acc,
        nil
      )
      when is_atom(type) and is_list(right) do
    if Ash.Type.embedded_type?(type) do
      type = determine_type_at_path(type, right)

      do_get_path(query, get_path, bindings, embedded?, acc, type)
    else
      do_get_path(query, get_path, bindings, embedded?, acc)
    end
  end

  def expr(
        query,
        %Ash.Query.Function.GetPath{
          arguments: [%Ash.Query.Ref{attribute: %{type: {:array, type}}}, right]
        } = get_path,
        bindings,
        embedded?,
        acc,
        nil
      )
      when is_atom(type) and is_list(right) do
    if Ash.Type.embedded_type?(type) do
      type = determine_type_at_path(type, right)
      do_get_path(query, get_path, bindings, embedded?, acc, type)
    else
      do_get_path(query, get_path, bindings, embedded?, acc)
    end
  end

  def expr(
        query,
        %Ash.Query.Function.GetPath{} = get_path,
        bindings,
        embedded?,
        acc,
        type
      ) do
    do_get_path(query, get_path, bindings, embedded?, acc, type)
  end

  # Honestly we need to either 1. not type cast or 2. build in type compatibility concepts
  # instead of `:same` we need an `ANY COMPATIBLE` equivalent.
  @cast_operands_for [:<>]

  def expr(
        query,
        %{
          __predicate__?: _,
          left: %Ash.Query.Ref{} = left,
          right: right,
          embedded?: pred_embedded?,
          operator: :==
        },
        bindings,
        embedded?,
        acc,
        _type
      )
      when is_integer(right) do
    {left_expr, acc} =
      AshSql.Expr.dynamic_expr(
        query,
        left,
        Map.put(bindings, :no_cast?, true),
        pred_embedded? || embedded?,
        nil,
        acc
      )

    {right_expr, acc} =
      AshSql.Expr.dynamic_expr(
        query,
        right,
        bindings,
        pred_embedded? || embedded?,
        nil,
        acc
      )

    {:ok, Ecto.Query.dynamic(^left_expr == ^right_expr), acc}
  end

  def expr(
        query,
        %mod{
          __predicate__?: _,
          left: left,
          right: right,
          embedded?: pred_embedded?,
          operator: operator
        },
        bindings,
        embedded?,
        acc,
        type
      )
      when operator in [:<>, :||, :&&] do
    {[left_type, right_type], _return_type} = mod |> determine_types([left, right])

    {left_expr, acc} =
      if left_type && operator in @cast_operands_for do
        {left_expr, acc} =
          AshSql.Expr.dynamic_expr(query, left, bindings, pred_embedded? || embedded?, nil, acc)

        left_type = parameterized_type(left_type, [])

        {type_expr(left_expr, left_type), acc}
      else
        AshSql.Expr.dynamic_expr(
          query,
          left,
          bindings,
          pred_embedded? || embedded?,
          left_type,
          acc
        )
      end

    {right_expr, acc} =
      if right_type && operator in @cast_operands_for do
        {right_expr, acc} =
          AshSql.Expr.dynamic_expr(query, right, bindings, pred_embedded? || embedded?, nil, acc)

        right_type = parameterized_type(left_type, [])

        {type_expr(right_expr, right_type), acc}
      else
        AshSql.Expr.dynamic_expr(
          query,
          right,
          bindings,
          pred_embedded? || embedded?,
          right_type,
          acc
        )
      end

    {expr, acc} =
      case operator do
        :<> ->
          AshSql.Expr.dynamic_expr(
            query,
            %Ash.Query.Function.Fragment{
              embedded?: pred_embedded?,
              arguments: [
                raw: "CONCAT( ",
                casted_expr: left_expr,
                raw: ", ",
                casted_expr: right_expr,
                raw: ")"
              ]
            },
            bindings,
            embedded?,
            type,
            acc
          )

        :|| ->
          AshSql.Expr.dynamic_expr(
            query,
            %Ash.Query.Function.Fragment{
              embedded?: pred_embedded?,
              arguments: [
                raw: "CASE WHEN (",
                casted_expr: left_expr,
                raw: " LIKE CAST(0 AS bit) OR ",
                casted_expr: left_expr,
                raw: " IS NULL) THEN ",
                casted_expr: right_expr,
                raw: " ELSE ",
                casted_expr: left_expr,
                raw: " END"
              ]
            },
            bindings,
            embedded?,
            type,
            acc
          )

        :&& ->
          AshSql.Expr.dynamic_expr(
            query,
            %Ash.Query.Function.Fragment{
              embedded?: pred_embedded?,
              arguments: [
                raw: "CASE WHEN (",
                casted_expr: left_expr,
                raw: " LIKE CAST(0 AS bit) OR ",
                casted_expr: left_expr,
                raw: " IS NULL) THEN ",
                casted_expr: left_expr,
                raw: " ELSE ",
                casted_expr: right_expr,
                raw: " END"
              ]
            },
            bindings,
            embedded?,
            type,
            acc
          )
      end

    {:ok, expr, acc}
  end

  @impl true
  def expr(
        _query,
        _expr,
        _bindings,
        _embedded?,
        _acc,
        _type
      ) do
    :error
  end

  @impl true
  def type_expr(expr, nil), do: expr

  def type_expr(expr, {tag, type}) when is_list(expr) and tag in [:array, :in] do
    Enum.map(expr, &uuid_expr(&1, type))
  end

  def type_expr(expr, {tag, _type}) when tag in [:array, :in] do
    expr
  end

  def type_expr(expr, type) when is_atom(type) do
    type = Ash.Type.get_type(type)

    expr = uuid_expr(expr, type)

    cond do
      !Ash.Type.ash_type?(type) ->
        Ecto.Query.dynamic(type(^expr, ^type))

      Ash.Type.storage_type(type, []) == :ci_string ->
        Ecto.Query.dynamic(fragment("(? COLLATE SQL_Latin1_General_CP1_CI_AI)", ^expr))

      true ->
        Ecto.Query.dynamic(type(^expr, ^Ash.Type.storage_type(type, [])))
    end
  end

  def type_expr(expr, type) do
    expr = uuid_expr(expr, type)

    case type do
      {:parameterized, {inner_type, constraints}} ->
        if inner_type.type(constraints) == :ci_string do
          Ecto.Query.dynamic(fragment("(? COLLATE SQL_Latin1_General_CP1_CI_AI)", ^expr))
        else
          Ecto.Query.dynamic(type(^expr, ^type))
        end

      nil ->
        expr

      type ->
        Ecto.Query.dynamic(type(^expr, ^type))
    end
  end

  defp uuid_expr(expr, {:parameterized, {Ash.Type.UUID.EctoType, _}}) when is_binary(expr) do
    case Ash.Type.dump_to_native(Ash.Type.UUID, expr) do
      {:ok, v} -> v
      _ -> expr
    end
  end

  defp uuid_expr(expr, _type) do
    expr
  end

  @impl true
  def table(resource) do
    AshMysql.DataLayer.Info.table(resource)
  end

  @impl true
  def schema(_resource) do
    nil
  end

  @impl true
  def repo(resource, _kind) do
    AshMysql.DataLayer.Info.repo(resource)
  end

  @impl true
  def multicolumn_distinct?, do: false

  @impl true
  def parameterized_type({:parameterized, _} = type, _) do
    type
  end

  def parameterized_type({:parameterized, _, _} = type, _) do
    type
  end

  def parameterized_type({:in, type}, constraints) do
    parameterized_type({:array, type}, constraints)
  end

  def parameterized_type({:array, type}, constraints) do
    case parameterized_type(type, constraints[:items] || []) do
      nil ->
        nil

      type ->
        {:array, type}
    end
  end

  def parameterized_type({type, constraints}, []) do
    parameterized_type(type, constraints)
  end

  def parameterized_type(type, constraints) do
    if Ash.Type.ash_type?(type) do
      cast_in_query? =
        if function_exported?(Ash.Type, :cast_in_query?, 2) do
          Ash.Type.cast_in_query?(type, constraints)
        else
          Ash.Type.cast_in_query?(type)
        end

      if cast_in_query? do
        type = Ash.Type.ecto_type(type)

        parameterized_type(type, constraints)
      else
        nil
      end
    else
      if is_atom(type) && :erlang.function_exported(type, :type, 1) do
        Ecto.ParameterizedType.init(type, constraints || [])
      else
        type
      end
    end
  end

  @impl true
  def determine_types(mod, args, returns \\ nil) do
    returns =
      case returns do
        {:parameterized, _} -> nil
        {:array, {:parameterized, _}} -> nil
        {:array, {type, constraints}} when type != :array -> {type, [items: constraints]}
        {:array, _} -> nil
        {type, constraints} -> {type, constraints}
        other -> other
      end

    {types, new_returns} = Ash.Expr.determine_types(mod, args, returns)

    {types, new_returns || returns}
  end

  defp do_get_path(
         _query,
         %Ash.Query.Function.GetPath{arguments: [left, right]},
         _bindings,
         _embedded?,
         acc,
         _type \\ nil
       ) do
    field = Ash.Query.Ref.name(left)
    json_path = sql_server_json_path(right)

    expr =
      Ecto.Query.dynamic(
        [row],
        fragment("JSON_VALUE(?, ?)", field(row, ^field), ^json_path)
      )

    {:ok, expr, acc}
  end

  defp ci_string_expr?(%Ash.Query.Ref{attribute: %{type: type} = attribute}) do
    constraints = Map.get(attribute, :constraints) || []

    Ash.Type.ash_type?(type) && Ash.Type.storage_type(type, constraints) == :ci_string
  end

  defp ci_string_expr?(%Ash.CiString{}), do: true
  defp ci_string_expr?(_), do: false

  defp like_pattern(Ash.Query.Function.Contains, string), do: "%" <> escape_like(string) <> "%"
  defp like_pattern(Ash.Query.Function.StringStartsWith, string), do: escape_like(string) <> "%"
  defp like_pattern(Ash.Query.Function.StringEndsWith, string), do: "%" <> escape_like(string)

  # SQL Server LIKE has no default escape character, but `[...]` character
  # classes can escape all wildcards without needing an ESCAPE clause.
  defp escape_like(string) do
    String.replace(string, ["[", "%", "_"], fn
      "[" -> "[[]"
      "%" -> "[%]"
      "_" -> "[_]"
    end)
  end

  defp sql_server_json_path(segments) do
    Enum.reduce(segments, "$", fn
      segment, path when is_integer(segment) ->
        path <> "[#{segment}]"

      segment, "$" ->
        "$." <> to_string(segment)

      segment, path ->
        path <> "." <> to_string(segment)
    end)
  end

  defp determine_type_at_path(type, path) do
    path
    |> Enum.reject(&is_integer/1)
    |> do_determine_type_at_path(type)
    |> case do
      nil ->
        nil

      {type, constraints} ->
        parameterized_type(type, constraints)
    end
  end

  defp do_determine_type_at_path([], _), do: nil

  defp do_determine_type_at_path([item], type) do
    case Ash.Resource.Info.attribute(type, item) do
      nil ->
        nil

      %{type: {:array, type}, constraints: constraints} ->
        constraints = constraints[:items] || []

        {type, constraints}

      %{type: type, constraints: constraints} ->
        {type, constraints}
    end
  end

  defp do_determine_type_at_path([item | rest], type) do
    case Ash.Resource.Info.attribute(type, item) do
      nil ->
        nil

      %{type: {:array, type}} ->
        if Ash.Type.embedded_type?(type) do
          type
        else
          nil
        end

      %{type: type} ->
        if Ash.Type.embedded_type?(type) do
          type
        else
          nil
        end
    end
    |> case do
      nil ->
        nil

      type ->
        do_determine_type_at_path(rest, type)
    end
  end
end
