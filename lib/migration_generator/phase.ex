# SPDX-FileCopyrightText: 2023 ash_sqlite contributors <https://github.com/ash-project/ash_sqlite/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshSqlite.MigrationGenerator.Phase do
  @moduledoc false

  defmodule Create do
    @moduledoc false
    defstruct [:table, :multitenancy, operations: [], options: [], commented?: false]

    import AshSqlite.MigrationGenerator.Operation.Helper, only: [as_atom: 1]

    def up(%{table: table, operations: operations, options: options}) do
      opts =
        if options[:strict?] do
          ~s', options: "STRICT"'
        else
          ""
        end

      "create table(:#{as_atom(table)}, primary_key: false#{opts}) do\n" <>
        Enum.map_join(operations, "\n", fn operation -> operation.__struct__.up(operation) end) <>
        "\nend"
    end

    def down(%{table: table}) do
      opts = ""

      "drop table(:#{as_atom(table)}#{opts})"
    end
  end

  defmodule RebuildTable do
    @moduledoc false
    defstruct [:table, :old_snapshot, :new_snapshot, :multitenancy, commented?: false]

    def up(%{table: table, old_snapshot: old_snapshot, new_snapshot: new_snapshot}) do
      rebuild(table, old_snapshot, new_snapshot)
    end

    def down(%{table: table, old_snapshot: old_snapshot, new_snapshot: new_snapshot}) do
      rebuild(table, new_snapshot, old_snapshot)
    end

    defp rebuild(table, from_snapshot, to_snapshot) do
      temp_table = "#{table}_migration_temp"

      # Build column definitions for CREATE TABLE
      column_defs = build_column_defs(to_snapshot)

      # Build INSERT ... SELECT column mapping (intersection of old and new by source name)
      common_columns = common_column_sources(from_snapshot, to_snapshot)

      # Build index statements
      drop_index_stmts = drop_index_statements(table, from_snapshot)
      create_index_stmts = create_index_statements(table, to_snapshot)

      lines = [
        ~s|execute("PRAGMA foreign_keys = OFF")|,
        "",
        "execute(\"\"\"",
        "CREATE TABLE \\\"#{temp_table}\\\" (",
        column_defs,
        ")",
        "\"\"\")",
        ""
      ]

      lines =
        lines ++
          if common_columns != [] do
            cols_str = Enum.map_join(common_columns, ", ", fn col -> "\\\"#{col}\\\"" end)

            [
              "execute(\"\"\"",
              "INSERT INTO \\\"#{temp_table}\\\" (#{cols_str})",
              "SELECT #{cols_str} FROM \\\"#{table}\\\"",
              "\"\"\")",
              ""
            ]
          else
            []
          end

      lines =
        lines ++
          [
            ~s|execute(~S[DROP TABLE "#{table}"])|,
            ~s|execute(~S[ALTER TABLE "#{temp_table}" RENAME TO "#{table}"])|,
            ""
          ]

      lines = lines ++ drop_index_stmts ++ create_index_stmts

      lines =
        lines ++
          [
            ~s|execute("PRAGMA foreign_keys = ON")|
          ]

      Enum.join(lines, "\n")
    end

    defp build_column_defs(snapshot) do
      attrs = snapshot.attributes

      # Add multitenancy attribute if strategy is :attribute
      attrs =
        case snapshot do
          %{multitenancy: %{strategy: :attribute, attribute: mt_attr}} when not is_nil(mt_attr) ->
            mt_source = mt_attr

            if Enum.any?(attrs, &(&1.source == mt_source)) do
              attrs
            else
              [
                %{
                  source: mt_source,
                  type: :uuid,
                  allow_nil?: false,
                  primary_key?: false,
                  default: "nil",
                  generated?: false
                }
                | attrs
              ]
            end

          _ ->
            attrs
        end

      primary_key_cols =
        attrs
        |> Enum.filter(& &1.primary_key?)
        |> Enum.map(fn attr -> "\\\"#{attr.source}\\\"" end)

      col_lines =
        Enum.map(attrs, fn attr ->
          type_str = sql_type(attr)
          null_str = if attr.allow_nil? == false, do: " NOT NULL", else: ""
          default_str = sql_default(attr)
          "  \\\"#{attr.source}\\\" #{type_str}#{null_str}#{default_str}"
        end)

      pk_line =
        if primary_key_cols != [] do
          "  PRIMARY KEY (#{Enum.join(primary_key_cols, ", ")})"
        end

      all_lines = col_lines ++ List.wrap(pk_line)

      Enum.join(all_lines, ",\n")
    end

    defp sql_type(%{type: :bigint}), do: "integer"
    defp sql_type(%{type: :integer}), do: "integer"
    defp sql_type(%{type: :bigserial}), do: "integer"
    defp sql_type(%{type: :serial}), do: "integer"
    defp sql_type(%{type: :uuid}), do: "uuid"
    defp sql_type(%{type: :text}), do: "text"
    defp sql_type(%{type: :boolean}), do: "boolean"
    defp sql_type(%{type: :binary}), do: "blob"
    defp sql_type(%{type: :date}), do: "date"
    defp sql_type(%{type: :time}), do: "time"

    defp sql_type(%{type: :naive_datetime}), do: "naive_datetime"
    defp sql_type(%{type: :utc_datetime}), do: "utc_datetime"
    defp sql_type(%{type: :naive_datetime_usec}), do: "naive_datetime_usec"
    defp sql_type(%{type: :utc_datetime_usec}), do: "utc_datetime_usec"
    defp sql_type(%{type: :float}), do: "float"
    defp sql_type(%{type: :decimal}), do: "decimal"
    defp sql_type(%{type: :map}), do: "text"
    defp sql_type(%{type: {:array, _}}), do: "text"
    defp sql_type(%{type: :citext}), do: "text"
    defp sql_type(%{type: {:varchar, size}}) when is_integer(size), do: "varchar(#{size})"
    defp sql_type(%{type: :varchar}), do: "varchar(255)"
    defp sql_type(%{type: type}) when is_atom(type), do: to_string(type)
    defp sql_type(_), do: "text"

    defp sql_default(%{default: "nil"}), do: ""
    defp sql_default(%{default: nil}), do: ""

    defp sql_default(%{default: default}) when is_binary(default) do
      cond do
        String.starts_with?(default, "\"") and String.ends_with?(default, "\"") ->
          inner = String.slice(default, 1..-2//1)
          " DEFAULT '#{inner}'"

        default == "true" ->
          " DEFAULT 1"

        default == "false" ->
          " DEFAULT 0"

        String.match?(default, ~r/^\d+$/) ->
          " DEFAULT #{default}"

        String.match?(default, ~r/^\d+\.\d+$/) ->
          " DEFAULT #{default}"

        true ->
          ""
      end
    end

    defp sql_default(_), do: ""

    defp common_column_sources(from_snapshot, to_snapshot) do
      from_sources = MapSet.new(from_snapshot.attributes, &to_string(&1.source))
      to_sources = MapSet.new(to_snapshot.attributes, &to_string(&1.source))

      to_snapshot.attributes
      |> Enum.map(&to_string(&1.source))
      |> Enum.filter(&MapSet.member?(from_sources, &1))
      |> Enum.filter(&MapSet.member?(to_sources, &1))
    end

    defp drop_index_statements(table, snapshot) do
      identity_drops =
        (snapshot[:identities] || [])
        |> Enum.map(fn identity ->
          index_name = identity[:index_name] || "#{table}_#{identity.name}_index"
          ~s|execute(~S[DROP INDEX IF EXISTS "#{index_name}"])|
        end)

      custom_drops =
        (snapshot[:custom_indexes] || [])
        |> Enum.map(fn index ->
          index_name = AshSqlite.CustomIndex.name(table, index)
          ~s|execute(~S[DROP INDEX IF EXISTS "#{index_name}"])|
        end)

      identity_drops ++ custom_drops
    end

    defp create_index_statements(table, snapshot) do
      identity_creates =
        (snapshot[:identities] || [])
        |> Enum.map(fn identity ->
          index_name = identity[:index_name] || "#{table}_#{identity.name}_index"

          keys =
            case snapshot[:multitenancy] do
              %{strategy: :attribute, attribute: mt_attr} when not is_nil(mt_attr) ->
                [mt_attr | identity.keys]

              _ ->
                identity.keys
            end

          cols = Enum.map_join(keys, ", ", fn col -> ~s|"#{col}"| end)
          ~s|execute(~S[CREATE UNIQUE INDEX "#{index_name}" ON "#{table}" (#{cols})])|
        end)

      custom_creates =
        (snapshot[:custom_indexes] || [])
        |> Enum.map(fn index ->
          index_name = AshSqlite.CustomIndex.name(table, index)

          keys =
            case snapshot[:multitenancy] do
              %{strategy: :attribute, attribute: mt_attr} when not is_nil(mt_attr) ->
                [to_string(mt_attr) | Enum.map(index.fields, &to_string/1)]

              _ ->
                Enum.map(index.fields, &to_string/1)
            end

          unique = if Map.get(index, :unique), do: "UNIQUE ", else: ""
          cols = Enum.map_join(keys, ", ", fn col -> ~s|"#{col}"| end)
          ~s|execute(~S[CREATE #{unique}INDEX "#{index_name}" ON "#{table}" (#{cols})])|
        end)

      identity_creates ++ custom_creates
    end
  end

  defmodule Alter do
    @moduledoc false
    defstruct [:table, :multitenancy, operations: [], commented?: false]

    import AshSqlite.MigrationGenerator.Operation.Helper, only: [as_atom: 1]

    def up(%{table: table, operations: operations}) do
      body =
        operations
        |> Enum.map_join("\n", fn operation -> operation.__struct__.up(operation) end)
        |> String.trim()

      if body == "" do
        ""
      else
        opts = ""

        "alter table(:#{as_atom(table)}#{opts}) do\n" <>
          body <>
          "\nend"
      end
    end

    def down(%{table: table, operations: operations}) do
      body =
        operations
        |> Enum.reverse()
        |> Enum.map_join("\n", fn operation -> operation.__struct__.down(operation) end)
        |> String.trim()

      if body == "" do
        ""
      else
        opts = ""

        "alter table(:#{as_atom(table)}#{opts}) do\n" <>
          body <>
          "\nend"
      end
    end
  end
end
