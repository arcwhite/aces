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

## Contributing

If you want to contribute please reach out, or heck, just fork and open a PR. I reserve the right to engage some different governance in the future, but for now it's open season.
