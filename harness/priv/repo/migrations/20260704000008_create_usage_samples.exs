defmodule Harness.Repo.Migrations.CreateUsageSamples do
  use Ecto.Migration

  def change do
    create table(:usage_samples) do
      add :source, :string, null: false
      add :five_hour_utilization, :float
      add :five_hour_resets_at, :utc_datetime_usec
      add :seven_day_utilization, :float
      add :seven_day_resets_at, :utc_datetime_usec
      add :seven_day_opus_utilization, :float
      add :rate_limit_status, :string
      add :raw, :map, null: false
      add :sampled_at, :utc_datetime_usec, null: false

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create index(:usage_samples, [:sampled_at])
    create index(:usage_samples, [:source, :sampled_at])
  end
end
