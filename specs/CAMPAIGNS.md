# Campaign

A Campaign represents a collection of Sorties. It represents a Company going on a multi-month deployment to a planet in the Battletech universe, where they're working for a client on a series of interconnected mission, to hopefully make some money and get some salvage.

A Campaign should have a name, which the player can enter.

A Commpany can only be on one Campaign at a time.

A campaign usually has a PV minimum and a warchest minimum. For example, the Scouring Sands campaign box set has rules to allow companies from previous compaigns, but allows that they have up to 400 PV of units, at least 8 units, and a warchest of 400 SP. If the Company doesn't meet any of these requirements, the player is allowed to "tune them up" to meet those requirements. (e.g. if the company has < 400 PV of units, we can add more up to 400 PV, and any remaining PV is still turned into SP at a rate of 1 PV = 40 SP)

During Sorties a Company can gain 'keywords'. These are used in later sorties to apply various effects, representing critical choices the players made (or things they failed to do).

## Campaign Difficulty

Campaigns have a difficulty level, from the following set:
* Rookie (PV limit for all sorties is +20% PV, rewards from sorties are 120%)
* Standard (No changes to sortie limits or rewards)
* Veteran (Sortie PV limits -10%, rewards at 90%)
* Elite (Sortie limits -30%, sortie rewards at 70%)

In addition, if a player is using a pre-existing Company (e.g. one that has been on previous adventures, and might have experienced pilots), there's some additional force modifiers based ont he total SP earned by all named pilots in the company:

* Up to 3000SP - No Change
3001 - 6000SP - Player Force PV (sortie limit) -10%
6001 - 9000SP - Player Force PV -20%
9001 - 12000SP - Player Force PV -30%
12000+SP - Player Force PV -40%

We should express these modifiers to the player within the UI explicitly, so we should track their chosen difficulty level for this campaign.

## Campaign Rounds and Sorties 

During a campaign, players have cmapaign rounds. During a campaign round, companies go on SORTIES. Each sortie is a game of Alpha strike. It has a set-up phase, during which the players chose what recon options they're choosing (if any are available), which units and pilots they're taking (up to some PV maximum for the sortie, which is modified by difficulty levels).

## Starting a Sortie

1. Enter the Sortie name and PV force limit.
2. Choose any Recon options (the player should enter these as a short name or description and an SP cost; this SP cost will be applied at the end of the Sortie)
3. Choose the units and pilots which will go on the Sortie, up to the PV limit, minus any difficulty modifiers.
4. At least one Named Pilot must go on a Sortie as Force Commander.
5. A Sortie cannot begin if the Company has < 2 named Pilots (the player will need to Hire a new Pilot)


Wounded pilots cannot go on a Sortie.

During this setup phase players can choose to modify their Omnimechs, switching an Omnimech variant for any other variant (e.g. a Prime for an A config). If the new variant costs less than or the same as the current variant, in PV, the player must spend Size x 5 SP to make this change. If the new variant costs more than the current variant in PV, the player must spend (the different in PV) * 40SP.

For each sortie, one of the Named Pilots chosen is nominated the Force Commander.

When a Company is on a Sortie, they cannot purchase new units or hire new pilots.

Sorties are identified by a number + name within the campaign.

When the players fail a Sortie, we record that against their campaign, but they're allowed to re-try the same Sortie later. A failed Sortie results in no damage being recorded for units, no income or expenses accruing, no keywords being recorded, and no pilots being wounded or killed (as if it never happened, but there's a "Filed Sortie" on the company's record!)

### After the Sortie

At the end of a Sortie, we should present a form to the players, allowing them to track how the Sortie went. We should ask them:

* Was the sortie a success or failure?
* Were any keywords added, and what are the keywords?
* What Income did the Sortie earn the Company? (Remember to apply Difficulty Adjustments on this number)
* For each unit that went on the Sortie, is it destroyed, salvageable, crippled, damaged internally, armour damaged, or operational? (Units that are destroyed cannot be repaired, but everything else can be repaired, at some SP cost)
* For each unit that went on the Sortie, were their crew wounded or killed? (This applied to both named and 'not named', notional pilots, so it's recorded per-unit)
* What expenses did the company incur? (Any waypoint gains/losses, re-arming costs, wounded/killed pilots, and unit repairs, as follows:)
    - For any unit that had its non-named pilot wounded or killed, you must spend 100 SP to heal them, or replace them with a new crew of locals
    - For any unit with a Named Pilot, if they're wounded, healing them costs 100 SP, and they must sit out the next Sortie. (They remain 'wounded' until the end of the next Sortie)
    - For the purposes of the following rules, Combat Vehicles, Battle Armour and Infantry count as their Size / 2. E.g. a Size 3 Combat Vehicle counts as Size 1.5 for Repair Costs (call this their Repair Size). Battlemechs Repair Size == their Size.
    - Salvageable units cost Repair Size * 100 to repair.
    - Crippled units cost Repair Size * 60 to repair.
    - Internal Structure Damaged units cost Repair Size * 40 to repair.
    - Units that only took armour damage cost Repair Size * 20 SP to repair.
    - All units must be re-armed at a cost of 20SP per unit that went on the Sortie, but units with the ENE special do not count here.

* Earnings is income - these expenses.
* The player then chooses how to distribute the spoilts to their company, if there are any!
    - A portion of the earnings MUST be allocated to named pilots. Each Sortie will tell the player the maximum SP each Named Pilot can claim. If the player can't give the Named Pilots this maximum, they divide the earnings between the number of pilots evently.
    - Named Pilots NEVER take their SP out of the Warchest.
    - Wounded pilots still get their SP reward.
    - Killed pilots do no earn SP.
    - Named Pilots who did not participate in the Sortie earn HALF as much SP as Named Pilots who went on the Sortie.
    - Players then nominate an MVP Pilot for the Sortie. This MVP gets a bonus 20 SP which does not come out of earnings or the warchest. We must keep track of which pilot was nominated MVP for this sortie.

* Spend pilot SP
    - Once pilots earn SP, they must immediately have their SP allocated to the three pools (Skill, Edge Tokens, Edge Abilities).
    - Player sshould do this for all their named pilots who earnt SP (which should be all of them)
    - If, somehow, no pilots earnt SP (e.g. income for the Sortie was 0, or negative?) this step can be skipped.

* Add any leftover income into the Company Warchest
    - Any leftover SP is added to the company's warchest.

* Finally, any wounded pilots from previous Sorties (e.g. those who were wounded and did NOT come on this Sortie) are now recovered.

### In Between Sorties

In Between Sorties, Companies can Hire Pilots (each pilot costs 150 SP, and gets 150 SP to allocated to their Skills, Edge Tokens and Edge Abilities, and must immediately allocate these SP when they're hired)

In between Sorties the company can Purchase new units. Each Campaign will have its own Random Allocation Tables, but for maximum flexibility we'll let the player enter whatever they'r epurchasing. The purchase cost is the unit's PV value * 40 SP.

In between Sorties players can also Sell their units, and receive its PV value * 20 SP back.

## Finishing a Campaign

Players should be able to tell us when a campaign is finished, and its outcome. When a campaign finishes the company is "released" from the Campaign and can go on a different Campaign again.

## Recording events

For all of these events, like starting a sortie, finishing a sortie, units being destroyed or crippled and subsequently repaired, or pilots being wounded, killed, hired, etc. we should be recording events, so that we can show the players a timeline of what happened to their Company on its Campaign(s).