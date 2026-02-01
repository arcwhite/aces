defmodule AcesWeb.PageController do
  use AcesWeb, :controller

  def home(conn, _params) do
    render(conn, :home,
      page_title: "Andy's Aces Accounting",
      current_scope: conn.assigns[:current_scope]
    )
  end
end
