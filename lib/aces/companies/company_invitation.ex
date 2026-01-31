defmodule Aces.Companies.CompanyInvitation do
  @moduledoc """
  Schema for company invitations.

  Invitations allow company owners to invite users (existing or new) to join
  their company with a specific role. Invitations are sent via email and
  contain a unique token for verification.

  ## Token Security

  The token is hashed before storage using SHA256. The unhashed token is
  sent to the invitee's email. This means:
  - Database access alone cannot be used to accept invitations
  - Tokens are verified by hashing the provided token and comparing

  ## Invitation States

  - `pending` - Invitation sent, awaiting response
  - `accepted` - Invitee accepted and joined the company
  - `expired` - Invitation expired (default: 7 days)
  - `cancelled` - Owner cancelled the invitation
  """

  use Ecto.Schema
  import Ecto.Changeset
  import Ecto.Query

  @hash_algorithm :sha256
  @rand_size 32
  @invitation_validity_in_days 7
  @valid_statuses ~w(pending accepted expired cancelled)
  @valid_roles ~w(owner editor viewer)

  schema "company_invitations" do
    field :invited_email, :string
    field :role, :string, default: "viewer"
    field :token, :binary
    field :status, :string, default: "pending"
    field :expires_at, :utc_datetime
    field :accepted_at, :utc_datetime

    belongs_to :company, Aces.Companies.Company
    belongs_to :invited_by, Aces.Accounts.User, foreign_key: :invited_by_id

    timestamps()
  end

  @doc """
  Builds a new invitation with a hashed token.

  Returns `{encoded_token, %CompanyInvitation{}}` where the encoded_token
  should be sent to the invitee via email, and the struct contains the
  hashed token for database storage.
  """
  def build_invitation(company, invited_by, invited_email, role \\ "viewer") do
    token = :crypto.strong_rand_bytes(@rand_size)
    hashed_token = :crypto.hash(@hash_algorithm, token)
    expires_at = DateTime.utc_now() |> DateTime.add(@invitation_validity_in_days, :day) |> DateTime.truncate(:second)

    {Base.url_encode64(token, padding: false),
     %__MODULE__{
       company_id: company.id,
       invited_by_id: invited_by.id,
       invited_email: String.downcase(invited_email),
       role: role,
       token: hashed_token,
       status: "pending",
       expires_at: expires_at
     }}
  end

  @doc """
  Creates a changeset for a new invitation.
  Used for validation before inserting the struct built by `build_invitation/4`.
  """
  def changeset(invitation, attrs) do
    invitation
    |> cast(attrs, [:invited_email, :role, :status])
    |> validate_required([:invited_email, :role, :token, :company_id, :expires_at])
    |> validate_format(:invited_email, ~r/^[^\s]+@[^\s]+$/, message: "must be a valid email address")
    |> validate_inclusion(:role, @valid_roles)
    |> validate_inclusion(:status, @valid_statuses)
    |> unique_constraint(:invited_email,
      name: :company_invitations_pending_unique,
      message: "already has a pending invitation"
    )
  end

  @doc """
  Creates a changeset for inserting a pre-built invitation struct.
  This ensures proper constraint handling for unique index violations.
  """
  def insert_changeset(%__MODULE__{} = invitation) do
    invitation
    |> change()
    |> unique_constraint(:invited_email,
      name: :company_invitations_pending_unique,
      message: "already has a pending invitation"
    )
  end

  @doc """
  Creates a changeset for accepting an invitation.
  """
  def accept_changeset(invitation) do
    invitation
    |> change(%{
      status: "accepted",
      accepted_at: DateTime.utc_now() |> DateTime.truncate(:second)
    })
  end

  @doc """
  Creates a changeset for cancelling an invitation.
  """
  def cancel_changeset(invitation) do
    change(invitation, %{status: "cancelled"})
  end

  @doc """
  Verifies a token and returns a query to find the invitation.

  Returns `{:ok, query}` if token decodes correctly, `:error` otherwise.
  The query filters for pending, non-expired invitations.
  """
  def verify_invitation_token_query(token) do
    case Base.url_decode64(token, padding: false) do
      {:ok, decoded_token} ->
        hashed_token = :crypto.hash(@hash_algorithm, decoded_token)

        query =
          from i in __MODULE__,
            where: i.token == ^hashed_token,
            where: i.status == "pending",
            where: i.expires_at > ^DateTime.utc_now(),
            preload: [:company, :invited_by]

        {:ok, query}

      :error ->
        :error
    end
  end

  @doc """
  Returns a query for all pending invitations for a company.
  """
  def pending_for_company_query(company_id) do
    from i in __MODULE__,
      where: i.company_id == ^company_id,
      where: i.status == "pending",
      where: i.expires_at > ^DateTime.utc_now(),
      order_by: [desc: i.inserted_at],
      preload: [:invited_by]
  end

  @doc """
  Returns a query for all pending invitations for an email address.
  """
  def pending_for_email_query(email) do
    email = String.downcase(email)

    from i in __MODULE__,
      where: i.invited_email == ^email,
      where: i.status == "pending",
      where: i.expires_at > ^DateTime.utc_now(),
      order_by: [desc: i.inserted_at],
      preload: [:company, :invited_by]
  end

  @doc """
  Returns a query for all invitations (any status) for an email address.
  Useful for showing invitation history.
  """
  def all_for_email_query(email) do
    email = String.downcase(email)

    from i in __MODULE__,
      where: i.invited_email == ^email,
      order_by: [desc: i.inserted_at],
      preload: [:company, :invited_by]
  end

  @doc """
  Returns a query for all invitations sent by a user.
  Useful for showing sent invitation history.
  """
  def sent_by_user_query(user_id) do
    from i in __MODULE__,
      where: i.invited_by_id == ^user_id,
      order_by: [desc: i.inserted_at],
      preload: [:company]
  end

  @doc """
  Returns the invitation validity period in days.
  """
  def validity_in_days, do: @invitation_validity_in_days
end
