# Interplanetary Logistics

A Factorio 2.0 Space Age mod that turns local shortages into routed interplanetary cargo transfers.

## Current features

- **Interplanetary Requester Chest** available without a dedicated research unlock.
- Local logistics are preferred; only unresolved requester shortages enter the interplanetary queue.
- Construction alerts are aggregated into destination-specific material requests.
- Requests can be approved, denied, or left to auto-approve after 30 seconds.
- Denied requests remain visible for manual review and are not raised repeatedly.
- A trade-style dashboard lists requests, requester chests, enrolled platforms, and transfer history.
- The first dashboard tab is a live fleet monitor split into alphabetized Delivery Fleet and Other Platforms views, with working, idle, returning, paused, and stuck states plus ETAs.
- Requests are ordered by priority and workflow state, with separate Active and Needs Attention views; Destinations and History use dedicated dense lists.
- Every leaf list owns one native scrollbar, with summaries and column headers fixed outside the scrolling content.
- A cohesive native style system provides summary cards, fixed table headers, consistent dense rows, compact controls, attention treatments, muted supporting text, and purposeful empty states.
- Dashboard dimensions and column density adapt to the player's display resolution and UI scale.
- Source stock is reserved per transfer so concurrent requests cannot claim the same surplus.
- Requests have low, normal, and high dispatch priorities.
- Source planets are ranked by historical reliability and stock coverage; eligible ships are ranked by route pinning and earliest arrival.
- Only explicitly enrolled platforms with both planets in their existing route are eligible.
- A platform can be pinned as the preferred ship for every source/destination pair in its permanent route.
- Pickup stops can require a configurable circuit-ready signal before departure.
- Selected platforms receive temporary source and destination schedule records.
- Existing onboard cargo is preserved as return cargo while only the requested amount is unloaded.
- Isolated platform-hub and landing-pad logistic sections, reservations, and temporary stops are removed after delivery or failure.

## Usage

1. Craft and place an **Interplanetary Requester Chest**.
2. Configure its requester slots normally and connect it to a logistics network shared with a cargo landing pad.
3. Open the dashboard with the shortcut bar button or `Alt+I`.
4. Enroll the space platforms the network is allowed to commandeer.
5. Ensure each enrolled platform's normal schedule contains the intended source and destination planets.
6. Optionally pin preferred ships, enable their ready signal, and adjust request priority from the dashboard.

The mod never replaces a platform's permanent route. It appends request-specific temporary stops and removes those stops once the transfer is complete.
