defmodule AcesWeb.PageController do
  use AcesWeb, :controller

  def home(conn, _params) do
    render(conn, :home)
  end
end
