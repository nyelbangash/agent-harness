defmodule Harness.Repo.Migrations.AddOperatorSteering do
  use Ecto.Migration

  def change do
    alter table(:ideation_sessions) do
      add :nudge, :text
      add :forced_node_id, :integer
    end
  end
end
