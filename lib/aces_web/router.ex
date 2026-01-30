defmodule AcesWeb.Router do
  use AcesWeb, :router

  import AcesWeb.UserAuth

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {AcesWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
    plug :fetch_current_scope_for_user
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  scope "/", AcesWeb do
    pipe_through :browser

    get "/", PageController, :home
  end

  # Other scopes may use custom stacks.
  # scope "/api", AcesWeb do
  #   pipe_through :api
  # end

  # Enable LiveDashboard and Swoosh mailbox preview in development
  if Application.compile_env(:aces, :dev_routes) do
    # If you want to use the LiveDashboard in production, you should put
    # it behind authentication and allow only admins to access it.
    # If your application does not have an admins-only section yet,
    # you can use Plug.BasicAuth to set up some basic authentication
    # as long as you are also using SSL (which you should anyway).
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through :browser

      live_dashboard "/dashboard", metrics: AcesWeb.Telemetry
      forward "/mailbox", Plug.Swoosh.MailboxPreview
    end
  end

  ## Authentication routes

  scope "/", AcesWeb do
    pipe_through [:browser, :redirect_if_user_is_authenticated]

    get "/users/register", UserRegistrationController, :new
    post "/users/register", UserRegistrationController, :create
  end

  scope "/", AcesWeb do
    pipe_through [:browser, :require_authenticated_user]

    # Company routes
    live "/companies", CompanyLive.Index, :index
    live "/companies/new", CompanyLive.New
    live "/companies/:id/draft", CompanyLive.Draft, :draft
    live "/companies/:id", CompanyLive.Show, :show

    # Campaign routes
    live "/campaigns", CampaignLive.Index, :index
    live "/companies/:company_id/campaigns/new", CampaignLive.New, :new
    live "/companies/:company_id/campaigns/:id", CampaignLive.Show, :show

    # Sortie routes
    live "/companies/:company_id/campaigns/:campaign_id/sorties/new", SortieLive.New, :new
    live "/companies/:company_id/campaigns/:campaign_id/sorties/:id", SortieLive.Show, :show
    live "/companies/:company_id/campaigns/:campaign_id/sorties/:id/edit", SortieLive.Edit, :edit

    # Sortie completion wizard
    live "/companies/:company_id/campaigns/:campaign_id/sorties/:id/complete/outcome", SortieLive.Complete.Outcome, :outcome
    live "/companies/:company_id/campaigns/:campaign_id/sorties/:id/complete/damage", SortieLive.Complete.Damage, :damage
    live "/companies/:company_id/campaigns/:campaign_id/sorties/:id/complete/costs", SortieLive.Complete.Costs, :costs
    live "/companies/:company_id/campaigns/:campaign_id/sorties/:id/complete/pilots", SortieLive.Complete.Pilots, :pilots
    live "/companies/:company_id/campaigns/:campaign_id/sorties/:id/complete/spend_sp", SortieLive.Complete.SpendSP, :spend_sp
    live "/companies/:company_id/campaigns/:campaign_id/sorties/:id/complete/summary", SortieLive.Complete.Summary, :summary

    get "/users/settings", UserSettingsController, :edit
    put "/users/settings", UserSettingsController, :update
    get "/users/settings/confirm-email/:token", UserSettingsController, :confirm_email
  end

  scope "/", AcesWeb do
    pipe_through [:browser]

    get "/users/log-in", UserSessionController, :new
    post "/users/log-in", UserSessionController, :create
    get "/users/confirm/:token", UserSessionController, :confirm
    delete "/users/log-out", UserSessionController, :delete

    get "/users/reset-password", UserResetPasswordController, :new
    post "/users/reset-password", UserResetPasswordController, :create
    get "/users/reset-password/:token", UserResetPasswordController, :edit
    put "/users/reset-password/:token", UserResetPasswordController, :update
  end
end
