# Mobile-First Design Strategy

## Overview

The Battletech: Aces Campaign Tracker will be designed **mobile-first** with progressive enhancement for desktop/tablet. This ensures the app is usable in the most common scenario: players at the gaming table with their phones.

## Design Philosophy

**Primary Use Case:** Players sitting around a table playing Alpha Strike on physical terrain, using their phones to manage campaign logistics.

**Progressive Enhancement Path:**
1. **Mobile (320px - 767px)**: Full functionality, optimized for touch
2. **Tablet (768px - 1023px)**: Enhanced layouts, side-by-side views
3. **Desktop (1024px+)**: Multi-column layouts, keyboard shortcuts, advanced features

---

## Mobile-First UI Patterns

### Navigation

**Mobile:**
- Bottom navigation bar (thumb-friendly zone)
- Hamburger menu for secondary actions
- Swipe gestures for tabs
- Back button in top-left

**Desktop Enhancement:**
- Persistent sidebar navigation
- Horizontal tab bar
- Breadcrumbs
- Keyboard shortcuts (e.g., `cmd+k` for search)

### Forms

**Mobile:**
- Single-column layouts
- Large touch targets (min 44px × 44px)
- Stepped wizards (one screen per step)
- Bottom-sheet modals for quick actions
- Number steppers (+ / -) instead of text inputs where appropriate

**Desktop Enhancement:**
- Multi-column forms where it makes sense
- Inline validation
- Keyboard navigation (tab order)
- Auto-focus on first field

### Data Display

**Mobile:**
- Card-based layouts (vertical stacking)
- Collapsible sections (accordions)
- Priority information at top
- "Tap to expand" for details
- Pull-to-refresh

**Desktop Enhancement:**
- Table views with sorting/filtering
- Multi-column layouts
- Hover tooltips
- Inline editing

---

## Component Adaptations

### Unit Cards

**Mobile (Card View):**
```
┌─────────────────────────┐
│ Atlas AS7-D             │
│ PV: 48  ★ Pilot: Jane   │
│                         │
│ [Tap for details →]     │
└─────────────────────────┘
```

**Desktop (Rich Card):**
```
┌─────────────────────────────────────┐
│ [Image] Atlas AS7-D        PV: 48   │
│         Assault Mech       Status: ✓│
│         Pilot: Jane Doe    Skill: 3 │
│         [Edit] [Deploy] [Remove]    │
└─────────────────────────────────────┘
```

### Sortie Log Entry

**Mobile (Multi-Step Wizard):**
1. Screen 1: Income (objectives, waypoints)
2. Screen 2: Deployed units damage
3. Screen 3: Expenses summary
4. Screen 4: Pilot SP allocation
5. Screen 5: Review & submit

**Desktop (Single-Page Form):**
- Left column: Income & expenses
- Center column: Deployed units grid
- Right column: Running totals & summary

### Unit Browser

**Mobile:**
- Search bar at top (sticky)
- Filter chips below search
- Infinite scroll list
- Bottom sheet for unit details

**Desktop:**
- Left sidebar: Filters (always visible)
- Main area: Grid view with images
- Right panel: Selected unit details
- Pagination

---

## daisyUI Component Choices

### Mobile-Optimized Components

| Feature | daisyUI Component | Mobile Notes |
|---------|-------------------|--------------|
| Navigation | `btm-nav` | Bottom navigation bar |
| Company list | `card` + `badge` | Vertical stacking |
| Pilots | `card` with `avatar` | Compact pilot cards |
| Unit details | `collapse` | Expandable sections |
| Damage entry | `btn-group` + `badge` | Large touch targets |
| Warchest | `stat` | Prominent display |
| Sortie history | `timeline` | Mobile-friendly chronology |
| Actions | `modal` or `drawer` | Full-screen overlays |
| Filters | `drawer` | Slide-in from bottom |
| Status | `badge` | Colored indicators |
| Loading | `loading` spinner | Centered |

### Responsive Breakpoints

```css
/* Mobile First (default) */
.unit-grid {
  display: flex;
  flex-direction: column;
  gap: 1rem;
}

/* Tablet */
@media (min-width: 768px) {
  .unit-grid {
    display: grid;
    grid-template-columns: repeat(2, 1fr);
  }
}

/* Desktop */
@media (min-width: 1024px) {
  .unit-grid {
    grid-template-columns: repeat(3, 1fr);
  }
}
```

---

## Touch Interactions

### Gestures

- **Swipe left/right**: Navigate between tabs
- **Swipe down**: Refresh (pull-to-refresh)
- **Long press**: Context menu (e.g., on unit card)
- **Pinch zoom**: N/A (not needed for this app)
- **Double tap**: Quick edit

### Touch Targets

**Minimum sizes:**
- Buttons: 44px × 44px
- Form inputs: 48px height
- List items: 56px height
- Icon buttons: 48px × 48px

**Spacing:**
- Minimum gap between interactive elements: 8px
- Comfortable gap: 16px

---

## Key Screens - Mobile Layout

### 1. Company Dashboard

```
┌────────────────────┐
│ ☰  Gray Death Legion│
├────────────────────┤
│                    │
│ Warchest: 5,240 SP │
│ ▲ +500 last sortie │
│                    │
├────────────────────┤
│ Active Campaign    │
│ ┌────────────────┐ │
│ │ Operation Fury │ │
│ │ Sortie 3 of 8  │ │
│ │ [Continue →]   │ │
│ └────────────────┘ │
├────────────────────┤
│ [Roster] [History] │
├────────────────────┤
│ Roster (6 units)   │
│ ┌────────────────┐ │
│ │ Atlas AS7-D    │ │
│ │ Jane | PV: 48  │ │
│ └────────────────┘ │
│ ┌────────────────┐ │
│ │ Timber Wolf    │ │
│ │ John | PV: 52  │ │
│ └────────────────┘ │
│                    │
│ [+ Add Unit]       │
├────────────────────┤
│ [🏠Home] [⚔️Units] │
│ [📊Stats] [👤Menu] │
└────────────────────┘
```

### 2. Sortie Creation (Step 1)

```
┌────────────────────┐
│ ← New Sortie (1/4) │
├────────────────────┤
│ Mission Name       │
│ [              ]   │
│                    │
│ PV Limit           │
│ [-] 150 [+]        │
│                    │
│ Primary Objective  │
│ [              ] SP│
│                    │
│ Secondary Obj.     │
│ [              ] SP│
│                    │
│ ┌────────────────┐ │
│ │ Total: 200 SP  │ │
│ └────────────────┘ │
│                    │
│     [Next: Deploy  │
│      Units →]      │
└────────────────────┘
```

### 3. Post-Battle Processing (Mobile)

```
┌────────────────────┐
│ ← Post-Battle (2/7)│
├────────────────────┤
│ Unit Damage        │
│                    │
│ Atlas AS7-D (Jane) │
│ ┌─────┬─────┬────┐ │
│ │None │Armor│Struc│ │
│ │Crip │Dest │     │ │
│ └─────┴─────┴────┘ │
│ Selected: Armor    │
│                    │
│ Timber Wolf (John) │
│ ┌─────┬─────┬────┐ │
│ │None │Armor│Struc│ │
│ │Crip │Dest │     │ │
│ └─────┴─────┴────┘ │
│ Selected: None     │
│                    │
│ [← Back] [Next →]  │
└────────────────────┘
```

---

## Progressive Web App (PWA) Features

### Why PWA?

Based on Jeff's BattleTech Tools IIC success, implement PWA features:

1. **Offline Capability**: Cache static assets, enable offline viewing
2. **Install to Home Screen**: Native app feel
3. **Fast Loading**: Service worker caching
4. **Background Sync**: Queue actions when offline

### Phoenix LiveView + PWA

LiveView is server-rendered, so we need a hybrid approach:

**Offline Capabilities:**
- Cache MUL unit data locally (IndexedDB)
- Cache company roster for offline viewing
- Queue sortie updates to sync when online

**Implementation:**
- Service worker for static assets
- LocalStorage for draft sortie data
- Phoenix Presence for online/offline indicator

---

## Performance Considerations

### Mobile Performance

**Critical Metrics:**
- First Contentful Paint: < 1.5s
- Time to Interactive: < 3s
- Lighthouse Score: > 90

**Optimizations:**
- Lazy load images
- Virtual scrolling for long lists (e.g., 1000+ units)
- Debounce search inputs
- Optimize LiveView payloads (only send diffs)
- Use `phx-update="append"` for lists

### Data Loading

**Mobile:**
- Load 10 items initially
- Infinite scroll loads 10 more
- Show skeleton loaders

**Desktop:**
- Load 50 items initially
- Pagination
- Instant search (debounced)

---

## Accessibility

### Touch Accessibility

- Large touch targets (44px+)
- Clear focus states
- Error messages above inputs (visible on mobile keyboards)
- Skip links
- Semantic HTML

### Screen Reader Support

- Proper ARIA labels
- Live regions for dynamic updates
- Announced state changes

---

## Typography & Spacing

### Mobile Typography

```css
/* Base font size: 16px (never smaller for body text) */
body { font-size: 16px; }

/* Headers */
h1 { font-size: 1.75rem; }  /* 28px */
h2 { font-size: 1.5rem; }   /* 24px */
h3 { font-size: 1.25rem; }  /* 20px */

/* Important numbers (PV, SP) */
.stat-value { font-size: 2rem; }  /* 32px */

/* Small text (never below 14px) */
.text-sm { font-size: 0.875rem; }  /* 14px */
```

### Spacing Scale

```css
/* Mobile-first spacing (based on 4px grid) */
--space-1: 0.25rem;  /* 4px */
--space-2: 0.5rem;   /* 8px */
--space-3: 0.75rem;  /* 12px */
--space-4: 1rem;     /* 16px - default gap */
--space-6: 1.5rem;   /* 24px - section spacing */
--space-8: 2rem;     /* 32px - major sections */
```

---

## Mobile-Specific Features

### Quick Actions

**Floating Action Button (FAB):**
- Position: bottom-right (not blocking navigation)
- Primary action per screen:
  - Company dashboard: "New Sortie"
  - Unit browser: "Add to Roster"
  - Pilot list: "New Pilot"

### Contextual Actions

**Long-press menus:**
- Unit card → Edit, Remove, Deploy, View History
- Pilot card → Edit, Assign, Wounds, View Stats
- Sortie → View, Edit, Delete

### Notifications

**Use browser notifications for:**
- Sortie completed (when other players finalize)
- Warchest updated
- Pilot wounded/killed

---

## Testing Strategy

### Device Testing

**Must test on:**
- iPhone SE (small screen - 375px)
- iPhone 14 Pro (standard - 393px)
- iPad (tablet - 768px)
- Android (Samsung Galaxy - 360px)
- Desktop (1920px)

### Touch Testing

- Test all buttons with thumb (one-handed use)
- Ensure no accidental touches (spacing)
- Test forms with mobile keyboard open
- Test scrolling with finger

### Performance Testing

- Test on slow 3G
- Test with CPU throttling
- Test LiveView reconnection
- Test offline mode

---

## Implementation Notes

### LiveView Mobile Patterns

```elixir
# In LiveView mount, detect mobile
def mount(_params, _session, socket) do
  is_mobile = get_connect_params(socket)["viewport"] == "mobile"

  {:ok, assign(socket, mobile: is_mobile)}
end
```

```heex
<!-- Conditional rendering -->
<div class={if @mobile, do: "mobile-layout", else: "desktop-layout"}>
  <!-- Content -->
</div>
```

### Responsive Components

```heex
<!-- Mobile: Bottom sheet, Desktop: Modal -->
<.modal :if={!@mobile} id="unit-details">
  <.unit_details unit={@selected_unit} />
</.modal>

<.drawer :if={@mobile} id="unit-details" position="bottom">
  <.unit_details unit={@selected_unit} />
</.drawer>
```

---

## Key Takeaways

1. **Design for thumbs first** - all actions reachable one-handed
2. **Progressive disclosure** - hide complexity, reveal on demand
3. **Touch-friendly** - 44px minimum, generous spacing
4. **Fast loading** - optimize for 3G networks
5. **Offline-capable** - PWA features for table-side use
6. **Responsive** - enhance for larger screens, don't rebuild
7. **Test on real devices** - emulators miss touch nuances

---

## Next Steps

1. Create mobile wireframes for key flows
2. Test navigation patterns with users
3. Prototype multi-step wizards
4. Implement service worker for offline
5. Performance budget: < 3s TTI on mobile
