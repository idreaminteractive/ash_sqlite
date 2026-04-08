# SPDX-FileCopyrightText: 2023 ash_sqlite contributors <https://github.com/ash-project/ash_sqlite/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshSqlite.MigrationGeneratorTest do
  use AshSqlite.RepoCase, async: false
  @moduletag :migration
  @moduletag :tmp_dir

  import ExUnit.CaptureLog

  setup %{tmp_dir: tmp_dir} do
    current_shell = Mix.shell()
    :ok = Mix.shell(Mix.Shell.Process)

    on_exit(fn ->
      Mix.shell(current_shell)
    end)

    %{
      snapshot_path: Path.join(tmp_dir, "snapshots"),
      migration_path: Path.join(tmp_dir, "migrations")
    }
  end

  defmacrop defposts(mod \\ Post, do: body) do
    quote do
      Code.compiler_options(ignore_module_conflict: true)

      defmodule unquote(mod) do
        use Ash.Resource,
          domain: nil,
          data_layer: AshSqlite.DataLayer

        sqlite do
          table "posts"
          repo(AshSqlite.TestRepo)

          custom_indexes do
            # need one without any opts
            index(["id"])
            index(["id"], unique: true, name: "test_unique_index")
          end
        end

        actions do
          defaults([:create, :read, :update, :destroy])
        end

        unquote(body)
      end

      Code.compiler_options(ignore_module_conflict: false)
    end
  end

  defmacrop defdomain(resources) do
    quote do
      Code.compiler_options(ignore_module_conflict: true)

      defmodule Domain do
        use Ash.Domain

        resources do
          for resource <- unquote(resources) do
            resource(resource)
          end
        end
      end

      Code.compiler_options(ignore_module_conflict: false)
    end
  end

  describe "creating initial snapshots" do
    setup %{snapshot_path: snapshot_path, migration_path: migration_path} do
      defposts do
        sqlite do
          migration_types(second_title: {:varchar, 16})
          migration_defaults(title_with_default: "\"fred\"")
        end

        identities do
          identity(:title, [:title])
          identity(:thing, [:title, :second_title])
          identity(:thing_with_source, [:title, :title_with_source])
        end

        attributes do
          uuid_primary_key(:id)
          attribute(:title, :string)
          attribute(:second_title, :string)
          attribute(:title_with_source, :string, source: :t_w_s)
          attribute(:title_with_default, :string)
          attribute(:email, Test.Support.Types.Email)
        end
      end

      defdomain([Post])

      AshSqlite.MigrationGenerator.generate(Domain,
        snapshot_path: snapshot_path,
        migration_path: migration_path,
        quiet: true,
        format: false,
        auto_name: true
      )

      :ok
    end

    test "the migration sets up resources correctly", %{
      snapshot_path: snapshot_path,
      migration_path: migration_path
    } do
      # the snapshot exists and contains valid json
      assert File.read!(Path.wildcard("#{snapshot_path}/test_repo/posts/*.json"))
             |> Jason.decode!(keys: :atoms!)

      assert [file] = Path.wildcard("#{migration_path}/**/*_migrate_resources*.exs")

      file_contents = File.read!(file)

      # the migration creates the table
      assert file_contents =~ "create table(:posts, primary_key: false) do"

      # the migration sets up the custom_indexes
      assert file_contents =~
               ~S{create index(:posts, ["id"], name: "test_unique_index", unique: true)}

      assert file_contents =~ ~S{create index(:posts, ["id"]}

      # the migration adds the id, with its default
      assert file_contents =~
               ~S[add :id, :uuid, null: false, primary_key: true]

      # the migration adds the id, with its default
      assert file_contents =~
               ~S[add :title_with_default, :text, default: "fred"]

      # the migration adds other attributes
      assert file_contents =~ ~S[add :title, :text]

      # the migration unwraps newtypes
      assert file_contents =~ ~S[add :email, :text]

      # the migration adds custom attributes
      assert file_contents =~ ~S[add :second_title, :varchar, size: 16]

      # the migration creates unique_indexes based on the identities of the resource
      assert file_contents =~ ~S{create unique_index(:posts, [:title], name: "posts_title_index")}

      # the migration creates unique_indexes based on the identities of the resource
      assert file_contents =~
               ~S{create unique_index(:posts, [:title, :second_title], name: "posts_thing_index")}

      # the migration creates unique_indexes using the `source` on the attributes of the identity on the resource
      assert file_contents =~
               ~S{create unique_index(:posts, [:title, :t_w_s], name: "posts_thing_with_source_index")}
    end
  end

  describe "strict table" do
    setup %{snapshot_path: snapshot_path, migration_path: migration_path} do
      defposts do
        sqlite do
          strict?(true)
        end

        attributes do
          uuid_primary_key(:id)
          attribute(:title, :string)
        end
      end

      defdomain([Post])

      AshSqlite.MigrationGenerator.generate(Domain,
        snapshot_path: snapshot_path,
        migration_path: migration_path,
        quiet: true,
        format: false,
        auto_name: true
      )

      :ok
    end

    test "creates the table with the strict option", %{
      snapshot_path: snapshot_path,
      migration_path: migration_path
    } do
      # the snapshot exists and contains valid json
      assert File.read!(Path.wildcard("#{snapshot_path}/test_repo/posts/*.json"))
             |> Jason.decode!(keys: :atoms!)

      assert [file] = Path.wildcard("#{migration_path}/**/*_migrate_resources*.exs")

      file_contents = File.read!(file)

      # the migration creates the table
      assert file_contents =~ ~s'create table(:posts, primary_key: false, options: "STRICT") do'
    end
  end

  describe "dev migrations" do
    setup %{snapshot_path: snapshot_path, migration_path: migration_path} do
      defposts do
        identities do
          identity(:title, [:title])
        end

        attributes do
          uuid_primary_key(:id)
          attribute(:title, :string)
        end
      end

      defdomain([Post])

      AshSqlite.MigrationGenerator.generate(Domain,
        snapshot_path: snapshot_path,
        migration_path: migration_path,
        quiet: true,
        format: false,
        auto_name: true,
        dev: true
      )

      :ok
    end

    test "running it again doesn't create a new file", %{
      snapshot_path: snapshot_path,
      migration_path: migration_path
    } do
      defposts do
        identities do
          identity(:title, [:title])
        end

        attributes do
          uuid_primary_key(:id)
          attribute(:title, :string)
        end
      end

      defdomain([Post])

      AshSqlite.MigrationGenerator.generate(Domain,
        snapshot_path: snapshot_path,
        migration_path: migration_path,
        quiet: true,
        format: false,
        auto_name: true,
        dev: true
      )

      assert [_] = Path.wildcard("#{migration_path}/**/*_migrate_resources*.exs")
    end
  end

  describe "creating follow up migrations" do
    setup %{snapshot_path: snapshot_path, migration_path: migration_path} do
      defposts do
        identities do
          identity(:title, [:title])
        end

        attributes do
          uuid_primary_key(:id)
          attribute(:title, :string)
        end
      end

      defdomain([Post])

      AshSqlite.MigrationGenerator.generate(Domain,
        snapshot_path: snapshot_path,
        migration_path: migration_path,
        quiet: true,
        format: false,
        auto_name: true
      )

      :ok
    end

    test "without change", %{snapshot_path: snapshot_path, migration_path: migration_path} do
      defposts do
        identities do
          identity(:title, [:title])
        end

        attributes do
          uuid_primary_key(:id)
          attribute(:title, :string)
        end
      end

      defdomain([Post])

      AshSqlite.MigrationGenerator.generate(Domain,
        snapshot_path: snapshot_path,
        migration_path: migration_path,
        quiet: true,
        format: false,
        auto_name: true
      )

      assert [_] = Path.wildcard("#{migration_path}/**/*_migrate_resources*.exs")
    end

    test "when renaming an index, it is properly renamed with drop + recreate", %{
      snapshot_path: snapshot_path,
      migration_path: migration_path
    } do
      defposts do
        sqlite do
          identity_index_names(title: "titles_r_unique_dawg")
        end

        identities do
          identity(:title, [:title])
        end

        attributes do
          uuid_primary_key(:id)
          attribute(:title, :string)
        end
      end

      defdomain([Post])

      AshSqlite.MigrationGenerator.generate(Domain,
        snapshot_path: snapshot_path,
        migration_path: migration_path,
        quiet: true,
        format: false,
        auto_name: true
      )

      assert [_file1, file2] =
               Enum.sort(Path.wildcard("#{migration_path}/**/*_migrate_resources*.exs"))

      file_contents = File.read!(file2)

      # Should use drop + recreate instead of ALTER INDEX (which is PostgreSQL-only)
      assert file_contents =~
               ~S|drop_if_exists unique_index(:posts, [:title], name: "posts_title_index")|

      assert file_contents =~
               ~S|create unique_index(:posts, [:title], name: "titles_r_unique_dawg")|

      refute file_contents =~ "ALTER INDEX"
    end

    test "when adding a field, it adds the field", %{
      snapshot_path: snapshot_path,
      migration_path: migration_path
    } do
      defposts do
        identities do
          identity(:title, [:title])
        end

        attributes do
          uuid_primary_key(:id)
          attribute(:title, :string)
          attribute(:name, :string, allow_nil?: false)
        end
      end

      defdomain([Post])

      AshSqlite.MigrationGenerator.generate(Domain,
        snapshot_path: snapshot_path,
        migration_path: migration_path,
        quiet: true,
        format: false,
        auto_name: true
      )

      assert [_file1, file2] =
               Enum.sort(Path.wildcard("#{migration_path}/**/*_migrate_resources*.exs"))

      assert File.read!(file2) =~
               ~S[add :name, :text, null: false]
    end

    test "when renaming a field, it asks if you are renaming it, and renames it if you are", %{
      snapshot_path: snapshot_path,
      migration_path: migration_path
    } do
      defposts do
        attributes do
          uuid_primary_key(:id)
          attribute(:name, :string, allow_nil?: false)
        end
      end

      defdomain([Post])

      send(self(), {:mix_shell_input, :yes?, true})

      AshSqlite.MigrationGenerator.generate(Domain,
        snapshot_path: snapshot_path,
        migration_path: migration_path,
        quiet: true,
        format: false,
        auto_name: true
      )

      assert [_file1, file2] =
               Enum.sort(Path.wildcard("#{migration_path}/**/*_migrate_resources*.exs"))

      assert File.read!(file2) =~ ~S[rename table(:posts), :title, to: :name]
    end

    test "when renaming a field, it asks if you are renaming it, and generates a rebuild if you aren't (column in index)",
         %{
           snapshot_path: snapshot_path,
           migration_path: migration_path
         } do
      defposts do
        attributes do
          uuid_primary_key(:id)
          attribute(:name, :string, allow_nil?: false)
        end
      end

      defdomain([Post])

      send(self(), {:mix_shell_input, :yes?, false})

      AshSqlite.MigrationGenerator.generate(Domain,
        snapshot_path: snapshot_path,
        migration_path: migration_path,
        quiet: true,
        format: false,
        auto_name: true
      )

      assert [_file1, file2] =
               Enum.sort(Path.wildcard("#{migration_path}/**/*_migrate_resources*.exs"))

      file_contents = File.read!(file2)

      # Removing :title (which is in a unique index) triggers a table rebuild
      assert file_contents =~ ~S[PRAGMA foreign_keys = OFF]
      assert file_contents =~ ~S[CREATE TABLE]
      assert file_contents =~ ~S[posts_migration_temp]
      assert file_contents =~ ~S[PRAGMA foreign_keys = ON]
    end

    test "when renaming a field, it asks which field you are renaming it to, and renames it if you are",
         %{snapshot_path: snapshot_path, migration_path: migration_path} do
      defposts do
        attributes do
          uuid_primary_key(:id)
          attribute(:name, :string, allow_nil?: false)
          attribute(:subject, :string, allow_nil?: false)
        end
      end

      defdomain([Post])

      send(self(), {:mix_shell_input, :yes?, true})
      send(self(), {:mix_shell_input, :prompt, "subject"})

      AshSqlite.MigrationGenerator.generate(Domain,
        snapshot_path: snapshot_path,
        migration_path: migration_path,
        quiet: true,
        format: false,
        auto_name: true
      )

      assert [_file1, file2] =
               Enum.sort(Path.wildcard("#{migration_path}/**/*_migrate_resources*.exs"))

      # Up migration
      assert File.read!(file2) =~ ~S[rename table(:posts), :title, to: :subject]

      # Down migration
      assert File.read!(file2) =~ ~S[rename table(:posts), :subject, to: :title]
    end

    test "when renaming a field, it asks which field you are renaming it to, and generates rebuild if you arent (column in index)",
         %{snapshot_path: snapshot_path, migration_path: migration_path} do
      defposts do
        attributes do
          uuid_primary_key(:id)
          attribute(:name, :string, allow_nil?: false)
          attribute(:subject, :string, allow_nil?: false)
        end
      end

      defdomain([Post])

      send(self(), {:mix_shell_input, :yes?, false})

      AshSqlite.MigrationGenerator.generate(Domain,
        snapshot_path: snapshot_path,
        migration_path: migration_path,
        quiet: true,
        format: false,
        auto_name: true
      )

      assert [_file1, file2] =
               Enum.sort(Path.wildcard("#{migration_path}/**/*_migrate_resources*.exs"))

      file_contents = File.read!(file2)

      # Removing :title (which is in a unique index) triggers a table rebuild
      assert file_contents =~ ~S[PRAGMA foreign_keys = OFF]
      assert file_contents =~ ~S[CREATE TABLE]
      assert file_contents =~ ~S[posts_migration_temp]
      assert file_contents =~ ~S[PRAGMA foreign_keys = ON]
    end

    test "when an attribute exists only on some of the resources that use the same table, it isn't marked as null: false",
         %{snapshot_path: snapshot_path, migration_path: migration_path} do
      defposts do
        attributes do
          uuid_primary_key(:id)
          attribute(:title, :string)
          attribute(:example, :string, allow_nil?: false)
        end
      end

      defposts Post2 do
        attributes do
          uuid_primary_key(:id)
        end
      end

      defdomain([Post, Post2])

      AshSqlite.MigrationGenerator.generate(Domain,
        snapshot_path: snapshot_path,
        migration_path: migration_path,
        quiet: true,
        format: false,
        auto_name: true
      )

      assert [_file1, file2] =
               Enum.sort(Path.wildcard("#{migration_path}/**/*_migrate_resources*.exs"))

      assert File.read!(file2) =~
               ~S[add :example, :text] <> "\n"

      refute File.read!(file2) =~ ~S[null: false]
    end
  end

  describe "auto incrementing integer, when generated" do
    setup %{snapshot_path: snapshot_path, migration_path: migration_path} do
      defposts do
        attributes do
          attribute(:id, :integer, generated?: true, allow_nil?: false, primary_key?: true)
          attribute(:views, :integer)
        end
      end

      defdomain([Post])

      AshSqlite.MigrationGenerator.generate(Domain,
        snapshot_path: snapshot_path,
        migration_path: migration_path,
        quiet: true,
        format: false,
        auto_name: true
      )

      :ok
    end

    test "when an integer is generated and default nil, it is a bigserial", %{
      migration_path: migration_path
    } do
      assert [file] = Path.wildcard("#{migration_path}/**/*_migrate_resources*.exs")

      assert File.read!(file) =~
               ~S[add :id, :bigserial, null: false, primary_key: true]

      assert File.read!(file) =~
               ~S[add :views, :bigint]
    end
  end

  describe "--check option" do
    setup do
      defposts do
        attributes do
          uuid_primary_key(:id)
          attribute(:title, :string)
        end
      end

      defdomain([Post])

      [domain: Domain]
    end

    test "raises an error on pending codegen", %{
      domain: domain,
      snapshot_path: snapshot_path,
      migration_path: migration_path
    } do
      assert_raise Ash.Error.Framework.PendingCodegen, fn ->
        AshSqlite.MigrationGenerator.generate(domain,
          snapshot_path: snapshot_path,
          migration_path: migration_path,
          check: true,
          auto_name: true
        )
      end

      refute File.exists?(Path.wildcard("#{migration_path}/**/*_migrate_resources*.exs"))
      refute File.exists?(Path.wildcard("#{snapshot_path}/test_repo/posts/*.json"))
    end
  end

  describe "references" do
    setup do: :ok

    test "references are inferred automatically", %{
      snapshot_path: snapshot_path,
      migration_path: migration_path
    } do
      defposts do
        attributes do
          uuid_primary_key(:id)
          attribute(:title, :string)
          attribute(:foobar, :string)
        end
      end

      defposts Post2 do
        attributes do
          uuid_primary_key(:id)
          attribute(:name, :string)
        end

        relationships do
          belongs_to(:post, Post)
        end
      end

      defdomain([Post, Post2])

      AshSqlite.MigrationGenerator.generate(Domain,
        snapshot_path: snapshot_path,
        migration_path: migration_path,
        quiet: true,
        format: false,
        auto_name: true
      )

      assert [file] = Path.wildcard("#{migration_path}/**/*_migrate_resources*.exs")

      assert File.read!(file) =~
               ~S[references(:posts, column: :id, name: "posts_post_id_fkey", type: :uuid)]
    end

    test "references are inferred automatically if the attribute has a different type", %{
      snapshot_path: snapshot_path,
      migration_path: migration_path
    } do
      defposts do
        attributes do
          attribute(:id, :string, primary_key?: true, allow_nil?: false)
          attribute(:title, :string)
          attribute(:foobar, :string)
        end
      end

      defposts Post2 do
        attributes do
          attribute(:id, :string, primary_key?: true, allow_nil?: false)
          attribute(:name, :string)
        end

        relationships do
          belongs_to(:post, Post, attribute_type: :string)
        end
      end

      defdomain([Post, Post2])

      AshSqlite.MigrationGenerator.generate(Domain,
        snapshot_path: snapshot_path,
        migration_path: migration_path,
        quiet: true,
        format: false,
        auto_name: true
      )

      assert [file] = Path.wildcard("#{migration_path}/**/*_migrate_resources*.exs")

      assert File.read!(file) =~
               ~S[references(:posts, column: :id, name: "posts_post_id_fkey", type: :text)]
    end

    test "modifying a foreign key generates a table rebuild migration", %{
      snapshot_path: snapshot_path,
      migration_path: migration_path
    } do
      defposts do
        attributes do
          uuid_primary_key(:id)
          attribute(:title, :string)
          attribute(:foobar, :string)
        end
      end

      defposts Post2 do
        attributes do
          uuid_primary_key(:id)
          attribute(:name, :string)
        end

        relationships do
          belongs_to(:post, Post)
        end
      end

      defdomain([Post, Post2])

      AshSqlite.MigrationGenerator.generate(Domain,
        snapshot_path: snapshot_path,
        migration_path: migration_path,
        quiet: true,
        format: false,
        auto_name: true
      )

      defposts Post2 do
        sqlite do
          references do
            reference(:post, name: "special_post_fkey", on_delete: :delete, on_update: :update)
          end
        end

        attributes do
          uuid_primary_key(:id)
          attribute(:name, :string)
        end

        relationships do
          belongs_to(:post, Post)
        end
      end

      AshSqlite.MigrationGenerator.generate(Domain,
        snapshot_path: snapshot_path,
        migration_path: migration_path,
        quiet: true,
        format: false,
        auto_name: true
      )

      assert file =
               "#{migration_path}/**/*_migrate_resources*.exs"
               |> Path.wildcard()
               |> Enum.sort()
               |> Enum.at(1)
               |> File.read!()

      # Should generate a table rebuild instead of raising
      assert file =~ ~S[PRAGMA foreign_keys = OFF]
      assert file =~ ~S[CREATE TABLE]
      assert file =~ ~S[posts_migration_temp]
      assert file =~ ~S[DROP TABLE]
      assert file =~ ~S[RENAME TO]
      assert file =~ ~S[PRAGMA foreign_keys = ON]

      # Should NOT contain the old raise message
      refute file =~ ~S[raise "SQLite does not support dropping foreign key constraints.]

      # Both up and down should contain rebuild sequences
      assert [_, down_code] = String.split(file, "def down do")
      assert down_code =~ ~S[PRAGMA foreign_keys = OFF]
      assert down_code =~ ~S[PRAGMA foreign_keys = ON]
    end

    test "modifying a foreign key constraint generates a table rebuild", %{
      snapshot_path: snapshot_path,
      migration_path: migration_path
    } do
      defposts do
        attributes do
          uuid_primary_key(:id)
          attribute(:title, :string)
        end
      end

      defposts Post2 do
        attributes do
          uuid_primary_key(:id)
          attribute(:name, :string)
        end

        relationships do
          belongs_to(:post, Post)
        end
      end

      defdomain([Post, Post2])

      AshSqlite.MigrationGenerator.generate(Domain,
        snapshot_path: snapshot_path,
        migration_path: migration_path,
        quiet: true,
        format: false,
        auto_name: true
      )

      # Modify the reference to trigger constraint modification
      defposts Post2 do
        sqlite do
          references do
            reference(:post, name: "new_post_fkey", on_delete: :delete)
          end
        end

        attributes do
          uuid_primary_key(:id)
          attribute(:name, :string)
        end

        relationships do
          belongs_to(:post, Post)
        end
      end

      AshSqlite.MigrationGenerator.generate(Domain,
        snapshot_path: snapshot_path,
        migration_path: migration_path,
        quiet: true,
        format: false,
        auto_name: true
      )

      assert [_file1, file2] =
               Enum.sort(Path.wildcard("#{migration_path}/**/*_migrate_resources*.exs"))

      file_contents = File.read!(file2)

      # Up migration should generate a table rebuild
      assert file_contents =~ ~S[PRAGMA foreign_keys = OFF]
      assert file_contents =~ ~S[CREATE TABLE]
      assert file_contents =~ ~S[posts_migration_temp]
      assert file_contents =~ ~S[INSERT INTO]
      assert file_contents =~ ~S[DROP TABLE]
      assert file_contents =~ ~S[RENAME TO]
      assert file_contents =~ ~S[PRAGMA foreign_keys = ON]

      # Should NOT contain the old raise message
      refute file_contents =~ ~S[raise "SQLite does not support dropping foreign key constraints.]

      # Down migration should also contain rebuild
      [_, down_code] = String.split(file_contents, "def down do")
      assert down_code =~ ~S[PRAGMA foreign_keys = OFF]
      assert down_code =~ ~S[CREATE TABLE]
      assert down_code =~ ~S[PRAGMA foreign_keys = ON]
    end
  end

  describe "polymorphic resources" do
    setup %{snapshot_path: snapshot_path, migration_path: migration_path} do
      defmodule Comment do
        use Ash.Resource,
          domain: nil,
          data_layer: AshSqlite.DataLayer

        sqlite do
          polymorphic?(true)
          repo(AshSqlite.TestRepo)
        end

        attributes do
          uuid_primary_key(:id)
          attribute(:resource_id, :uuid)
        end

        actions do
          defaults([:create, :read, :update, :destroy])
        end
      end

      defmodule Post do
        use Ash.Resource,
          domain: nil,
          data_layer: AshSqlite.DataLayer

        sqlite do
          table "posts"
          repo(AshSqlite.TestRepo)
        end

        actions do
          defaults([:create, :read, :update, :destroy])
        end

        attributes do
          uuid_primary_key(:id)
        end

        relationships do
          has_many(:comments, Comment,
            destination_attribute: :resource_id,
            relationship_context: %{data_layer: %{table: "post_comments"}}
          )

          belongs_to(:best_comment, Comment,
            destination_attribute: :id,
            relationship_context: %{data_layer: %{table: "post_comments"}}
          )
        end
      end

      defdomain([Post, Comment])

      AshSqlite.MigrationGenerator.generate(Domain,
        snapshot_path: snapshot_path,
        migration_path: migration_path,
        quiet: true,
        format: false,
        auto_name: true
      )

      [domain: Domain]
    end

    test "it uses the relationship's table context if it is set", %{
      migration_path: migration_path
    } do
      assert [file] = Path.wildcard("#{migration_path}/**/*_migrate_resources*.exs")

      assert File.read!(file) =~
               ~S[references(:post_comments, column: :id, name: "posts_best_comment_id_fkey", type: :uuid)]
    end
  end

  describe "default values" do
    setup do: :ok

    test "when default value is specified that has no impl", %{
      snapshot_path: snapshot_path,
      migration_path: migration_path
    } do
      defposts do
        attributes do
          uuid_primary_key(:id)
          attribute(:product_code, :term, default: {"xyz"})
        end
      end

      defdomain([Post])

      capture_log(fn ->
        AshSqlite.MigrationGenerator.generate(Domain,
          snapshot_path: snapshot_path,
          migration_path: migration_path,
          quiet: true,
          format: false,
          auto_name: true
        )
      end)

      assert [file1] = Enum.sort(Path.wildcard("#{migration_path}/**/*_migrate_resources*.exs"))

      file = File.read!(file1)

      assert file =~
               ~S[add :product_code, :binary]
    end
  end

  describe "follow up with references" do
    setup %{snapshot_path: snapshot_path, migration_path: migration_path} do
      defposts do
        attributes do
          uuid_primary_key(:id)
          attribute(:title, :string)
        end
      end

      defmodule Comment do
        use Ash.Resource,
          domain: nil,
          data_layer: AshSqlite.DataLayer

        sqlite do
          table "comments"
          repo AshSqlite.TestRepo
        end

        attributes do
          uuid_primary_key(:id)
        end

        relationships do
          belongs_to(:post, Post)
        end
      end

      defdomain([Post, Comment])

      AshSqlite.MigrationGenerator.generate(Domain,
        snapshot_path: snapshot_path,
        migration_path: migration_path,
        quiet: true,
        format: false,
        auto_name: true
      )

      :ok
    end

    test "when changing the primary key, it generates a table rebuild", %{
      snapshot_path: snapshot_path,
      migration_path: migration_path
    } do
      defposts do
        attributes do
          attribute(:id, :uuid, primary_key?: false, default: &Ecto.UUID.generate/0)
          uuid_primary_key(:guid)
          attribute(:title, :string)
        end
      end

      defmodule Comment do
        use Ash.Resource,
          domain: nil,
          data_layer: AshSqlite.DataLayer

        sqlite do
          table "comments"
          repo AshSqlite.TestRepo
        end

        attributes do
          uuid_primary_key(:id)
        end

        relationships do
          belongs_to(:post, Post)
        end
      end

      defdomain([Post, Comment])

      AshSqlite.MigrationGenerator.generate(Domain,
        snapshot_path: snapshot_path,
        migration_path: migration_path,
        quiet: true,
        format: false,
        auto_name: true
      )

      assert [_file1, file2] =
               Enum.sort(Path.wildcard("#{migration_path}/**/*_migrate_resources*.exs"))

      file = File.read!(file2)

      # FK changes now trigger a table rebuild instead of raising
      assert file =~ ~S[PRAGMA foreign_keys = OFF]
      assert file =~ ~S[CREATE TABLE]
      assert file =~ ~S[comments_migration_temp]
      assert file =~ ~S[DROP TABLE]
      assert file =~ ~S[RENAME TO]
      assert file =~ ~S[PRAGMA foreign_keys = ON]

      # Should NOT contain the old raise message
      refute file =~ ~S[raise "SQLite does not support dropping foreign key constraints.]
    end
  end

  describe "renaming multiple relationships" do
    setup %{snapshot_path: snapshot_path, migration_path: migration_path} do
      defposts do
        attributes do
          uuid_primary_key(:id)
        end

        relationships do
          belongs_to(:creator, AshSqlite.Test.User)
          belongs_to(:contributer, AshSqlite.Test.User)
        end
      end

      defdomain([Post, AshSqlite.Test.User])

      AshSqlite.MigrationGenerator.generate(Domain,
        snapshot_path: snapshot_path,
        migration_path: migration_path,
        quiet: true,
        format: false,
        auto_name: true
      )

      :ok
    end

    test "renames columns without adding duplicate columns", %{
      snapshot_path: snapshot_path,
      migration_path: migration_path
    } do
      defposts do
        attributes do
          uuid_primary_key(:id)
        end

        relationships do
          belongs_to(:creator2, AshSqlite.Test.User)
          belongs_to(:contributer2, AshSqlite.Test.User)
        end
      end

      defdomain([Post, AshSqlite.Test.User])

      send(self(), {:mix_shell_input, :yes?, true})
      send(self(), {:mix_shell_input, :prompt, "creator2_id"})
      send(self(), {:mix_shell_input, :yes?, true})

      AshSqlite.MigrationGenerator.generate(Domain,
        snapshot_path: snapshot_path,
        migration_path: migration_path,
        quiet: true,
        format: false,
        auto_name: true
      )

      assert [_file1, file2] =
               Enum.sort(Path.wildcard("#{migration_path}/**/*_migrate_resources*.exs"))

      # Up migration
      assert File.read!(file2) =~ ~S[rename table(:posts), :creator_id, to: :creator2_id]
      assert File.read!(file2) =~ ~S[rename table(:posts), :contributer_id, to: :contributer2_id]

      refute File.read!(file2) =~ ~S[alter table(:posts)]

      # Down migration
      assert File.read!(file2) =~ ~S[rename table(:posts), :creator2_id, to: :creator_id]
      assert File.read!(file2) =~ ~S[rename table(:posts), :contributer2_id, to: :contributer_id]
    end
  end

  describe "table rebuild migrations" do
    setup do: :ok

    test "type change on a column generates a table rebuild", %{
      snapshot_path: snapshot_path,
      migration_path: migration_path
    } do
      defposts do
        attributes do
          uuid_primary_key(:id)
          attribute(:title, :string)
        end
      end

      defdomain([Post])

      AshSqlite.MigrationGenerator.generate(Domain,
        snapshot_path: snapshot_path,
        migration_path: migration_path,
        quiet: true,
        format: false,
        auto_name: true
      )

      defposts do
        sqlite do
          migration_types(title: :binary)
        end

        attributes do
          uuid_primary_key(:id)
          attribute(:title, :string)
        end
      end

      defdomain([Post])

      AshSqlite.MigrationGenerator.generate(Domain,
        snapshot_path: snapshot_path,
        migration_path: migration_path,
        quiet: true,
        format: false,
        auto_name: true
      )

      assert [_file1, file2] =
               Enum.sort(Path.wildcard("#{migration_path}/**/*_migrate_resources*.exs"))

      file_contents = File.read!(file2)

      # Up migration should contain rebuild sequence
      assert file_contents =~ ~S[PRAGMA foreign_keys = OFF]
      assert file_contents =~ "CREATE TABLE"
      assert file_contents =~ "posts_migration_temp"
      assert file_contents =~ "INSERT INTO"
      assert file_contents =~ ~S[DROP TABLE "posts"]
      assert file_contents =~ ~S[RENAME TO "posts"]
      assert file_contents =~ ~S[PRAGMA foreign_keys = ON]

      # Down should also contain rebuild
      [_, down_code] = String.split(file_contents, "def down do")
      assert down_code =~ ~S[PRAGMA foreign_keys = OFF]
      assert down_code =~ "CREATE TABLE"
      assert down_code =~ ~S[PRAGMA foreign_keys = ON]
    end

    test "nullability change generates a table rebuild", %{
      snapshot_path: snapshot_path,
      migration_path: migration_path
    } do
      defposts do
        attributes do
          uuid_primary_key(:id)
          attribute(:title, :string, allow_nil?: true)
        end
      end

      defdomain([Post])

      AshSqlite.MigrationGenerator.generate(Domain,
        snapshot_path: snapshot_path,
        migration_path: migration_path,
        quiet: true,
        format: false,
        auto_name: true
      )

      defposts do
        attributes do
          uuid_primary_key(:id)
          attribute(:title, :string, allow_nil?: false)
        end
      end

      defdomain([Post])

      AshSqlite.MigrationGenerator.generate(Domain,
        snapshot_path: snapshot_path,
        migration_path: migration_path,
        quiet: true,
        format: false,
        auto_name: true
      )

      assert [_file1, file2] =
               Enum.sort(Path.wildcard("#{migration_path}/**/*_migrate_resources*.exs"))

      file_contents = File.read!(file2)

      assert file_contents =~ ~S[PRAGMA foreign_keys = OFF]
      assert file_contents =~ "CREATE TABLE"
      assert file_contents =~ "posts_migration_temp"
      assert file_contents =~ ~S[PRAGMA foreign_keys = ON]

      # Down should also contain rebuild
      [_, down_code] = String.split(file_contents, "def down do")
      assert down_code =~ ~S[PRAGMA foreign_keys = OFF]
      assert down_code =~ ~S[PRAGMA foreign_keys = ON]
    end

    test "adding a column without other changes does NOT generate a rebuild", %{
      snapshot_path: snapshot_path,
      migration_path: migration_path
    } do
      defposts do
        attributes do
          uuid_primary_key(:id)
          attribute(:title, :string)
        end
      end

      defdomain([Post])

      AshSqlite.MigrationGenerator.generate(Domain,
        snapshot_path: snapshot_path,
        migration_path: migration_path,
        quiet: true,
        format: false,
        auto_name: true
      )

      defposts do
        attributes do
          uuid_primary_key(:id)
          attribute(:title, :string)
          attribute(:body, :string)
        end
      end

      defdomain([Post])

      AshSqlite.MigrationGenerator.generate(Domain,
        snapshot_path: snapshot_path,
        migration_path: migration_path,
        quiet: true,
        format: false,
        auto_name: true
      )

      assert [_file1, file2] =
               Enum.sort(Path.wildcard("#{migration_path}/**/*_migrate_resources*.exs"))

      file_contents = File.read!(file2)

      # Should use standard alter table, not rebuild
      assert file_contents =~ "alter table(:posts)"
      assert file_contents =~ "add :body, :text"
      refute file_contents =~ "PRAGMA foreign_keys"
      refute file_contents =~ "posts_migration_temp"
    end

    test "removing a column with no FK and no index uses simple remove", %{
      snapshot_path: snapshot_path,
      migration_path: migration_path
    } do
      defposts do
        identities do
          identity(:title, [:title])
        end

        attributes do
          uuid_primary_key(:id)
          attribute(:title, :string)
          attribute(:body, :string)
        end
      end

      defdomain([Post])

      AshSqlite.MigrationGenerator.generate(Domain,
        snapshot_path: snapshot_path,
        migration_path: migration_path,
        quiet: true,
        format: false,
        auto_name: true
      )

      defposts do
        identities do
          identity(:title, [:title])
        end

        attributes do
          uuid_primary_key(:id)
          attribute(:title, :string)
        end
      end

      defdomain([Post])

      AshSqlite.MigrationGenerator.generate(Domain,
        snapshot_path: snapshot_path,
        migration_path: migration_path,
        quiet: true,
        format: false,
        auto_name: true
      )

      assert [_file1, file2] =
               Enum.sort(Path.wildcard("#{migration_path}/**/*_migrate_resources*.exs"))

      file_contents = File.read!(file2)

      # Should use simple remove (no FK, not in any index)
      assert file_contents =~ "remove :body"
      refute file_contents =~ "PRAGMA foreign_keys"
      refute file_contents =~ "posts_migration_temp"
    end

    test "removing a column that appears in a unique index generates a table rebuild", %{
      snapshot_path: snapshot_path,
      migration_path: migration_path
    } do
      defposts do
        identities do
          identity(:title, [:title])
        end

        attributes do
          uuid_primary_key(:id)
          attribute(:title, :string)
        end
      end

      defdomain([Post])

      AshSqlite.MigrationGenerator.generate(Domain,
        snapshot_path: snapshot_path,
        migration_path: migration_path,
        quiet: true,
        format: false,
        auto_name: true
      )

      defposts do
        attributes do
          uuid_primary_key(:id)
        end
      end

      defdomain([Post])

      send(self(), {:mix_shell_input, :yes?, false})

      AshSqlite.MigrationGenerator.generate(Domain,
        snapshot_path: snapshot_path,
        migration_path: migration_path,
        quiet: true,
        format: false,
        auto_name: true
      )

      assert [_file1, file2] =
               Enum.sort(Path.wildcard("#{migration_path}/**/*_migrate_resources*.exs"))

      file_contents = File.read!(file2)

      # Should generate a rebuild since :title is in a unique index
      assert file_contents =~ ~S[PRAGMA foreign_keys = OFF]
      assert file_contents =~ "CREATE TABLE"
      assert file_contents =~ "posts_migration_temp"
      assert file_contents =~ ~S[PRAGMA foreign_keys = ON]
    end

    test "RenameUniqueIndex generates drop + recreate, not ALTER INDEX", %{
      snapshot_path: snapshot_path,
      migration_path: migration_path
    } do
      defposts do
        sqlite do
          identity_index_names(title: "posts_foo_index")
        end

        identities do
          identity(:title, [:title])
        end

        attributes do
          uuid_primary_key(:id)
          attribute(:title, :string)
        end
      end

      defdomain([Post])

      AshSqlite.MigrationGenerator.generate(Domain,
        snapshot_path: snapshot_path,
        migration_path: migration_path,
        quiet: true,
        format: false,
        auto_name: true
      )

      defposts do
        sqlite do
          identity_index_names(title: "posts_bar_index")
        end

        identities do
          identity(:title, [:title])
        end

        attributes do
          uuid_primary_key(:id)
          attribute(:title, :string)
        end
      end

      defdomain([Post])

      AshSqlite.MigrationGenerator.generate(Domain,
        snapshot_path: snapshot_path,
        migration_path: migration_path,
        quiet: true,
        format: false,
        auto_name: true
      )

      assert [_file1, file2] =
               Enum.sort(Path.wildcard("#{migration_path}/**/*_migrate_resources*.exs"))

      file_contents = File.read!(file2)

      assert file_contents =~ ~S|drop_if_exists unique_index(:posts|
      assert file_contents =~ ~S|posts_foo_index|
      assert file_contents =~ ~S|create unique_index(:posts|
      assert file_contents =~ ~S|posts_bar_index|
      refute file_contents =~ "ALTER INDEX"
    end

    test "table rebuild recreates all indexes", %{
      snapshot_path: snapshot_path,
      migration_path: migration_path
    } do
      defposts do
        identities do
          identity(:title, [:title])
        end

        attributes do
          uuid_primary_key(:id)
          attribute(:title, :string, allow_nil?: true)
        end
      end

      defdomain([Post])

      AshSqlite.MigrationGenerator.generate(Domain,
        snapshot_path: snapshot_path,
        migration_path: migration_path,
        quiet: true,
        format: false,
        auto_name: true
      )

      # Change nullability to trigger rebuild
      defposts do
        identities do
          identity(:title, [:title])
        end

        attributes do
          uuid_primary_key(:id)
          attribute(:title, :string, allow_nil?: false)
        end
      end

      defdomain([Post])

      AshSqlite.MigrationGenerator.generate(Domain,
        snapshot_path: snapshot_path,
        migration_path: migration_path,
        quiet: true,
        format: false,
        auto_name: true
      )

      assert [_file1, file2] =
               Enum.sort(Path.wildcard("#{migration_path}/**/*_migrate_resources*.exs"))

      file_contents = File.read!(file2)

      # Should contain rebuild
      assert file_contents =~ ~S[PRAGMA foreign_keys = OFF]

      # Should recreate unique indexes after the rebuild
      assert file_contents =~ ~S|CREATE UNIQUE INDEX "posts_title_index"|

      # Should recreate custom indexes after the rebuild
      assert file_contents =~ ~S|CREATE INDEX "posts_id_index"|
      assert file_contents =~ ~S|CREATE UNIQUE INDEX "test_unique_index"|
    end

    test "removing a column that has a FK generates a table rebuild", %{
      snapshot_path: snapshot_path,
      migration_path: migration_path
    } do
      defposts do
        attributes do
          uuid_primary_key(:id)
          attribute(:title, :string)
        end
      end

      defposts Post2 do
        attributes do
          uuid_primary_key(:id)
          attribute(:name, :string)
        end

        relationships do
          belongs_to(:post, Post)
        end
      end

      defdomain([Post, Post2])

      AshSqlite.MigrationGenerator.generate(Domain,
        snapshot_path: snapshot_path,
        migration_path: migration_path,
        quiet: true,
        format: false,
        auto_name: true
      )

      # Remove the belongs_to relationship (which removes the FK column)
      defposts Post2 do
        attributes do
          uuid_primary_key(:id)
          attribute(:name, :string)
        end
      end

      defdomain([Post, Post2])

      send(self(), {:mix_shell_input, :yes?, false})

      AshSqlite.MigrationGenerator.generate(Domain,
        snapshot_path: snapshot_path,
        migration_path: migration_path,
        quiet: true,
        format: false,
        auto_name: true
      )

      assert [_file1, file2] =
               Enum.sort(Path.wildcard("#{migration_path}/**/*_migrate_resources*.exs"))

      file_contents = File.read!(file2)

      # Removing a column with a FK should trigger rebuild
      assert file_contents =~ ~S[PRAGMA foreign_keys = OFF]
      assert file_contents =~ "CREATE TABLE"
      assert file_contents =~ "posts_migration_temp"
      assert file_contents =~ ~S[PRAGMA foreign_keys = ON]
    end

    test "rebuild with nullability change on column with default uses COALESCE", %{
      snapshot_path: snapshot_path,
      migration_path: migration_path
    } do
      defposts do
        sqlite do
          migration_defaults(title: "\"hey hey\"")
        end

        attributes do
          uuid_primary_key(:id)
          attribute(:title, :string, allow_nil?: true)
        end
      end

      defdomain([Post])

      AshSqlite.MigrationGenerator.generate(Domain,
        snapshot_path: snapshot_path,
        migration_path: migration_path,
        quiet: true,
        format: false,
        auto_name: true
      )

      # Change to NOT NULL — triggers rebuild, and existing NULLs need COALESCE
      defposts do
        sqlite do
          migration_defaults(title: "\"hey hey\"")
        end

        attributes do
          uuid_primary_key(:id)
          attribute(:title, :string, allow_nil?: false)
        end
      end

      defdomain([Post])

      AshSqlite.MigrationGenerator.generate(Domain,
        snapshot_path: snapshot_path,
        migration_path: migration_path,
        quiet: true,
        format: false,
        auto_name: true
      )

      assert [_file1, file2] =
               Enum.sort(Path.wildcard("#{migration_path}/**/*_migrate_resources*.exs"))

      file_contents = File.read!(file2)

      # Should generate a rebuild
      assert file_contents =~ ~S[PRAGMA foreign_keys = OFF]

      # The INSERT ... SELECT should use COALESCE for the nullable-to-not-null transition
      assert file_contents =~ "COALESCE"
      assert file_contents =~ "'hey hey'"
    end

    test "rebuild with new NOT NULL column with default includes default in SELECT", %{
      snapshot_path: snapshot_path,
      migration_path: migration_path
    } do
      defposts do
        attributes do
          uuid_primary_key(:id)
          attribute(:title, :string, allow_nil?: true)
        end
      end

      defdomain([Post])

      AshSqlite.MigrationGenerator.generate(Domain,
        snapshot_path: snapshot_path,
        migration_path: migration_path,
        quiet: true,
        format: false,
        auto_name: true
      )

      # Add a NOT NULL column with a default AND change nullability on title (triggers rebuild)
      defposts do
        sqlite do
          migration_defaults(thing: "\"hey hey\"")
        end

        attributes do
          uuid_primary_key(:id)
          attribute(:title, :string, allow_nil?: false)
          attribute(:thing, :string, allow_nil?: false)
        end
      end

      defdomain([Post])

      AshSqlite.MigrationGenerator.generate(Domain,
        snapshot_path: snapshot_path,
        migration_path: migration_path,
        quiet: true,
        format: false,
        auto_name: true
      )

      assert [_file1, file2] =
               Enum.sort(Path.wildcard("#{migration_path}/**/*_migrate_resources*.exs"))

      file_contents = File.read!(file2)

      # Should generate a rebuild
      assert file_contents =~ ~S[PRAGMA foreign_keys = OFF]

      # New column "thing" should appear in INSERT with its default value in SELECT
      assert file_contents =~ "thing"
      assert file_contents =~ "'hey hey'"
    end

    test "rebuild uses COALESCE with type zero value when no migration_default is configured", %{
      snapshot_path: snapshot_path,
      migration_path: migration_path
    } do
      defposts do
        attributes do
          uuid_primary_key(:id)
          attribute(:title, :string, allow_nil?: true)
          attribute(:thing, :string, allow_nil?: true)
        end
      end

      defdomain([Post])

      AshSqlite.MigrationGenerator.generate(Domain,
        snapshot_path: snapshot_path,
        migration_path: migration_path,
        quiet: true,
        format: false,
        auto_name: true
      )

      # Change "thing" to NOT NULL with a runtime-only default (no migration_defaults)
      defposts do
        attributes do
          uuid_primary_key(:id)
          attribute(:title, :string, allow_nil?: true)
          attribute(:thing, :string, allow_nil?: false)
        end
      end

      defdomain([Post])

      AshSqlite.MigrationGenerator.generate(Domain,
        snapshot_path: snapshot_path,
        migration_path: migration_path,
        quiet: true,
        format: false,
        auto_name: true
      )

      assert [_file1, file2] =
               Enum.sort(Path.wildcard("#{migration_path}/**/*_migrate_resources*.exs"))

      file_contents = File.read!(file2)

      # Should generate a rebuild (nullability change)
      assert file_contents =~ ~S[PRAGMA foreign_keys = OFF]

      # Should use COALESCE with a type-appropriate zero value for existing NULLs
      assert file_contents =~ "COALESCE"
      # text type zero value is ''
      assert file_contents =~ ~S|COALESCE(\"thing\", '')|
    end
  end
end
