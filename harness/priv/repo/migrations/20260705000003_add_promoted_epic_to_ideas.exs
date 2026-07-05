defmodule Harness.Repo.Migrations.AddPromotedEpicToIdeas do
  use Ecto.Migration

  def change do
    alter table(:ideas) do
      add :promoted_epic_url, :string
      add :promoted_epic_number, :integer
    end
  end
end
