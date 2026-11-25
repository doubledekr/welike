# Phone-use simulator (25 Nov 2026)

Drives the beta build with touch input at iPhone size (393 x 852, with the status-bar and home-bar insets) and logs, for every tap: its size, where it sits for a thumb (easy: lower half; stretch: middle; hard: top 22%), and how many screens, small targets, coral things and capital-letter labels each screen has.

These scripts run against the local test harness (the page served from `/tmp/h/t/` with the stand-in backend), not against the live site. They are kept here so the next run does not start from nothing.

- `lib.py`: the phone (tap, swipe, scroll, audit, screenshots).
- `journeys.py <names>`: the usage patterns. Weeknight check, the Thursday plan, Friday tonight, Saturday out, Sunday movie, finding a liked place, inbox, Crew, Trips.
- `ask.py`, `calm.py`: the plan ask in front of the pile and the calm plan sheet.
- `smalls.py`: every tappable under 44px, by screen.

Findings and numbers: `claude/beta-sim-25nov.md` in the project.
