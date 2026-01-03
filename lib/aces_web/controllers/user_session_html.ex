defmodule AcesWeb.UserSessionHTML do
  use AcesWeb, :html

  embed_templates "user_session_html/*"

  defp local_mail_adapter? do
    Application.get_env(:aces, Aces.Mailer)[:adapter] == Swoosh.Adapters.Local
  end
end
