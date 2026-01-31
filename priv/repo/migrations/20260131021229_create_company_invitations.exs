defmodule Aces.Repo.Migrations.CreateCompanyInvitations do
  use Ecto.Migration

  def change do
    create table(:company_invitations) do
      add :company_id, references(:companies, on_delete: :delete_all), null: false
      add :invited_by_id, references(:users, on_delete: :nilify_all)
      add :invited_email, :citext, null: false
      add :role, :string, null: false, default: "viewer"
      add :token, :binary, null: false
      add :status, :string, null: false, default: "pending"
      add :expires_at, :utc_datetime, null: false
      add :accepted_at, :utc_datetime

      timestamps()
    end

    create index(:company_invitations, [:company_id])
    create index(:company_invitations, [:invited_email])
    create index(:company_invitations, [:token])
    create index(:company_invitations, [:status])

    # Prevent duplicate pending invitations to the same email for the same company
    create unique_index(:company_invitations, [:company_id, :invited_email],
      where: "status = 'pending'",
      name: :company_invitations_pending_unique
    )
  end
end
