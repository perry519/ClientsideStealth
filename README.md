# ClientsideStealth

PAYDAY 2's poor netcode makes stealth as a client range from frustrating to unplayable, especially with an unstable connection or high ping.

This mod moves suspicion calculations for you and the things affected by your actions from the host to your client.
It also handles some stealth-related interactions locally, without waiting for host confirmation.
This makes playing stealth as a client feel almost like you're the host, playable even at 400ms+ ping.

## Features

- Guards, civs and cameras use positions from your game when detecting you and the things you've interacted with: bags, corpses, hostages, drills, vehicles, broken windows and other props.
- Your client also handles the alert chains you start. If a bag you've thrown alerts a guard, the guard alerts a civilian, and a camera spots that civilian, your client calculates detection for the whole chain.
- ECMs and pocket ECMs instantly jam cameras that detect you or suspicious targets you're responsible for.
- Loot pickups, bag throws and loot securing without delay. Bagging corpses and placing body bag cases or other deployables are also handled clientside.
- Immediate guard intimidation and sleep dart effects.

## Compatibility

- Mixed lobbies supported. As long as the host has CST, clients with the mod get all features. Clients without it can join and keep vanilla detection. All state changes sync automatically between the host and every client type, in both directions.
- Fully compatible with Dynamic Suspicion Indicators v2.0.0+.

## Configuration

Highly configurable, each feature can be toggled individually in the mod options.
