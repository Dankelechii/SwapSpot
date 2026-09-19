# SwapSpot
A UK parking-bay swap app — interactive prototype. List, browse, and swap access to parking bays with other members, with a credits economy, live demand-based pricing, and a Swap Plus tier (currently locked, in beta).

Live demo: https://dankelechii.github.io/SwapSpot/ or https://claude.ai/artifact/VHcFuVYYnFFJmMTa7qcnw4

This is a front-end-only prototype: one self-contained HTML file, no backend, no real accounts. Session state (your name, credits, swap history) is saved in your browser's local storage, so it survives a refresh but won't follow you to another device.

Running it

No build step. Either:

Open index.html directly in a browser, or
Serve it locally: npx serve . (or any static file server) and visit http://localhost:3000, or
Enable GitHub Pages on this repo (Settings → Pages → deploy from the main branch, root folder) and it'll be live at https://<your-username>.github.io/<repo-name>/
We'd like people to stress test this

It's already been through several automated passes — injection/XSS attempts, rapid-fire clicking and double-submit race conditions, boundary values (negative credits, absurd offer counts), corrupted saved-session data, and viewport sizes from a 280px phone to a 2560px desktop. All clean at time of writing (one real XSS bug was found this way and fixed — see SECURITY.md if we add one).

What's genuinely more useful coming from real people than from scripted tests:

Real devices and browsers — Safari on an actual iPhone, older Android Chrome, Firefox — the automated passes only ran headless Chromium
Touch gestures — swipes, pinch-zoom, long-press, double-tap-to-zoom behavior on the map screen
Screen readers / accessibility — VoiceOver, TalkBack, keyboard-only navigation through the whole onboarding flow
Weird real-world input — pasting text with emoji, RTL text, or copy-pasted formatting into the name/email fields
Slow or flaky networks — Google Fonts is loaded from a CDN; see how the app behaves if that's slow or blocked
Multiple tabs open at once — since state is saved to local storage, what happens if you have the app open in two tabs and act in both?
The credits/surge economy — try to find a sequence of actions that leaves the credit balance in a state that doesn't add up
Known limitations (by design, for now)
No real backend — it's a single-player simulation of a multi-user marketplace
Bay "verification photos" are generated illustrations, not real uploads from other users
Swap Plus is intentionally locked (beta messaging only) — see subscribe() / PLUS_ENABLED in the code
Terms & Conditions are a legal draft pending solicitor review, not final
Reporting what you find

Open an issue with steps to reproduce, what you expected, and what actually happened. Screenshots/screen recordings help a lot for anything visual or timing-related.
