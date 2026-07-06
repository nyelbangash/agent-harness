defmodule HarnessWeb.Router do
  use HarnessWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {HarnessWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  scope "/", HarnessWeb do
    pipe_through :browser

    live_session :mission_control, on_mount: [HarnessWeb.RailHooks] do
      live "/", OverviewLive
      live "/issues", IssuesLive
      live "/issues/:id", IssuesLive
      live "/runs", RunsLive
      live "/runs/:id", RunsLive
      live "/ideation", IdeationLive
      live "/ideation/:id", IdeationLive
      live "/budget", BudgetLive
      live "/compose", ComposeLive
      live "/compose/:id", ComposeLive
    end

    get "/ideation/:id/synthesis.md", DownloadController, :synthesis
    get "/ideation/:id/journal.md", DownloadController, :journal
    get "/ideation/:id/export.zip", DownloadController, :zip
    get "/ideation/nodes/:idea_id/artifact.md", DownloadController, :node
    get "/compose/:id/draft.md", DownloadController, :draft
    get "/compose/:id/attachments/:filename", DownloadController, :draft_attachment
    get "/ideation/:id/attachments/:filename", DownloadController, :ideation_attachment
  end

  scope "/", HarnessWeb do
    pipe_through :api
    get "/healthz", HealthController, :index
  end

  # Enable LiveDashboard in development
  if Application.compile_env(:harness, :dev_routes) do
    # If you want to use the LiveDashboard in production, you should put
    # it behind authentication and allow only admins to access it.
    # If your application does not have an admins-only section yet,
    # you can use Plug.BasicAuth to set up some basic authentication
    # as long as you are also using SSL (which you should anyway).
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through :browser

      live_dashboard "/dashboard", metrics: HarnessWeb.Telemetry
    end
  end
end
