# Let's Together (formerly WeLike)

A two-person swipe app for picking movies, dinner, activities and local events. Each person swipes the same deck on their own phone; cards you both said yes to become matches.

- `index.html` – the whole app (installable on iPhone via Share → Add to Home Screen)
- `sw.js` – service worker that shows nudges as push notifications
- `manifest.webmanifest`, `icon-*.png` – home-screen install metadata

Backend: Supabase project `welike` (database functions, a nightly movie-catalog sync from Watchmode, and a push "nudge" function). No API secrets live in this repo; the Supabase key in `index.html` is the publishable client key.

Streaming data powered by Watchmode.com.
