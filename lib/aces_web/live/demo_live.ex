defmodule AcesWeb.DemoLive do
  use AcesWeb, :live_view

  @topic "demo:interactions"

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(Aces.PubSub, @topic)
    end

    {:ok,
     socket
     |> assign(:page_title, "daisyUI Component Demo")
     |> assign(:interaction_count, 0)
     |> assign(:active_users, 1)
     |> assign(:button_clicks, %{})
     |> assign(:selected_tab, "components")
     |> assign(:show_modal, false)
     |> assign(:toast_message, nil)}
  end

  @impl true
  def handle_event("increment", %{"component" => component}, socket) do
    new_count = socket.assigns.interaction_count + 1

    broadcast_interaction({:interaction, component, new_count})

    {:noreply,
     socket
     |> assign(:interaction_count, new_count)
     |> update(:button_clicks, &Map.update(&1, component, 1, fn count -> count + 1 end))
     |> put_flash(:info, "#{component} clicked!")}
  end

  def handle_event("select_tab", %{"tab" => tab}, socket) do
    broadcast_interaction({:tab_change, tab})
    {:noreply, assign(socket, :selected_tab, tab)}
  end

  def handle_event("toggle_modal", _params, socket) do
    {:noreply, assign(socket, :show_modal, !socket.assigns.show_modal)}
  end

  def handle_event("close_modal", _params, socket) do
    {:noreply, assign(socket, :show_modal, false)}
  end

  @impl true
  def handle_info({:interaction, component, count}, socket) do
    {:noreply,
     socket
     |> assign(:interaction_count, count)
     |> update(:button_clicks, &Map.update(&1, component, 1, fn c -> c + 1 end))}
  end

  def handle_info({:tab_change, tab}, socket) do
    {:noreply, assign(socket, :selected_tab, tab)}
  end

  def handle_info({:user_joined}, socket) do
    {:noreply, update(socket, :active_users, &(&1 + 1))}
  end

  def handle_info({:user_left}, socket) do
    {:noreply, update(socket, :active_users, &max(&1 - 1, 0))}
  end

  defp broadcast_interaction(msg) do
    Phoenix.PubSub.broadcast(Aces.PubSub, @topic, msg)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="min-h-screen bg-base-200">
      <!-- Hero Section -->
      <div class="hero bg-primary text-primary-content py-8 md:py-12">
        <div class="hero-content text-center">
          <div class="max-w-2xl">
            <h1 class="text-3xl md:text-5xl font-bold">daisyUI Component Showcase</h1>
            <p class="py-4 md:py-6">
              Real-time collaborative demo powered by Phoenix LiveView
            </p>
            <div class="stats stats-vertical md:stats-horizontal shadow bg-base-100 text-base-content">
              <div class="stat">
                <div class="stat-title">Total Interactions</div>
                <div class="stat-value text-primary">{@interaction_count}</div>
                <div class="stat-desc">Across all users</div>
              </div>
              <div class="stat">
                <div class="stat-title">Active Users</div>
                <div class="stat-value text-secondary">{@active_users}</div>
                <div class="stat-desc">Viewing this page</div>
              </div>
            </div>
          </div>
        </div>
      </div>
      
    <!-- Main Content -->
      <div class="container mx-auto px-4 py-8">
        <!-- Tabs -->
        <div class="tabs tabs-boxed justify-center mb-8">
          <button
            class={["tab", @selected_tab == "components" && "tab-active"]}
            phx-click="select_tab"
            phx-value-tab="components"
          >
            Components
          </button>
          <button
            class={["tab", @selected_tab == "forms" && "tab-active"]}
            phx-click="select_tab"
            phx-value-tab="forms"
          >
            Forms
          </button>
          <button
            class={["tab", @selected_tab == "data" && "tab-active"]}
            phx-click="select_tab"
            phx-value-tab="data"
          >
            Data Display
          </button>
        </div>
        
    <!-- Components Tab -->
        <div :if={@selected_tab == "components"} class="space-y-8">
          <!-- Buttons Section -->
          <div class="card bg-base-100 shadow-xl">
            <div class="card-body">
              <h2 class="card-title">Buttons</h2>
              <p class="text-sm text-base-content/70">
                Click any button to increment the global counter (synced across all users)
              </p>
              <div class="flex flex-wrap gap-2 mt-4">
                <button
                  class="btn btn-primary"
                  phx-click="increment"
                  phx-value-component="primary"
                >
                  Primary
                  <span :if={Map.get(@button_clicks, "primary", 0) > 0} class="badge badge-secondary">
                    {Map.get(@button_clicks, "primary")}
                  </span>
                </button>
                <button
                  class="btn btn-secondary"
                  phx-click="increment"
                  phx-value-component="secondary"
                >
                  Secondary
                  <span :if={Map.get(@button_clicks, "secondary", 0) > 0} class="badge badge-primary">
                    {Map.get(@button_clicks, "secondary")}
                  </span>
                </button>
                <button
                  class="btn btn-accent"
                  phx-click="increment"
                  phx-value-component="accent"
                >
                  Accent
                  <span :if={Map.get(@button_clicks, "accent", 0) > 0} class="badge badge-ghost">
                    {Map.get(@button_clicks, "accent")}
                  </span>
                </button>
                <button
                  class="btn btn-ghost"
                  phx-click="increment"
                  phx-value-component="ghost"
                >
                  Ghost
                </button>
                <button
                  class="btn btn-link"
                  phx-click="increment"
                  phx-value-component="link"
                >
                  Link
                </button>
              </div>
              <div class="flex flex-wrap gap-2 mt-2">
                <button class="btn btn-sm">Small</button>
                <button class="btn">Normal</button>
                <button class="btn btn-lg">Large</button>
              </div>
            </div>
          </div>
          
    <!-- Badges & Alerts -->
          <div class="grid grid-cols-1 md:grid-cols-2 gap-4">
            <div class="card bg-base-100 shadow-xl">
              <div class="card-body">
                <h2 class="card-title">Badges</h2>
                <div class="flex flex-wrap gap-2">
                  <div class="badge">Default</div>
                  <div class="badge badge-primary">Primary</div>
                  <div class="badge badge-secondary">Secondary</div>
                  <div class="badge badge-accent">Accent</div>
                  <div class="badge badge-ghost">Ghost</div>
                  <div class="badge badge-info">Info</div>
                  <div class="badge badge-success">Success</div>
                  <div class="badge badge-warning">Warning</div>
                  <div class="badge badge-error">Error</div>
                </div>
              </div>
            </div>

            <div class="card bg-base-100 shadow-xl">
              <div class="card-body">
                <h2 class="card-title">Alerts</h2>
                <div class="alert alert-info">
                  <svg
                    xmlns="http://www.w3.org/2000/svg"
                    fill="none"
                    viewBox="0 0 24 24"
                    class="stroke-current shrink-0 w-6 h-6"
                  >
                    <path
                      stroke-linecap="round"
                      stroke-linejoin="round"
                      stroke-width="2"
                      d="M13 16h-1v-4h-1m1-4h.01M21 12a9 9 0 11-18 0 9 9 0 0118 0z"
                    />
                  </svg>
                  <span>This is real-time collaborative!</span>
                </div>
                <div class="alert alert-success">
                  <svg
                    xmlns="http://www.w3.org/2000/svg"
                    class="stroke-current shrink-0 h-6 w-6"
                    fill="none"
                    viewBox="0 0 24 24"
                  >
                    <path
                      stroke-linecap="round"
                      stroke-linejoin="round"
                      stroke-width="2"
                      d="M9 12l2 2 4-4m6 2a9 9 0 11-18 0 9 9 0 0118 0z"
                    />
                  </svg>
                  <span>LiveView connected!</span>
                </div>
              </div>
            </div>
          </div>
          
    <!-- Modal Demo -->
          <div class="card bg-base-100 shadow-xl">
            <div class="card-body">
              <h2 class="card-title">Modal</h2>
              <button class="btn btn-primary w-fit" phx-click="toggle_modal">
                Open Modal
              </button>
            </div>
          </div>
          
    <!-- Cards with Images -->
          <div class="grid grid-cols-1 md:grid-cols-3 gap-4">
            <div class="card bg-base-100 shadow-xl">
              <div class="card-body">
                <h2 class="card-title">BattleMech</h2>
                <p>Heavy assault unit</p>
                <div class="badge badge-primary">100 tons</div>
                <div class="badge badge-secondary">48 PV</div>
                <div class="card-actions justify-end mt-4">
                  <button class="btn btn-primary btn-sm">Deploy</button>
                </div>
              </div>
            </div>

            <div class="card bg-base-100 shadow-xl">
              <div class="card-body">
                <h2 class="card-title">Combat Vehicle</h2>
                <p>Fast reconnaissance</p>
                <div class="badge badge-accent">30 tons</div>
                <div class="badge badge-ghost">12 PV</div>
                <div class="card-actions justify-end mt-4">
                  <button class="btn btn-secondary btn-sm">Deploy</button>
                </div>
              </div>
            </div>

            <div class="card bg-base-100 shadow-xl">
              <div class="card-body">
                <h2 class="card-title">Battle Armor</h2>
                <p>Infantry support</p>
                <div class="badge badge-info">750 kg</div>
                <div class="badge badge-success">6 PV</div>
                <div class="card-actions justify-end mt-4">
                  <button class="btn btn-accent btn-sm">Deploy</button>
                </div>
              </div>
            </div>
          </div>
        </div>
        
    <!-- Forms Tab -->
        <div :if={@selected_tab == "forms"} class="space-y-8">
          <div class="card bg-base-100 shadow-xl">
            <div class="card-body">
              <h2 class="card-title">Form Controls</h2>
              <div class="form-control w-full max-w-xs">
                <label class="label">
                  <span class="label-text">Pilot Callsign</span>
                </label>
                <input type="text" placeholder="Enter callsign" class="input input-bordered w-full" />
              </div>

              <div class="form-control w-full max-w-xs">
                <label class="label">
                  <span class="label-text">Skill Level</span>
                </label>
                <select class="select select-bordered">
                  <option>Green (5)</option>
                  <option>Regular (4)</option>
                  <option>Veteran (3)</option>
                  <option>Elite (2)</option>
                  <option>Legendary (1)</option>
                </select>
              </div>

              <div class="form-control">
                <label class="label cursor-pointer justify-start gap-2">
                  <input type="checkbox" class="checkbox checkbox-primary" />
                  <span class="label-text">Award MVP Bonus (+20 SP)</span>
                </label>
              </div>

              <div class="form-control">
                <label class="label cursor-pointer justify-start gap-2">
                  <input type="radio" name="damage" class="radio radio-primary" checked />
                  <span class="label-text">No Damage</span>
                </label>
                <label class="label cursor-pointer justify-start gap-2">
                  <input type="radio" name="damage" class="radio radio-warning" />
                  <span class="label-text">Armor Damage</span>
                </label>
                <label class="label cursor-pointer justify-start gap-2">
                  <input type="radio" name="damage" class="radio radio-error" />
                  <span class="label-text">Structure Damage</span>
                </label>
              </div>

              <div class="form-control w-full max-w-xs">
                <label class="label">
                  <span class="label-text">Point Value</span>
                </label>
                <input type="range" min="0" max="100" value="48" class="range range-primary" />
                <div class="w-full flex justify-between text-xs px-2">
                  <span>0</span>
                  <span>25</span>
                  <span>50</span>
                  <span>75</span>
                  <span>100</span>
                </div>
              </div>

              <div class="form-control">
                <label class="label">
                  <span class="label-text">Mission Notes</span>
                </label>
                <textarea
                  class="textarea textarea-bordered h-24"
                  placeholder="Enter mission details..."
                ></textarea>
              </div>
            </div>
          </div>
        </div>
        
    <!-- Data Display Tab -->
        <div :if={@selected_tab == "data"} class="space-y-8">
          <div class="card bg-base-100 shadow-xl">
            <div class="card-body">
              <h2 class="card-title">Campaign Stats</h2>
              <div class="stats stats-vertical md:stats-horizontal shadow">
                <div class="stat">
                  <div class="stat-figure text-primary">
                    <svg
                      xmlns="http://www.w3.org/2000/svg"
                      fill="none"
                      viewBox="0 0 24 24"
                      class="inline-block w-8 h-8 stroke-current"
                    >
                      <path
                        stroke-linecap="round"
                        stroke-linejoin="round"
                        stroke-width="2"
                        d="M4.318 6.318a4.5 4.5 0 000 6.364L12 20.364l7.682-7.682a4.5 4.5 0 00-6.364-6.364L12 7.636l-1.318-1.318a4.5 4.5 0 00-6.364 0z"
                      />
                    </svg>
                  </div>
                  <div class="stat-title">Warchest</div>
                  <div class="stat-value text-primary">12,450</div>
                  <div class="stat-desc">SP available</div>
                </div>

                <div class="stat">
                  <div class="stat-figure text-secondary">
                    <svg
                      xmlns="http://www.w3.org/2000/svg"
                      fill="none"
                      viewBox="0 0 24 24"
                      class="inline-block w-8 h-8 stroke-current"
                    >
                      <path
                        stroke-linecap="round"
                        stroke-linejoin="round"
                        stroke-width="2"
                        d="M13 10V3L4 14h7v7l9-11h-7z"
                      />
                    </svg>
                  </div>
                  <div class="stat-title">Sorties</div>
                  <div class="stat-value text-secondary">8</div>
                  <div class="stat-desc">Completed</div>
                </div>

                <div class="stat">
                  <div class="stat-title">Pilots</div>
                  <div class="stat-value">6</div>
                  <div class="stat-desc">Active roster</div>
                </div>
              </div>
            </div>
          </div>

          <div class="card bg-base-100 shadow-xl overflow-x-auto">
            <div class="card-body">
              <h2 class="card-title">Pilot Roster</h2>
              <table class="table">
                <thead>
                  <tr>
                    <th>Callsign</th>
                    <th>Skill</th>
                    <th>Edge</th>
                    <th>Status</th>
                    <th>Actions</th>
                  </tr>
                </thead>
                <tbody>
                  <tr>
                    <td>
                      <div class="flex items-center gap-3">
                        <div class="avatar placeholder">
                          <div class="bg-primary text-primary-content rounded-full w-12">
                            <span>GD</span>
                          </div>
                        </div>
                        <div>
                          <div class="font-bold">Grayson Carlyle</div>
                          <div class="text-sm opacity-50">Commander</div>
                        </div>
                      </div>
                    </td>
                    <td>
                      <span class="badge badge-primary">Elite (2)</span>
                    </td>
                    <td>
                      <div class="flex gap-1">
                        <div class="badge badge-sm">5 tokens</div>
                        <div class="badge badge-sm badge-ghost">Oblique Artillery</div>
                      </div>
                    </td>
                    <td>
                      <span class="badge badge-success">Active</span>
                    </td>
                    <td>
                      <button class="btn btn-ghost btn-xs">Edit</button>
                    </td>
                  </tr>
                  <tr>
                    <td>
                      <div class="flex items-center gap-3">
                        <div class="avatar placeholder">
                          <div class="bg-secondary text-secondary-content rounded-full w-12">
                            <span>LM</span>
                          </div>
                        </div>
                        <div>
                          <div class="font-bold">Lori Kalmar</div>
                          <div class="text-sm opacity-50">Second-in-Command</div>
                        </div>
                      </div>
                    </td>
                    <td>
                      <span class="badge badge-secondary">Veteran (3)</span>
                    </td>
                    <td>
                      <div class="flex gap-1">
                        <div class="badge badge-sm">4 tokens</div>
                      </div>
                    </td>
                    <td>
                      <span class="badge badge-success">Active</span>
                    </td>
                    <td>
                      <button class="btn btn-ghost btn-xs">Edit</button>
                    </td>
                  </tr>
                  <tr>
                    <td>
                      <div class="flex items-center gap-3">
                        <div class="avatar placeholder">
                          <div class="bg-accent text-accent-content rounded-full w-12">
                            <span>DB</span>
                          </div>
                        </div>
                        <div>
                          <div class="font-bold">Davis McCall</div>
                          <div class="text-sm opacity-50">Scout</div>
                        </div>
                      </div>
                    </td>
                    <td>
                      <span class="badge badge-accent">Regular (4)</span>
                    </td>
                    <td>
                      <div class="flex gap-1">
                        <div class="badge badge-sm">3 tokens</div>
                        <div class="badge badge-sm badge-ghost">Weapon Specialist</div>
                      </div>
                    </td>
                    <td>
                      <span class="badge badge-warning">Wounded</span>
                    </td>
                    <td>
                      <button class="btn btn-ghost btn-xs">Edit</button>
                    </td>
                  </tr>
                </tbody>
              </table>
            </div>
          </div>
          
    <!-- Timeline -->
          <div class="card bg-base-100 shadow-xl">
            <div class="card-body">
              <h2 class="card-title">Campaign Timeline</h2>
              <ul class="timeline timeline-vertical">
                <li>
                  <div class="timeline-start">3145-08-15</div>
                  <div class="timeline-middle">
                    <svg
                      xmlns="http://www.w3.org/2000/svg"
                      viewBox="0 0 20 20"
                      fill="currentColor"
                      class="w-5 h-5 text-primary"
                    >
                      <path
                        fill-rule="evenodd"
                        d="M10 18a8 8 0 100-16 8 8 0 000 16zm3.857-9.809a.75.75 0 00-1.214-.882l-3.483 4.79-1.88-1.88a.75.75 0 10-1.06 1.061l2.5 2.5a.75.75 0 001.137-.089l4-5.5z"
                        clip-rule="evenodd"
                      />
                    </svg>
                  </div>
                  <div class="timeline-end timeline-box">Campaign Started</div>
                  <hr class="bg-primary" />
                </li>
                <li>
                  <hr class="bg-primary" />
                  <div class="timeline-start">3145-08-20</div>
                  <div class="timeline-middle">
                    <svg
                      xmlns="http://www.w3.org/2000/svg"
                      viewBox="0 0 20 20"
                      fill="currentColor"
                      class="w-5 h-5 text-primary"
                    >
                      <path
                        fill-rule="evenodd"
                        d="M10 18a8 8 0 100-16 8 8 0 000 16zm3.857-9.809a.75.75 0 00-1.214-.882l-3.483 4.79-1.88-1.88a.75.75 0 10-1.06 1.061l2.5 2.5a.75.75 0 001.137-.089l4-5.5z"
                        clip-rule="evenodd"
                      />
                    </svg>
                  </div>
                  <div class="timeline-end timeline-box">
                    Sortie 1: Recon Raid
                    <div class="badge badge-success badge-sm ml-2">Victory</div>
                  </div>
                  <hr />
                </li>
                <li>
                  <hr />
                  <div class="timeline-start">3145-09-03</div>
                  <div class="timeline-middle">
                    <svg
                      xmlns="http://www.w3.org/2000/svg"
                      viewBox="0 0 20 20"
                      fill="currentColor"
                      class="w-5 h-5"
                    >
                      <path
                        fill-rule="evenodd"
                        d="M10 18a8 8 0 100-16 8 8 0 000 16zm3.857-9.809a.75.75 0 00-1.214-.882l-3.483 4.79-1.88-1.88a.75.75 0 10-1.06 1.061l2.5 2.5a.75.75 0 001.137-.089l4-5.5z"
                        clip-rule="evenodd"
                      />
                    </svg>
                  </div>
                  <div class="timeline-end timeline-box">
                    Sortie 2: Convoy Escort
                    <div class="badge badge-warning badge-sm ml-2">Partial</div>
                  </div>
                </li>
              </ul>
            </div>
          </div>
        </div>
        
    <!-- Loading States -->
        <div class="card bg-base-100 shadow-xl">
          <div class="card-body">
            <h2 class="card-title">Loading States</h2>
            <div class="flex flex-wrap gap-4">
              <span class="loading loading-spinner loading-xs"></span>
              <span class="loading loading-spinner loading-sm"></span>
              <span class="loading loading-spinner loading-md"></span>
              <span class="loading loading-spinner loading-lg"></span>
            </div>
            <div class="flex flex-wrap gap-4 mt-4">
              <button class="btn btn-primary">
                <span class="loading loading-spinner"></span> Processing...
              </button>
              <button class="btn btn-secondary" disabled>
                <span class="loading loading-dots"></span>
              </button>
            </div>
          </div>
        </div>
      </div>
      
    <!-- Modal -->
      <dialog :if={@show_modal} class="modal modal-open">
        <div class="modal-box">
          <h3 class="font-bold text-lg">Modal Demo</h3>
          <p class="py-4">
            This is a daisyUI modal! All interactions on this page are synced across connected users via Phoenix PubSub.
          </p>
          <p class="text-sm text-base-content/70">
            Total interactions so far: <span class="badge badge-primary">{@interaction_count}</span>
          </p>
          <div class="modal-action">
            <button class="btn" phx-click="close_modal">Close</button>
            <button class="btn btn-primary" phx-click="close_modal">Got it!</button>
          </div>
        </div>
        <form method="dialog" class="modal-backdrop" phx-click="close_modal">
          <button>close</button>
        </form>
      </dialog>
      
    <!-- Bottom Navigation (Mobile) -->
      <div class="btm-nav md:hidden">
        <button
          class={[@selected_tab == "components" && "active"]}
          phx-click="select_tab"
          phx-value-tab="components"
        >
          <svg
            xmlns="http://www.w3.org/2000/svg"
            class="h-5 w-5"
            fill="none"
            viewBox="0 0 24 24"
            stroke="currentColor"
          >
            <path
              stroke-linecap="round"
              stroke-linejoin="round"
              stroke-width="2"
              d="M3 12l2-2m0 0l7-7 7 7M5 10v10a1 1 0 001 1h3m10-11l2 2m-2-2v10a1 1 0 01-1 1h-3m-6 0a1 1 0 001-1v-4a1 1 0 011-1h2a1 1 0 011 1v4a1 1 0 001 1m-6 0h6"
            />
          </svg>
          <span class="btm-nav-label">Components</span>
        </button>
        <button
          class={[@selected_tab == "forms" && "active"]}
          phx-click="select_tab"
          phx-value-tab="forms"
        >
          <svg
            xmlns="http://www.w3.org/2000/svg"
            class="h-5 w-5"
            fill="none"
            viewBox="0 0 24 24"
            stroke="currentColor"
          >
            <path
              stroke-linecap="round"
              stroke-linejoin="round"
              stroke-width="2"
              d="M9 12h6m-6 4h6m2 5H7a2 2 0 01-2-2V5a2 2 0 012-2h5.586a1 1 0 01.707.293l5.414 5.414a1 1 0 01.293.707V19a2 2 0 01-2 2z"
            />
          </svg>
          <span class="btm-nav-label">Forms</span>
        </button>
        <button
          class={[@selected_tab == "data" && "active"]}
          phx-click="select_tab"
          phx-value-tab="data"
        >
          <svg
            xmlns="http://www.w3.org/2000/svg"
            class="h-5 w-5"
            fill="none"
            viewBox="0 0 24 24"
            stroke="currentColor"
          >
            <path
              stroke-linecap="round"
              stroke-linejoin="round"
              stroke-width="2"
              d="M9 19v-6a2 2 0 00-2-2H5a2 2 0 00-2 2v6a2 2 0 002 2h2a2 2 0 002-2zm0 0V9a2 2 0 012-2h2a2 2 0 012 2v10m-6 0a2 2 0 002 2h2a2 2 0 002-2m0 0V5a2 2 0 012-2h2a2 2 0 012 2v14a2 2 0 01-2 2h-2a2 2 0 01-2-2z"
            />
          </svg>
          <span class="btm-nav-label">Data</span>
        </button>
      </div>
    </div>
    """
  end
end
