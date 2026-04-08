# SPDX-FileCopyrightText: 2023 ash_sqlite contributors <https://github.com/ash-project/ash_sqlite/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshSqlite.MigrationGenerator.Operation do
  @moduledoc false

  defmodule Helper do
    @moduledoc false
    def join(list),
      do:
        list
        |> List.flatten()
        |> Enum.reject(&is_nil/1)
        |> Enum.join(", ")
        |> String.replace(", )", ")")

    def maybe_add_default("nil"), do: nil
    def maybe_add_default(value), do: "default: #{value}"

    def maybe_add_primary_key(true), do: "primary_key: true"
    def maybe_add_primary_key(_), do: nil

    def maybe_add_null(false), do: "null: false"
    def maybe_add_null(_), do: nil

    def in_quotes(nil), do: nil
    def in_quotes(value), do: "\"#{value}\""

    def as_atom(value) when is_atom(value), do: Macro.inspect_atom(:remote_call, value)
    # sobelow_skip ["DOS.StringToAtom"]
    def as_atom(value), do: Macro.inspect_atom(:remote_call, String.to_atom(value))

    def option(key, value) when key in [:nulls_distinct, "nulls_distinct"] do
      if !value do
        "#{as_atom(key)}: #{inspect(value)}"
      end
    end

    def option(key, value) do
      if value do
        "#{as_atom(key)}: #{inspect(value)}"
      end
    end

    def on_delete(%{on_delete: on_delete}) when on_delete in [:delete, :nilify] do
      "on_delete: :#{on_delete}_all"
    end

    def on_delete(%{on_delete: on_delete}) when is_atom(on_delete) and not is_nil(on_delete) do
      "on_delete: :#{on_delete}"
    end

    def on_delete(_), do: nil

    def on_update(%{on_update: on_update}) when on_update in [:update, :nilify] do
      "on_update: :#{on_update}_all"
    end

    def on_update(%{on_update: on_update}) when is_atom(on_update) and not is_nil(on_update) do
      "on_update: :#{on_update}"
    end

    def on_update(_), do: nil

    def reference_type(
          %{type: :integer},
          %{destination_attribute_generated: true, destination_attribute_default: "nil"}
        ) do
      :bigint
    end

    def reference_type(%{type: type}, _) do
      type
    end

    @doc false
    def column_def(attribute, multitenancy) do
      do_column_def(attribute, multitenancy)
    end

    # Multitenancy reference
    defp do_column_def(
           %{
             references:
               %{
                 table: table,
                 destination_attribute: reference_attribute,
                 multitenancy: %{strategy: :attribute, attribute: destination_attribute}
               } = reference
           } = attribute,
           %{strategy: :attribute, attribute: source_attribute}
         ) do
      with_match =
        if destination_attribute != reference_attribute do
          "with: [#{as_atom(source_attribute)}: :#{as_atom(destination_attribute)}], match: :full"
        end

      size =
        if attribute[:size] do
          "size: #{attribute[:size]}"
        end

      [
        "add #{inspect(attribute.source)}",
        "references(:#{as_atom(table)}",
        [
          "column: #{inspect(reference_attribute)}",
          with_match,
          "name: #{inspect(reference.name)}",
          "type: #{inspect(reference_type(attribute, reference))}",
          on_delete(reference),
          on_update(reference),
          size
        ],
        ")",
        maybe_add_default(attribute.default),
        maybe_add_primary_key(attribute.primary_key?),
        maybe_add_null(attribute.allow_nil?)
      ]
      |> join()
    end

    # Plain reference
    defp do_column_def(
           %{
             references:
               %{
                 table: table,
                 destination_attribute: destination_attribute
               } = reference
           } = attribute,
           _multitenancy
         ) do
      size =
        if attribute[:size] do
          "size: #{attribute[:size]}"
        end

      [
        "add #{inspect(attribute.source)}",
        "references(:#{as_atom(table)}",
        [
          "column: #{inspect(destination_attribute)}",
          "name: #{inspect(reference.name)}",
          "type: #{inspect(reference_type(attribute, reference))}",
          size,
          on_delete(reference),
          on_update(reference)
        ],
        ")",
        maybe_add_default(attribute.default),
        maybe_add_primary_key(attribute.primary_key?),
        maybe_add_null(attribute.allow_nil?)
      ]
      |> join()
    end

    # Bigserial
    defp do_column_def(%{type: :bigint, default: "nil", generated?: true} = attribute, _multitenancy) do
      [
        "add #{inspect(attribute.source)}",
        ":bigserial",
        maybe_add_null(attribute.allow_nil?),
        maybe_add_primary_key(attribute.primary_key?)
      ]
      |> join()
    end

    # Serial
    defp do_column_def(%{type: :integer, default: "nil", generated?: true} = attribute, _multitenancy) do
      [
        "add #{inspect(attribute.source)}",
        ":serial",
        maybe_add_null(attribute.allow_nil?),
        maybe_add_primary_key(attribute.primary_key?)
      ]
      |> join()
    end

    # Plain attribute
    defp do_column_def(attribute, _multitenancy) do
      size =
        if attribute[:size] do
          "size: #{attribute[:size]}"
        end

      [
        "add #{inspect(attribute.source)}",
        "#{inspect(attribute.type)}",
        maybe_add_null(attribute.allow_nil?),
        maybe_add_default(attribute.default),
        size,
        maybe_add_primary_key(attribute.primary_key?)
      ]
      |> join()
    end
  end

  defmodule CreateTable do
    @moduledoc false
    defstruct [:table, :multitenancy, :old_multitenancy, options: []]
  end

  defmodule AddAttribute do
    @moduledoc false
    defstruct [:attribute, :table, :multitenancy, :old_multitenancy]

    def up(%{attribute: attribute, multitenancy: multitenancy}) do
      Helper.column_def(attribute, multitenancy)
    end

    def down(
          %{
            attribute: attribute,
            table: table,
            multitenancy: multitenancy
          } = op
        ) do
      AshSqlite.MigrationGenerator.Operation.RemoveAttribute.up(%{
        op
        | attribute: attribute,
          table: table,
          multitenancy: multitenancy
      })
    end
  end

  defmodule AlterDeferrability do
    @moduledoc false
    # SQLite does not support deferrable constraints. This is a no-op.
    defstruct [:table, :references, :direction, no_phase: true]

    def up(_), do: ""
    def down(_), do: ""
  end

  defmodule AlterAttribute do
    @moduledoc false
    defstruct [
      :old_attribute,
      :new_attribute,
      :table,
      :multitenancy,
      :old_multitenancy
    ]

    import Helper

    defp alter_opts(attribute, old_attribute) do
      primary_key =
        cond do
          attribute.primary_key? and !old_attribute.primary_key? ->
            ", primary_key: true"

          old_attribute.primary_key? and !attribute.primary_key? ->
            ", primary_key: false"

          true ->
            nil
        end

      default =
        if attribute.default != old_attribute.default do
          if is_nil(attribute.default) do
            ", default: nil"
          else
            ", default: #{attribute.default}"
          end
        end

      null =
        if attribute.allow_nil? != old_attribute.allow_nil? do
          ", null: #{attribute.allow_nil?}"
        end

      "#{null}#{default}#{primary_key}"
    end

    def up(%{
          multitenancy: multitenancy,
          old_attribute: old_attribute,
          new_attribute: attribute
        }) do
      type_or_reference =
        if AshSqlite.MigrationGenerator.has_reference?(multitenancy, attribute) and
             Map.get(old_attribute, :references) != Map.get(attribute, :references) do
          reference(multitenancy, attribute)
        else
          inspect(attribute.type)
        end

      "modify #{inspect(attribute.source)}, #{type_or_reference}#{alter_opts(attribute, old_attribute)}"
    end

    defp reference(
           %{strategy: :attribute, attribute: source_attribute},
           %{
             references:
               %{
                 multitenancy: %{strategy: :attribute, attribute: destination_attribute},
                 table: table,
                 destination_attribute: reference_attribute
               } = reference
           } = attribute
         ) do
      with_match =
        if destination_attribute != reference_attribute do
          "with: [#{as_atom(source_attribute)}: :#{as_atom(destination_attribute)}], match: :full"
        end

      size =
        if attribute[:size] do
          "size: #{attribute[:size]}"
        end

      join([
        "references(:#{as_atom(table)}, column: #{inspect(reference_attribute)}",
        with_match,
        "name: #{inspect(reference.name)}",
        "type: #{inspect(reference_type(attribute, reference))}",
        size,
        on_delete(reference),
        on_update(reference),
        ")"
      ])
    end

    defp reference(
           _,
           %{
             references:
               %{
                 table: table,
                 destination_attribute: destination_attribute
               } = reference
           } = attribute
         ) do
      size =
        if attribute[:size] do
          "size: #{attribute[:size]}"
        end

      join([
        "references(:#{as_atom(table)}, column: #{inspect(destination_attribute)}",
        "name: #{inspect(reference.name)}",
        "type: #{inspect(reference_type(attribute, reference))}",
        size,
        on_delete(reference),
        on_update(reference),
        ")"
      ])
    end

    def down(op) do
      up(%{
        op
        | old_attribute: op.new_attribute,
          new_attribute: op.old_attribute,
          old_multitenancy: op.multitenancy,
          multitenancy: op.old_multitenancy
      })
    end
  end

  defmodule DropForeignKey do
    @moduledoc false
    # DropForeignKey operations are absorbed into Phase.RebuildTable at the
    # group_into_phases stage. The rebuild handles FK changes via CREATE TABLE
    # with the new schema. These up/down implementations are no-ops.
    defstruct [:attribute, :table, :multitenancy, :direction, no_phase: true]

    def up(_), do: ""
    def down(_), do: ""
  end

  defmodule RenameAttribute do
    @moduledoc false
    defstruct [
      :old_attribute,
      :new_attribute,
      :table,
      :multitenancy,
      :old_multitenancy,
      no_phase: true
    ]

    import Helper

    def up(%{
          old_attribute: old_attribute,
          new_attribute: new_attribute,
          table: table
        }) do
      table_statement = join([":#{as_atom(table)}"])

      "rename table(#{table_statement}), #{inspect(old_attribute.source)}, to: #{inspect(new_attribute.source)}"
    end

    def down(
          %{
            old_attribute: old_attribute,
            new_attribute: new_attribute
          } = data
        ) do
      up(%{data | new_attribute: old_attribute, old_attribute: new_attribute})
    end
  end

  defmodule RemoveAttribute do
    @moduledoc false
    defstruct [:attribute, :table, :multitenancy, :old_multitenancy, commented?: false]

    def up(%{attribute: attribute, commented?: true}) do
      """
      # Attribute removal has been commented out to avoid data loss. See the migration generator documentation for more
      # If you uncomment this, be sure to also uncomment the corresponding attribute *addition* in the `down` migration
      # remove #{inspect(attribute.source)}
      """
    end

    def up(%{attribute: attribute}) do
      "remove #{inspect(attribute.source)}"
    end

    def down(%{attribute: attribute, multitenancy: multitenancy, commented?: true}) do
      prefix = """
      # This is the `down` migration of the statement:
      #
      #     remove #{inspect(attribute.source)}
      #
      """

      contents =
        %AshSqlite.MigrationGenerator.Operation.AddAttribute{
          attribute: attribute,
          multitenancy: multitenancy
        }
        |> AshSqlite.MigrationGenerator.Operation.AddAttribute.up()
        |> String.split("\n")
        |> Enum.map_join("\n", &"# #{&1}")

      prefix <> "\n" <> contents
    end

    def down(%{attribute: attribute, multitenancy: multitenancy, table: table}) do
      AshSqlite.MigrationGenerator.Operation.AddAttribute.up(
        %AshSqlite.MigrationGenerator.Operation.AddAttribute{
          attribute: attribute,
          table: table,
          multitenancy: multitenancy
        }
      )
    end
  end

  defmodule AddUniqueIndex do
    @moduledoc false
    defstruct [:identity, :table, :multitenancy, :old_multitenancy, no_phase: true]

    import Helper

    def up(%{
          identity:
            %{name: name, keys: keys, base_filter: base_filter, index_name: index_name} = identity,
          table: table,
          multitenancy: multitenancy
        }) do
      nils_distinct? = Map.get(identity, :nils_distinct?, true)

      keys =
        case multitenancy.strategy do
          :attribute ->
            [multitenancy.attribute | keys]

          _ ->
            keys
        end

      index_name = index_name || "#{table}_#{name}_index"

      if base_filter do
        "create unique_index(:#{as_atom(table)}, [#{Enum.map_join(keys, ", ", &inspect/1)}], where: \"#{base_filter}\", #{join(["name: \"#{index_name}\"", option("nulls_distinct", nils_distinct?)])})"
      else
        "create unique_index(:#{as_atom(table)}, [#{Enum.map_join(keys, ", ", &inspect/1)}], #{join(["name: \"#{index_name}\"", option("nulls_distinct", nils_distinct?)])})"
      end
    end

    def down(%{
          identity: %{name: name, keys: keys, index_name: index_name},
          table: table,
          multitenancy: multitenancy
        }) do
      keys =
        case multitenancy.strategy do
          :attribute ->
            [multitenancy.attribute | keys]

          _ ->
            keys
        end

      index_name = index_name || "#{table}_#{name}_index"

      "drop_if_exists unique_index(:#{as_atom(table)}, [#{Enum.map_join(keys, ", ", &inspect/1)}], #{join(["name: \"#{index_name}\""])})"
    end
  end

  defmodule AddCustomStatement do
    @moduledoc false
    defstruct [:statement, :table, no_phase: true]

    def up(%{statement: %{up: up, code?: false}}) do
      """
      execute(\"\"\"
      #{String.trim(up)}
      \"\"\")
      """
    end

    def up(%{statement: %{up: up, code?: true}}) do
      up
    end

    def down(%{statement: %{down: down, code?: false}}) do
      """
      execute(\"\"\"
      #{String.trim(down)}
      \"\"\")
      """
    end

    def down(%{statement: %{down: down, code?: true}}) do
      down
    end
  end

  defmodule RemoveCustomStatement do
    @moduledoc false
    defstruct [:statement, :table, no_phase: true]

    def up(%{statement: statement, table: table}) do
      AddCustomStatement.down(%AddCustomStatement{statement: statement, table: table})
    end

    def down(%{statement: statement, table: table}) do
      AddCustomStatement.up(%AddCustomStatement{statement: statement, table: table})
    end
  end

  defmodule AddCustomIndex do
    @moduledoc false
    defstruct [:table, :index, :base_filter, :multitenancy, no_phase: true]
    import Helper

    def up(%{
          index: index,
          table: table,
          base_filter: base_filter,
          multitenancy: multitenancy
        }) do
      keys =
        case multitenancy.strategy do
          :attribute ->
            [to_string(multitenancy.attribute) | Enum.map(index.fields, &to_string/1)]

          _ ->
            Enum.map(index.fields, &to_string/1)
        end

      index =
        if index.where && base_filter do
          %{index | where: base_filter <> " AND " <> index.where}
        else
          index
        end

      opts =
        join([
          option(:name, index.name),
          option(:unique, index.unique),
          option(:using, index.using),
          option(:where, index.where),
          option(:include, index.include)
        ])

      if opts == "",
        do: "create index(:#{as_atom(table)}, [#{Enum.map_join(keys, ", ", &inspect/1)}])",
        else:
          "create index(:#{as_atom(table)}, [#{Enum.map_join(keys, ", ", &inspect/1)}], #{opts})"
    end

    def down(%{index: index, table: table, multitenancy: multitenancy}) do
      index_name = AshSqlite.CustomIndex.name(table, index)

      keys =
        case multitenancy.strategy do
          :attribute ->
            [to_string(multitenancy.attribute) | Enum.map(index.fields, &to_string/1)]

          _ ->
            Enum.map(index.fields, &to_string/1)
        end

      "drop_if_exists index(:#{as_atom(table)}, [#{Enum.map_join(keys, ", ", &inspect/1)}], #{join(["name: \"#{index_name}\""])})"
    end
  end

  defmodule RemovePrimaryKey do
    @moduledoc false
    defstruct [:table, no_phase: true]

    def up(%{table: table}) do
      "drop constraint(#{inspect(table)}, \"#{table}_pkey\")"
    end

    def down(_) do
      ""
    end
  end

  defmodule RemovePrimaryKeyDown do
    @moduledoc false
    defstruct [:table, no_phase: true]

    def up(_) do
      ""
    end

    def down(%{table: table}) do
      "drop constraint(#{inspect(table)}, \"#{table}_pkey\")"
    end
  end

  defmodule RemoveCustomIndex do
    @moduledoc false
    defstruct [:table, :index, :base_filter, :multitenancy, no_phase: true]
    import Helper

    def up(%{index: index, table: table, multitenancy: multitenancy}) do
      index_name = AshSqlite.CustomIndex.name(table, index)

      keys =
        case multitenancy.strategy do
          :attribute ->
            [to_string(multitenancy.attribute) | Enum.map(index.fields, &to_string/1)]

          _ ->
            Enum.map(index.fields, &to_string/1)
        end

      "drop_if_exists index(:#{as_atom(table)}, [#{Enum.map_join(keys, ", ", &inspect/1)}], #{join(["name: \"#{index_name}\""])})"
    end

    def down(%{
          index: index,
          table: table,
          base_filter: base_filter,
          multitenancy: multitenancy
        }) do
      keys =
        case multitenancy.strategy do
          :attribute ->
            [to_string(multitenancy.attribute) | Enum.map(index.fields, &to_string/1)]

          _ ->
            Enum.map(index.fields, &to_string/1)
        end

      index =
        if index.where && base_filter do
          %{index | where: base_filter <> " AND " <> index.where}
        else
          index
        end

      opts =
        join([
          option(:name, index.name),
          option(:unique, index.unique),
          option(:using, index.using),
          option(:where, index.where),
          option(:include, index.include)
        ])

      if opts == "" do
        "create index(:#{as_atom(table)}, [#{Enum.map_join(keys, ", ", &inspect/1)}])"
      else
        "create index(:#{as_atom(table)}, [#{Enum.map_join(keys, ", ", &inspect/1)}], #{opts})"
      end
    end
  end

  defmodule RenameUniqueIndex do
    @moduledoc false
    defstruct [
      :new_identity,
      :old_identity,
      :table,
      :multitenancy,
      :old_multitenancy,
      no_phase: true
    ]

    import Helper

    def up(%{
          old_identity: old,
          new_identity: new,
          table: table,
          multitenancy: multitenancy
        }) do
      old_name = old.index_name || "#{table}_#{old.name}_index"
      keys = index_keys(new, multitenancy)

      "drop_if_exists unique_index(:#{as_atom(table)}, [#{keys}], name: \"#{old_name}\")\n" <>
        "create unique_index(:#{as_atom(table)}, [#{keys}], name: \"#{new.index_name}\")\n"
    end

    def down(%{
          old_identity: old,
          new_identity: new,
          table: table,
          multitenancy: multitenancy
        }) do
      old_name = old.index_name || "#{table}_#{old.name}_index"
      keys = index_keys(old, multitenancy)

      "drop_if_exists unique_index(:#{as_atom(table)}, [#{keys}], name: \"#{new.index_name}\")\n" <>
        "create unique_index(:#{as_atom(table)}, [#{keys}], name: \"#{old_name}\")\n"
    end

    defp index_keys(identity, multitenancy) do
      keys =
        case multitenancy do
          %{strategy: :attribute, attribute: mt_attr} when not is_nil(mt_attr) ->
            [mt_attr | identity.keys]

          _ ->
            identity.keys
        end

      Enum.map_join(keys, ", ", &inspect/1)
    end
  end

  defmodule RemoveUniqueIndex do
    @moduledoc false
    defstruct [:identity, :table, :multitenancy, :old_multitenancy, no_phase: true]

    import Helper

    def up(%{
          identity: %{name: name, keys: keys, index_name: index_name},
          table: table,
          old_multitenancy: multitenancy
        }) do
      keys =
        case multitenancy.strategy do
          :attribute ->
            [multitenancy.attribute | keys]

          _ ->
            keys
        end

      index_name = index_name || "#{table}_#{name}_index"

      "drop_if_exists unique_index(:#{as_atom(table)}, [#{Enum.map_join(keys, ", ", &inspect/1)}], #{join(["name: \"#{index_name}\""])})"
    end

    def down(%{
          identity: %{name: name, keys: keys, base_filter: base_filter, index_name: index_name},
          table: table,
          multitenancy: multitenancy
        }) do
      keys =
        case multitenancy.strategy do
          :attribute ->
            [multitenancy.attribute | keys]

          _ ->
            keys
        end

      index_name = index_name || "#{table}_#{name}_index"

      if base_filter do
        "create unique_index(:#{as_atom(table)}, [#{Enum.map_join(keys, ", ", &inspect/1)}], where: \"#{base_filter}\", #{join(["name: \"#{index_name}\""])})"
      else
        "create unique_index(:#{as_atom(table)}, [#{Enum.map_join(keys, ", ", &inspect/1)}], #{join(["name: \"#{index_name}\""])})"
      end
    end
  end
end
