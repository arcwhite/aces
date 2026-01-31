defmodule Aces.Accounts.UserNotifier do
  import Swoosh.Email

  alias Aces.Mailer

  # Delivers the email using the application mailer.
  defp deliver(recipient, subject, body) do
    email =
      new()
      |> to(recipient)
      |> from({"Aces", "contact@example.com"})
      |> subject(subject)
      |> text_body(body)

    with {:ok, _metadata} <- Mailer.deliver(email) do
      {:ok, email}
    end
  end

  @doc """
  Deliver instructions to update a user email.
  """
  def deliver_update_email_instructions(user, url) do
    deliver(user.email, "Update email instructions", """

    ==============================

    Hi #{user.email},

    You can change your email by visiting the URL below:

    #{url}

    If you didn't request this change, please ignore this.

    ==============================
    """)
  end


  @doc """
  Deliver email confirmation instructions.
  """
  def deliver_confirmation_instructions(user, url) do
    deliver(user.email, "Confirmation instructions", """

    ==============================

    Hi #{user.email},

    You can confirm your account by visiting the URL below:

    #{url}

    If you didn't create an account with us, please ignore this.

    ==============================
    """)
  end

  @doc """
  Deliver instructions to reset a user password.
  """
  def deliver_reset_password_instructions(user, url) do
    deliver(user.email, "Reset password instructions", """

    ==============================

    Hi #{user.email},

    You can reset your password by visiting the URL below:

    #{url}

    If you didn't request this change, please ignore this.

    ==============================
    """)
  end

  @doc """
  Deliver a company invitation email.

  `invitation` should have `:company` and `:invited_by` preloaded.
  """
  def deliver_company_invitation(invited_email, invitation, url) do
    inviter_email = if invitation.invited_by, do: invitation.invited_by.email, else: "a user"
    company_name = invitation.company.name
    role = invitation.role

    deliver(invited_email, "You've been invited to join #{company_name}", """

    ==============================

    Hi there,

    #{inviter_email} has invited you to join the mercenary company "#{company_name}" as #{article_for_role(role)} #{role}.

    You can accept this invitation by visiting the URL below:

    #{url}

    This invitation will expire in #{Aces.Companies.CompanyInvitation.validity_in_days()} days.

    If you weren't expecting this invitation, you can safely ignore this email.

    ==============================
    """)
  end

  defp article_for_role("owner"), do: "an"
  defp article_for_role("editor"), do: "an"
  defp article_for_role("viewer"), do: "a"
  defp article_for_role(_), do: "a"
end
