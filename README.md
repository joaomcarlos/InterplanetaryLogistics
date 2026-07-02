# Interplanetary Logistics

A Factorio 2.0 Space Age mod that turns local shortages into routed interplanetary cargo transfers.

## Current features

- **Interplanetary Requester Chest** available without a dedicated research unlock.
- Local logistics are preferred; only unresolved requester shortages enter the interplanetary queue.
- Construction alerts are aggregated into destination-specific material requests.
- Requests can be approved, denied, or left to auto-approve after 30 seconds.
- Denied requests remain visible for manual review and are not raised repeatedly.
- A trade-style dashboard lists requests, requester chests, enrolled platforms, and transfer history.
- Source planets are ranked by historical delivery reliability first, with stock coverage as a tie-breaker.
- Only explicitly enrolled platforms with both planets in their existing route are eligible.
- Selected platforms receive temporary source and destination schedule records.
- Isolated platform-hub and landing-pad logistic sections are removed after delivery.

## Usage

1. Craft and place an **Interplanetary Requester Chest**.
2. Configure its requester slots normally and connect it to a logistics network shared with a cargo landing pad.
3. Open the dashboard with the shortcut bar button or `Alt+I`.
4. Enroll the space platforms the network is allowed to commandeer.
5. Ensure each enrolled platform's normal schedule contains the intended source and destination planets.

The mod never replaces a platform's permanent route. It appends request-specific temporary stops and removes those stops once the transfer is complete.
