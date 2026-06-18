# Context: Cybus

A mobile app showing live public-transit buses in Cyprus on a map, with arrival information per stop. Inspired by busonmap.com. This document is a glossary of the project's language — no implementation details.

## Glossary

**Vehicle** — A single physical bus currently in service, shown as a moving marker on the map. Its position comes from a live feed. Not to be confused with a Route or a Trip.

**Stop** — A fixed boarding point with a location and name. Users tap a Stop to see upcoming Arrivals.

**Route** — A named bus line (e.g. "30") operated by a Provider. Has one or more paths drawn on the map.

**Trip** — A single scheduled run of a Vehicle along a Route at a specific time. Connects a Vehicle to the Stops it will serve.

**Arrival** — When a Vehicle is expected at a Stop. Real-time-predicted from the official GTFS-realtime TripUpdates feed when available; falls back to the scheduled time from static GTFS when the live feed is silent for that Trip.

**Provider** — A transit operator. Cyprus has seven, each publishing its own static GTFS file: EMEL (Limassol), OSYPA (Pafos), OSEA (Famagusta), NPT (Nicosia), LPT (Larnaca), Intercity, and Pame Express (Park & Ride). All share one combined real-time feed.
