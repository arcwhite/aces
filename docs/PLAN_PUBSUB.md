# Real-time Company Updates with PubSub

## Overview

This document outlines the implementation plan for adding real-time cross-user updates to company views (show and draft) using Phoenix PubSub while maintaining proper authorization security.

## Current State

- Company views use `:noreply` for form actions
- Changes only update the current user's view
- No cross-user synchronization of company data updates

## Goals

- Live-update company data (units, pilots, stats) across all authorized viewers
- Maintain role-based security (owner/editor/viewer permissions)
- Updates should work for both `/companies/:id` (show) and `/companies/:id/draft` views

## Implementation Plan

### 1. PubSub Infrastructure

Phoenix PubSub is already configured in `lib/aces/application.ex:14`:
```elixir
{Phoenix.PubSub, name: Aces.PubSub}
```

### 2. Broadcast Strategy

#### Topics
- Use topic pattern: `"company:#{company.id}"`
- One topic per company for all update types

#### Message Format
```elixir
{:company_updated, company_id, updated_company}
```

#### Broadcast Locations
Add broadcasts after successful operations in the `Companies` context:
- `purchase_unit_for_company/2`
- `finalize_company/1` 
- Pilot creation/updates/deletion
- Unit removal operations
- Company settings changes

```elixir
# Example broadcast in Companies context
def purchase_unit_for_company(company, mul_id) do
  case do_purchase_unit(company, mul_id) do
    {:ok, company_unit} ->
      updated_company = get_company_with_stats!(company.id)
      Phoenix.PubSub.broadcast(Aces.PubSub, "company:#{company.id}", 
        {:company_updated, company.id, updated_company})
      {:ok, company_unit}
    error -> error
  end
end
```

### 3. LiveView Subscriptions

#### Secure Subscription in mount/3
```elixir
def mount(%{"id" => id}, _session, socket) do
  company = Companies.get_company_with_stats!(id)
  user = socket.assigns.current_scope.user

  if Authorization.can?(:view_company, user, company) do
    # Only subscribe if user can view this company
    Phoenix.PubSub.subscribe(Aces.PubSub, "company:#{company.id}")
    
    {:ok,
     socket
     |> assign(:company, company)
     |> assign(:page_title, company.name)
     # ... other assigns
    }
  else
    {:ok,
     socket
     |> put_flash(:error, "You don't have permission to view this company")
     |> redirect(to: ~p"/companies")}
  end
end
```

#### Handle Broadcast Messages
Add to both `show.ex` and `draft.ex`:

```elixir
def handle_info({:company_updated, company_id, updated_company}, socket) do
  user = socket.assigns.current_scope.user
  
  # Verify user still has access and this is the right company
  if socket.assigns.company.id == company_id and 
     Authorization.can?(:view_company, user, updated_company) do
    {:noreply, assign(socket, :company, updated_company)}
  else
    # User lost access - redirect them away
    {:noreply, 
     socket
     |> put_flash(:error, "You no longer have access to this company")
     |> redirect(to: ~p"/companies")}
  end
end
```

### 4. Security Considerations

#### Two-Layer Defense Strategy

**Primary Defense: Authorization Check on Subscribe**
- Only subscribe to PubSub topics if user has `:view_company` permission
- Prevents unauthorized users from receiving any updates

**Secondary Defense: Re-Authorization on Message Receipt**
- Verify permissions on each broadcast message
- Handles edge cases where user permissions change during session
- Immediately disconnects users who lose access

#### Security Benefits
- Unauthorized users cannot subscribe to company updates
- Permission changes (e.g., owner removes viewer) enforced in real-time
- Role-based access control maintained throughout session
- No sensitive data leaked through PubSub channels

### 5. Files to Modify

#### Context Layer
- `lib/aces/companies.ex` - Add broadcasts after successful operations

#### LiveView Layer
- `lib/aces_web/live/company_live/show.ex` - Add subscription and message handling
- `lib/aces_web/live/company_live/draft.ex` - Add subscription and message handling

### 6. Update Events to Broadcast

#### Company Data Changes
- Unit additions (`select_unit` event)
- Unit removals (when implemented)
- Pilot hiring (`hire_pilot` completion)
- Pilot updates/removal (when implemented)
- Company finalization (`finalize_company`)

#### Stats Updates
All changes that affect `company.stats`:
- PV budget changes
- Unit count changes
- Pilot count changes
- Warchest balance changes

### 7. Testing Considerations

- Multi-user scenarios with different permission levels
- Permission revocation during active sessions
- Network disconnection/reconnection scenarios
- High-frequency update scenarios

## Implementation Notes

- The current `handle_info/2` patterns in both LiveViews already handle component messages well, making this addition straightforward
- Existing authorization patterns in `Authorization.can?/3` provide the security foundation needed
- PubSub messages should include full updated company data to avoid race conditions
- Consider rate limiting broadcasts for high-frequency operations if needed

## Future Enhancements

- Granular update types (e.g., `:unit_added`, `:pilot_hired`) for more specific UI updates
- Presence tracking to show who else is viewing/editing a company
- Operational event logging for audit trails