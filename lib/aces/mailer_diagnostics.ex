defmodule Aces.MailerDiagnostics do
  @moduledoc """
  Production-safe diagnostics for the email (SES SMTP) configuration.

  Intended to be run on a deployed release without Mix, e.g. on fly.io:

      fly ssh console -C "/app/bin/aces eval 'Aces.MailerDiagnostics.run(\\"you@example.com\\")'"

  or via the convenience launcher:

      fly ssh console -C "/app/bin/test-email you@example.com"

  It prints the resolved mailer configuration (with the password redacted),
  validates the required environment variables, attempts to actually send a
  test message through SES, and decodes the most common failure modes.
  """

  import Swoosh.Email

  alias Aces.Mailer

  @doc """
  Run the full email diagnostic, sending a test message to `recipient`.

  Returns `:ok` if the message was accepted by SES, `:error` otherwise.
  """
  def run(recipient) when is_binary(recipient) do
    # Bring up the full application so the mailer/gen_smtp deps are started.
    {:ok, _} = Application.ensure_all_started(:aces)

    line()
    IO.puts("Aces email diagnostics")
    line()

    print_env()
    print_config()

    from_email = Application.get_env(:aces, :mailer_from_email)
    from_name = Application.get_env(:aces, :mailer_from_name, "Aces")

    IO.puts("")
    IO.puts("Sending test email")
    IO.puts("  From: #{inspect(from_name)} <#{from_email}>")
    IO.puts("  To:   #{recipient}")
    IO.puts("")

    email =
      new()
      |> to(recipient)
      |> from({from_name, from_email})
      |> subject("Aces SES test #{timestamp()}")
      |> text_body("""
      This is a test message from the Aces mailer diagnostics.

      If you received this, SES SMTP delivery is working for this recipient.

      Sent at: #{timestamp()}
      """)

    case Mailer.deliver(email) do
      {:ok, metadata} ->
        IO.puts("RESULT: SES accepted the message ✅")
        IO.puts("  metadata: #{inspect(metadata)}")
        IO.puts("")
        IO.puts("Note: acceptance by SES is not proof of delivery to the inbox.")
        IO.puts("Check the recipient's inbox/spam, and the SES sending dashboard")
        IO.puts("for bounces/complaints if the message does not arrive.")
        line()
        :ok

      {:error, reason} ->
        IO.puts("RESULT: delivery FAILED ❌")
        IO.puts("  raw error: #{inspect(reason, pretty: true, limit: :infinity)}")
        IO.puts("")
        explain(reason)
        line()
        :error
    end
  end

  def run(_) do
    IO.puts("Usage: Aces.MailerDiagnostics.run(\"recipient@example.com\")")
    :error
  end

  # ---- reporting helpers ---------------------------------------------------

  defp print_env do
    region = System.get_env("AWS_REGION")
    username = System.get_env("SMTP_USERNAME")
    password = System.get_env("SMTP_PASSWORD")
    from = System.get_env("MAILER_FROM_EMAIL")

    IO.puts("Environment variables")
    IO.puts("  AWS_REGION:        #{present(region, default: "us-east-1 (default)")}")
    IO.puts("  SMTP_USERNAME:     #{present(username)}")
    IO.puts("  SMTP_PASSWORD:     #{redacted(password)}")
    IO.puts("  MAILER_FROM_EMAIL: #{present(from)}")
    IO.puts("  MAILER_FROM_NAME:  #{present(System.get_env("MAILER_FROM_NAME"), default: "Andy's Aces Accounting (default)")}")

    missing =
      [{"SMTP_USERNAME", username}, {"SMTP_PASSWORD", password}, {"MAILER_FROM_EMAIL", from}]
      |> Enum.filter(fn {_k, v} -> is_nil(v) or v == "" end)
      |> Enum.map(&elem(&1, 0))

    if missing != [] do
      IO.puts("")
      IO.puts("  ⚠ Missing required vars: #{Enum.join(missing, ", ")}")
      IO.puts("    Set them with: fly secrets set #{Enum.map_join(missing, " ", &"#{&1}=...")}")
    end

    IO.puts("")
  end

  defp print_config do
    cfg = Application.get_env(:aces, Aces.Mailer, [])

    IO.puts("Resolved Aces.Mailer config")
    IO.puts("  adapter:  #{inspect(cfg[:adapter])}")
    IO.puts("  relay:    #{inspect(cfg[:relay])}")
    IO.puts("  port:     #{inspect(cfg[:port])}")
    IO.puts("  username: #{present(cfg[:username])}")
    IO.puts("  password: #{redacted(cfg[:password])}")
    IO.puts("  tls:      #{inspect(cfg[:tls])}")
    IO.puts("  ssl:      #{inspect(cfg[:ssl])}")
    IO.puts("  auth:     #{inspect(cfg[:auth])}")

    if cfg[:adapter] != Swoosh.Adapters.SMTP do
      IO.puts("")
      IO.puts("  ⚠ Adapter is not Swoosh.Adapters.SMTP — are you running in :prod?")
      IO.puts("    (The SES SMTP config only loads when config_env() == :prod.)")
    end

    IO.puts("")
  end

  # ---- error interpretation ------------------------------------------------

  defp explain(reason) do
    IO.puts("Likely cause")

    text = inspect(reason) |> String.downcase()

    cond do
      contains?(text, ["email address is not verified", "not verified", "mailfromdomainnotverified"]) ->
        IO.puts("""
          SES rejected the sender or recipient as NOT VERIFIED.

          • If your SES account is still in the SANDBOX, you can only send to
            and from *verified* identities. Real users' addresses are not
            verified, so their mail is silently dropped — this matches
            "some emails don't get sent".
          • Verify your MAILER_FROM_EMAIL (or its domain) in the SES console,
            and request production access to leave the sandbox:
            https://docs.aws.amazon.com/ses/latest/dg/request-production-access.html
          • Make sure AWS_REGION matches the region where the identity is
            verified AND where these SMTP credentials were created.
        """)

      contains?(text, ["authentication", "535", "auth", "credentials", "username and password not accepted"]) ->
        IO.puts("""
          SES rejected authentication (SMTP 535 / auth failure).

          • SMTP_USERNAME / SMTP_PASSWORD must be *SES SMTP credentials*,
            NOT your AWS access key id / secret. Generate them under
            SES → SMTP settings → "Create SMTP credentials".
          • SMTP credentials are region-specific: the credentials must belong
            to the same region as AWS_REGION (#{System.get_env("AWS_REGION", "us-east-1")}).
        """)

      contains?(text, ["nxdomain", "timeout", "econnrefused", "closed", "tls", "ssl", "connect"]) ->
        IO.puts("""
          Could not establish a working SMTP/TLS connection to SES.

          • Confirm AWS_REGION is a real SES region (relay resolves to
            email-smtp.<region>.amazonaws.com).
          • Port 587 with STARTTLS (tls: :always, ssl: false) is correct for
            SES. Port 465 would need ssl: true instead.
          • Check fly.io egress / any firewall isn't blocking outbound 587.
        """)

      contains?(text, ["throttl", "limit", "rate", "454"]) ->
        IO.puts("""
          SES is throttling / rate-limiting (sandbox or sending-quota limits).

          • Sandbox accounts have very low send quotas. Request production
            access to raise them.
        """)

      true ->
        IO.puts("""
          Unrecognised error — inspect the raw error above.

          Common SES gotchas to check:
          • Sandbox mode (only verified recipients allowed).
          • AWS_REGION not matching where the SMTP creds / identities live.
          • Using AWS access keys instead of SES SMTP credentials.
          • From address / domain not verified.
        """)
    end
  end

  # ---- small utilities -----------------------------------------------------

  defp present(value, opts \\ [])
  defp present(nil, opts), do: Keyword.get(opts, :default, "(not set) ⚠")
  defp present("", opts), do: Keyword.get(opts, :default, "(empty) ⚠")
  defp present(value, _opts) when is_binary(value), do: value
  defp present(value, _opts), do: inspect(value)

  defp redacted(nil), do: "(not set) ⚠"
  defp redacted(""), do: "(empty) ⚠"
  defp redacted(value) when is_binary(value), do: "set (#{String.length(value)} chars, redacted)"
  defp redacted(_), do: "set (redacted)"

  defp contains?(text, needles), do: Enum.any?(needles, &String.contains?(text, &1))

  defp timestamp do
    DateTime.utc_now() |> DateTime.to_iso8601()
  end

  defp line, do: IO.puts(String.duplicate("=", 60))
end
