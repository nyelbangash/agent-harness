defmodule Harness.Repo.Migrations.CreateIdeationPromotions do
  use Ecto.Migration

  def change do
    create table(:ideation_promotions) do
      add :idea_id, references(:ideas, on_delete: :delete_all), null: false
      add :session_id, references(:ideation_sessions, on_delete: :delete_all), null: false
      add :run_id, references(:runs, on_delete: :nilify_all)
      add :target_repo, :string, null: false
      add :epic_number, :integer
      add :epic_url, :string
      add :status, :string, null: false, default: "running"
      add :error_detail, :string

      timestamps(type: :utc_datetime_usec)
    end

    create index(:ideation_promotions, [:idea_id])
    create index(:ideation_promotions, [:session_id])
  end
end
