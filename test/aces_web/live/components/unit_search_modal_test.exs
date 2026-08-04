defmodule AcesWeb.Components.UnitSearchModalTest do
  use AcesWeb.ConnCase

  import Phoenix.LiveViewTest
  import Aces.UnitsFixtures


  @endpoint AcesWeb.Endpoint

  # The modal's default filter selection is ilclan+dark_age+mercenary; every
  # fixture in this suite lives under those keys so the default view matches.
  @default_factions %{"ilclan" => ["mercenary"], "dark_age" => ["mercenary"]}

  # Minimal host LiveView for isolated component testing. Keeps `:show`
  # controllable via a message so tests can drive open/close edges
  # without dragging in the full CampaignLive.Show stack.
  defmodule ModalHost do
    use Phoenix.LiveView

    alias AcesWeb.Components.UnitSearchModal

    @impl true
    def mount(_params, _session, socket) do
      {:ok,
       socket
       |> Phoenix.Component.assign(:show, false)
       |> Phoenix.Component.assign(:mode, :pv_budget)
       |> Phoenix.Component.assign(:budget, 10_000)
       |> Phoenix.Component.assign(:error, nil)}
    end

    @impl true
    def handle_event("open", _params, socket) do
      {:noreply, Phoenix.Component.assign(socket, :show, true)}
    end

    def handle_event("parent_close", _params, socket) do
      {:noreply, Phoenix.Component.assign(socket, :show, false)}
    end

    @impl true
    def handle_info({UnitSearchModal, :close_modal}, socket) do
      {:noreply, Phoenix.Component.assign(socket, :show, false)}
    end

    def handle_info({UnitSearchModal, {:unit_selected, mul_id}}, socket) do
      send(self(), {:selected, mul_id})
      {:noreply, socket}
    end

    @impl true
    def render(assigns) do
      ~H"""
      <div id="modal-host">
        <button type="button" phx-click="open" id="btn-open">Open</button>
        <button type="button" phx-click="parent_close" id="btn-parent-close">Parent Close</button>
        <.live_component
          module={UnitSearchModal}
          id="unit-search"
          show={@show}
          mode={@mode}
          budget={@budget}
          error={@error}
        />
      </div>
      """
    end
  end

  setup do
    original = Application.get_env(:aces, :mul_fixture_path)
    on_exit(fn -> Application.put_env(:aces, :mul_fixture_path, original) end)
    :ok
  end

  # Points the fixture-backed client at a temp fixture set, so a test can
  # choose what the MUL layer returns without a second injection seam.
  defp put_fixture_units(units) do
    path =
      Path.join(
        System.tmp_dir!(),
        "aces-modal-test-#{System.unique_integer([:positive])}.json"
      )

    File.write!(path, Jason.encode!(%{"units" => units}))
    Application.put_env(:aces, :mul_fixture_path, path)
    on_exit(fn -> File.rm(path) end)
    path
  end

  defp merc_fixture(attrs) do
    attrs
    |> Enum.into(%{factions: @default_factions})
    |> units_master_unit_fixture()
  end

  defp open_modal(view) do
    view |> element("#btn-open") |> render_click()
  end

  describe "default results on open" do
    test "loads cached units on the false→true transition", %{conn: conn} do
      _atlas =
        merc_fixture(name: "Atlas", variant: "AS7-D", full_name: "Atlas AS7-D", point_value: 48)

      _locust =
        merc_fixture(
          name: "Locust",
          variant: "LCT-1V",
          full_name: "Locust LCT-1V",
          point_value: 8
        )

      {:ok, view, _html} = live_isolated(conn, ModalHost)

      html = open_modal(view)

      # Default view shows results without any search having been typed.
      assert html =~ "Atlas"
      assert html =~ "Locust"
      # Source indicator is present and reads "from local cache".
      assert html =~ "from local cache"
    end

    test "orders by point_value then name", %{conn: conn} do
      _big =
        merc_fixture(name: "ZZZ Heavy", variant: "H1", full_name: "ZZZ Heavy H1", point_value: 60)

      _small =
        merc_fixture(name: "AAA Light", variant: "L1", full_name: "AAA Light L1", point_value: 8)

      {:ok, view, _html} = live_isolated(conn, ModalHost)
      html = open_modal(view)

      light_idx = :binary.match(html, "AAA Light") |> elem(0)
      heavy_idx = :binary.match(html, "ZZZ Heavy") |> elem(0)
      assert light_idx < heavy_idx
    end

    test "limits default view to 50 rows", %{conn: conn} do
      for i <- 1..60 do
        merc_fixture(
          name: "Bulk Unit #{i}",
          variant: "B-#{i}",
          full_name: "Bulk Unit B-#{i}",
          point_value: 20 + rem(i, 10)
        )
      end

      {:ok, view, _html} = live_isolated(conn, ModalHost)
      html = open_modal(view)

      assert html =~ "50 units"
    end

    test "shows cache-empty message when nothing matches the current filters", %{conn: conn} do
      {:ok, view, _html} = live_isolated(conn, ModalHost)
      html = open_modal(view)

      assert html =~ "Unit cache is empty"
      assert html =~ "mix seed_master_units --matrix"
    end
  end

  describe "reset on close" do
    test "close event clears search term and results", %{conn: conn} do
      _atlas = merc_fixture(name: "Atlas", variant: "AS7-D", full_name: "Atlas AS7-D")

      {:ok, view, _html} = live_isolated(conn, ModalHost)
      _html = open_modal(view)

      # Type a search that matches nothing → MUL-empty via the fixture client.
      put_fixture_units([])

      view
      |> element("input[name=search]")
      |> render_keyup(%{"value" => "Nonexistent"})

      assert render(view) =~ "No units match"

      # Trigger close via the modal's own X button.
      view |> element("button[phx-click='close']") |> render_click()

      # Reopen — search term should be blank, mul_empty banner gone.
      html = open_modal(view)
      refute html =~ "No units match"
      refute html =~ "Nonexistent"
    end

    test "parent-driven dismissal resets search state", %{conn: conn} do
      _atlas = merc_fixture(name: "Atlas", variant: "AS7-D", full_name: "Atlas AS7-D")

      {:ok, view, _html} = live_isolated(conn, ModalHost)
      _html = open_modal(view)

      put_fixture_units([])

      view
      |> element("input[name=search]")
      |> render_keyup(%{"value" => "Nonexistent"})

      assert render(view) =~ "No units match"

      # Parent-driven close (e.g. push_patch back to base URL).
      view |> element("#btn-parent-close") |> render_click()

      # Reopen — cache-based defaults, no stale error.
      html = open_modal(view)
      refute html =~ "No units match"
      refute html =~ "Nonexistent"
      assert html =~ "Atlas"
    end
  end

  describe "empty and error states" do
    test "renders :mul_empty distinctly from cache-empty", %{conn: conn} do
      _atlas = merc_fixture(name: "Atlas", variant: "AS7-D", full_name: "Atlas AS7-D")

      {:ok, view, _html} = live_isolated(conn, ModalHost)
      _html = open_modal(view)

      put_fixture_units([])

      view
      |> element("input[name=search]")
      |> render_keyup(%{"value" => "Zzzzzzz"})

      html = render(view)
      assert html =~ ~s(No units match &quot;Zzzzzzz&quot;)
      refute html =~ "Unit cache is empty"
    end

    # NOTE: the modal's {:mul_unavailable, _} branch has no end-to-end test.
    # Reaching it needs the client to report a transport/rate-limit failure,
    # which the fixture-backed client cannot produce — it reads a local file.
    # The client's own mapping of those failures is covered in
    # test/aces/mul/client_test.exs; only the modal rendering is uncovered.
    test "renders :query_failed when the client cannot serve the query", %{conn: conn} do
      _atlas = merc_fixture(name: "Atlas", variant: "AS7-D", full_name: "Atlas AS7-D")

      {:ok, view, _html} = live_isolated(conn, ModalHost)
      _html = open_modal(view)

      Application.put_env(:aces, :mul_fixture_path, "/tmp/aces-no-such-fixture-file.json")

      view
      |> element("input[name=search]")
      |> render_keyup(%{"value" => "Zzzzzzz"})

      html = render(view)
      assert html =~ ~s(data-role="query-failed")
      assert html =~ "Something went wrong looking up units"
    end
  end

  describe "source indicator" do
    test "shows 'from local cache' when results served from local", %{conn: conn} do
      _atlas = merc_fixture(name: "Atlas", variant: "AS7-D", full_name: "Atlas AS7-D")

      {:ok, view, _html} = live_isolated(conn, ModalHost)
      _html = open_modal(view)

      view
      |> element("input[name=search]")
      |> render_keyup(%{"value" => "Atlas"})

      html = render(view)
      assert html =~ "Atlas"
      assert html =~ "from local cache"
    end

    test "names the fixture backing when results come from the fixture client", %{conn: conn} do
      # No local rows for the search term, so the search falls through to the
      # client. Under test config that client is fixture-backed, and the label
      # must say so rather than implying a live MUL hit.
      put_fixture_units([
        %{
          "mul_id" => 500_001,
          "name" => "MUL Fallback Mech",
          "variant" => "MFM-1",
          "full_name" => "MUL Fallback Mech MFM-1",
          "unit_type" => "battlemech",
          "bf_type" => "BM",
          "point_value" => 25,
          "factions" => %{"ilclan" => ["mercenary"], "dark_age" => ["mercenary"]}
        }
      ])

      {:ok, view, _html} = live_isolated(conn, ModalHost)
      _html = open_modal(view)

      view
      |> element("input[name=search]")
      |> render_keyup(%{"value" => "Fallback"})

      html = render(view)
      assert html =~ "MUL Fallback Mech"
      assert html =~ "from local fixtures"
    end
  end
end
