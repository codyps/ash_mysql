# SPDX-FileCopyrightText: 2024 ash_mysql contributors <https://github.com/ash-project/ash_mysql/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshMysql.Functions.ILike do
  @moduledoc """
  Maps to a case-insensitive SQL `LIKE` (both sides lowercased).
  """

  use Ash.Query.Function, name: :ilike, predicate?: true

  def args, do: [[:string, :string], [:ci_string, :string]]
end
