# SPDX-FileCopyrightText: 2024 ash_mysql contributors <https://github.com/ash-project/ash_mysql/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshMysql.Functions.Like do
  @moduledoc """
  Maps to a case-sensitive SQL `LIKE` (forced via a case-sensitive collation).
  """

  use Ash.Query.Function, name: :like, predicate?: true

  def args, do: [[:string, :string], [:ci_string, :string]]
end
