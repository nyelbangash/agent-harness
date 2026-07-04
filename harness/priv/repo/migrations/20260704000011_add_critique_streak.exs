defmodule Harness.Repo.Migrations.AddCritiqueStreak do
  use Ecto.Migration

  def change do
    alter table(:ideation_sessions) do
      # spec §5.2 stop condition counts consecutive CRITIQUES with no material
      # progress, separately from per-iteration bookkeeping
      add :critique_no_progress_streak, :integer, null: false, default: 0
    end
  end
end
