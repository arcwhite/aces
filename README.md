# Andy's Aces Accounting

An Elixir/Phoenix application for managing some of the inter-game accounting for Battletech: Aces. This was built to scratch an itch my friend Autumn and I had, where we're co-operatively playing Aces but needed some better tooling for sharing and resolving some of the math after a Sortie, and keeping track of what we have.

It doesn't replace the need for you to buy that game, and I've no intention of adding e.g. the Aces instruction cards or any of the details of the campaigns in those boxed sets.

I'm hosting it at https://aces.arcwhite.org for the time being.

## Clanker Warning
Heads-up - I used this as a bit of an experiment for LLM-based coding. There's a mix of code written by hand and written by clanker. If you're ethically opposed to clanker-coding that's cool, I get you.

I've been pretty blase about leaving files from those experiments in the repo. I'll probably go through and tidy this up at some point.

## Features

- Create a company (400 PV, 2+ pilots, 8+ units, 3145 Merc availability list by default) 
- Create sorties, including recon costs and Omnimech refits
- Manage an in-progress sortie, including marking armor vs. structure damaged and destroyed units and wounded/killed pilots
- Fully calculate post-sortie costs, including repair and rearm costs, pilot SP allocations and MVP
- Manage pilot skills including Edge tokens and abilities
- Manage campaign keywords
- Purchase units and hire pilots between sorties
- Mechs are pulled from the MUL, with a local caching layer to speed things up
- Share ownership of your company with friends, or just give them viewer access
- Phoenix LiveViews mean live-updating views (at least the mid-sortie status view) - everyone can see changes made as they happen
- Various difficulty modifiers from the rulebook can be applied, including the additional PV modifications

## Hosting yourself

Go nuts, if you can figure out how to run a Phoenix app. I'll update these instructions in the near future, but the gist of it is:

- You need Elixir & Erlang on your machine
- You need to use postgres, and configure that in config/dev.exs or config/prod.exs
- `mix ecto.create && mix ecto.migrate`
- `mix phx.server`

## Seed data for local development

`mix seed_dev` spins up a complete, ready-to-play scaffold so you don't have to
click through company creation every time you reset your dev DB. It creates:

- a fixed, confirmed admin user — **`admin@aces.test`** / **`password1234`**
- a mercenary company ("Crimson Lances") with a ~400 PV force of BattleMechs,
  Combat Vehicles, Battle Armor and Conventional Infantry
- a pilot for every non-infantry unit, assigned to its unit
- the company finalized to `active`, with a campaign already started

```
mix seed_master_units --era ilclan --faction mercenary --types battlemech
mix seed_master_units --era ilclan --faction mercenary --types combat_vehicle --force
mix seed_dev
```

`mix seed_dev` needs BattleMech and Combat Vehicle master units cached first
(via `mix seed_master_units`). The Battle Armor and Conventional Infantry it uses
are real MUL data baked into the task and upserted offline, so they need no
separate seeding. The task is **idempotent**: if `admin@aces.test` already
exists it reports and exits without making changes.

## Local smoke testing

`bin/local-smoke` spins up a second copy of the app — pinned to whatever
ref you point it at — without disturbing your working tree or dev DB. It
uses a git worktree at `.smoke-worktree/`, an isolated `aces_smoke`
Postgres database, and (by default) port 4100, so you can browse a
known-good build side-by-side with `mix phx.server`.

```
bin/local-smoke up                  # build & run origin/main
bin/local-smoke up origin/some-pr   # smoke a specific branch / tag / SHA
bin/local-smoke status              # ref, server PID, tailscale state
bin/local-smoke logs                # tail the running server's log
bin/local-smoke down                # stop the server, keep the worktree
bin/local-smoke clean               # stop + remove the worktree
```

If you've got Tailscale and want to poke the running smoke server from
another device:

```
bin/local-smoke serve     # tailscale serve port 4100 over HTTPS
bin/local-smoke unserve   # tear the mapping down
```

Tunables (all optional): `SMOKE_PORT`, `SMOKE_DB_NAME`, `SMOKE_DIR`,
`SMOKE_REF`.

## Contributing

If you want to contribute please reach out, or heck, just fork and open a PR. I reserve the right to engage some different governance in the future, but for now it's open season.
