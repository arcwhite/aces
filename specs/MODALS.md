# URL-Based Modal State for Mobile Reconnection

## Problem

When using the app on mobile, switching away from the browser tab causes the WebSocket connection to drop. When the user returns, LiveView reconnects and re-runs `mount/3` from scratch, losing all ephemeral state including:
- Open modals
- Form data within modals
- Any unsaved work

This is particularly frustrating when users are in the middle of filling out forms in modals.

## Solution

Use **URL-based state** for modal visibility. When a modal opens, push the modal identifier to the URL as a query parameter. On reconnect, `handle_params` reads the URL and restores the modal state.

### Benefits
- Survives WebSocket reconnection
- Browser back button closes modals naturally
- State is bookmarkable/shareable
- Idiomatic Phoenix/LiveView pattern

## Implementation Pattern

### Opening a Modal
```elixir
# Before (socket assign only - lost on reconnect)
def handle_event("invite_member", _params, socket) do
  {:noreply, assign(socket, :show_invite_modal, true)}
end

# After (URL-based - survives reconnect)
def handle_event("invite_member", _params, socket) do
  {:noreply, push_patch(socket, to: ~p"/companies/#{socket.assigns.company}?modal=invite")}
end
```

### Restoring State in handle_params
```elixir
@impl true
def handle_params(params, _uri, socket) do
  {:noreply, apply_modal_state(socket, params["modal"])}
end

defp apply_modal_state(socket, "invite"), do: assign(socket, :show_invite_modal, true)
defp apply_modal_state(socket, "unit_search"), do: assign(socket, :show_unit_search, true)
defp apply_modal_state(socket, "unit_edit"), do: assign(socket, :show_unit_edit, true)
defp apply_modal_state(socket, "pilot_edit"), do: assign(socket, :show_pilot_edit, true)
defp apply_modal_state(socket, _) do
  socket
  |> assign(:show_invite_modal, false)
  |> assign(:show_unit_search, false)
  |> assign(:show_unit_edit, false)
  |> assign(:show_pilot_edit, false)
end
```

### Closing a Modal
```elixir
# From component message
def handle_info({AcesWeb.CompanyLive.InviteModal, :close_modal}, socket) do
  {:noreply, push_patch(socket, to: ~p"/companies/#{socket.assigns.company}")}
end

# From direct event
def handle_event("close_unit_edit", _params, socket) do
  {:noreply, push_patch(socket, to: ~p"/companies/#{socket.assigns.company}")}
end
```

### Handling Modal-Specific Data (e.g., editing a specific unit)

For modals that edit a specific entity, include the entity ID in the URL:

```elixir
# Opening edit modal for specific unit
def handle_event("edit_unit", %{"unit_id" => unit_id}, socket) do
  {:noreply, push_patch(socket, to: ~p"/companies/#{socket.assigns.company}?modal=unit_edit&unit_id=#{unit_id}")}
end

# In handle_params
defp apply_modal_state(socket, "unit_edit", params) do
  case params["unit_id"] do
    nil -> socket
    unit_id ->
      unit = Enum.find(socket.assigns.company.company_units, &(&1.id == String.to_integer(unit_id)))
      socket
      |> assign(:show_unit_edit, true)
      |> assign(:editing_unit, unit)
  end
end
```

## Files Requiring Changes

### Phase 1: company_live/show.ex (Prototype)
- **Modals**: unit_search, unit_edit, pilot_edit, invite
- **Current handle_params**: Exists but is no-op
- **Estimated changes**: ~40 lines

### Phase 2: company_live/draft.ex
- **Modals**: unit_search, pilot_form, unit_edit
- **Current handle_params**: Exists but is no-op
- **Estimated changes**: ~35 lines

### Phase 3: campaign_live/show.ex
- **Modals**: unit_search, pilot_form, sell_unit
- **Current handle_params**: Missing (needs to be added)
- **Estimated changes**: ~40 lines

### Phase 4: sortie_live/show.ex
- **Modals**: fail_modal
- **Current handle_params**: Missing (needs to be added)
- **Estimated changes**: ~15 lines

## Form Data Preservation

URL params handle modal open/close state, but form data within modals needs separate handling:

### Option A: Component Assigns (Recommended for now)
LiveComponents already preserve their internal state across parent re-renders. Ensure form state is stored in component assigns rather than recreated fresh:

```elixir
# In component update/2
def update(assigns, socket) do
  {:ok,
   socket
   |> assign(assigns)
   |> assign_new(:form, fn -> to_form(%{"email" => "", "role" => "viewer"}) end)}
end
```

The `assign_new` ensures the form isn't reset if it already exists.

### Option B: localStorage + JS Hook (Future enhancement)
For critical form data, a JS hook could save to localStorage on change and restore on reconnect. This is more complex and should only be added if Option A proves insufficient.

## Testing

Each phase should include tests verifying:
1. Modal opens via URL param (e.g., `?modal=invite`)
2. Modal state survives simulated reconnect (disconnect + reconnect LiveView)
3. Browser back button closes modal
4. Entity-specific modals restore the correct entity (e.g., editing correct unit)

Example test:
```elixir
test "modal state survives reconnection", %{conn: conn, user: user} do
  company = company_fixture(user: user, status: "active")

  # Open modal via URL
  {:ok, view, html} = live(conn, ~p"/companies/#{company}?modal=invite")
  assert html =~ "Send Invitation"

  # Simulate reconnect by re-mounting with same URL
  {:ok, view2, html2} = live(conn, ~p"/companies/#{company}?modal=invite")
  assert html2 =~ "Send Invitation"
end
```

## Rollout Plan

1. **Phase 1**: Implement on `company_live/show.ex` as prototype
2. **Test on mobile**: Verify reconnection preserves modal state
3. **Phase 2-4**: Roll out to remaining files if Phase 1 succeeds
4. **Optional**: Extract common helpers if patterns emerge

## References

- [Phoenix LiveView Navigation](https://hexdocs.pm/phoenix_live_view/live-navigation.html)
- [handle_params callback](https://hexdocs.pm/phoenix_live_view/Phoenix.LiveView.html#c:handle_params/3)
