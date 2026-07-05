defmodule Harness.Repo.Migrations.AddOperatorSteering do
  use Ecto.Migration

  def change do
    alter table(:ideation_sessions) do
      add :nudge, :text
      add :focus_node_id, references(:ideas, on_delete: :nilify_all)
    end
  end
end
