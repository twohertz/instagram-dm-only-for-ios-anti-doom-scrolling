<img src="IGDM/Assets.xcassets/AppIcon.appiconset/AppIcon.png" width="96" alt="IG DM icon" align="right">

# IG DM — Instagram, messages only

A tiny personal iPhone app that opens Instagram's DM inbox and nothing else. The feed, reels, explore,
stories, search and profile pages are blocked: tapping them does nothing, or bounces you back to the inbox.
Everything you need for messaging works: reading and replying, sending photos, starting new conversations,
logging in with two-factor authentication.

It is a wrapper around Instagram's mobile website, written in Swift and SwiftUI with no third-party
dependencies. It cannot go on the App Store, so you build it yourself in Xcode and install it on your own
phone. Non-technical instructions below; you have never needed to open Xcode before.

## Why

Instagram DMs are useful. The rest of Instagram is designed to keep you scrolling. Deleting the app kills
both. This keeps the useful half.

## What you need

- A Mac with **Xcode 16 or newer** (free, from the Mac App Store; it is a large download).
- An iPhone running **iOS 17 or newer**, and a cable.
- An Apple ID. A free one works: the app then stops opening after 7 days and you re-install it from Xcode
  (plug in, press Run). With a paid Apple Developer account ($99/year) the install lasts a year.

## Install

1. Download this repository (green **Code** button, **Download ZIP**) and unzip it.
2. Double-click `IGDM.xcodeproj`. Xcode opens.
3. Sign it as yours: click the blue **IGDM** at the top of the left-hand file list, then **IGDM** under
   **TARGETS**, then the **Signing & Capabilities** tab.
   - **Team**: pick your name. If the list is empty: Xcode menu, Settings, Accounts, **+**, sign in with
     your Apple ID, then come back and pick it.
   - **Bundle Identifier**: change `com.example.igdm` to something that is yours, for example
     `com.yourname.igdm`. It has to be unique across all Apple developers, so do not keep the example.
4. Plug in the iPhone, unlock it, and tap **Trust** on the phone if it asks.
   If Xcode says the phone needs Developer Mode: on the phone, Settings, Privacy & Security,
   Developer Mode, turn it on, restart.
5. In Xcode's top toolbar, click the device name next to "IGDM" and choose your iPhone (under
   *iOS Devices*, not the simulators).
6. Press **▶ Run** (or ⌘R). The first build takes a minute or two. The app installs and opens on the phone.
7. If the phone shows **Untrusted Developer** when you open the app: Settings, General,
   VPN & Device Management, tap your Apple ID entry, **Trust**.

You can unplug afterwards. To update, or to renew a free-Apple-ID install, repeat steps 4 to 6.

If you would rather not touch the project file, copy `Config/Local.xcconfig.example` to
`Config/Local.xcconfig` and put your team ID and bundle identifier there instead of doing step 3. Git
ignores that file.

## Using it

- First launch shows Instagram's login page. Log in as usual, including any two-factor code. You land on
  the inbox. Right after login the app asks for notification permission.
- The login is remembered. Closing the app or restarting the phone does not log you out. To log out,
  delete the app and install it again.
- Pull down on the page to reload it. If you are ever somehow on a page that is not allowed, pulling down
  brings you back to the inbox, and so does returning to the app from the Home Screen.
- Web links people send you (YouTube, shops, …) open in Safari. Posts, reels and stories shared inside a
  conversation do not open: that is the blocking working. See *Changing the rules* if you want them.

## How the blocking works

Instagram's website is a "single-page app": most taps do not load a new page, they swap the content in
place and quietly rewrite the address bar. So there are two layers, and they use one shared list of rules
(`IGDM/URLPolicy.swift`):

1. **Native (`IGDM/WebView.swift`)**. Every real page load is checked. Allowed pages load; anything else is
   cancelled, and if that would leave the screen blank the app loads the inbox instead. Links to other
   apps (`instagram://`, the App Store) are always refused. Embedded frames are left alone because
   Instagram's login needs them and a frame cannot take over the screen. Images, scripts and data requests
   are not page loads, so Instagram keeps working.
2. **A small script injected into every page (`IGDM/GuardScript.swift`)**. It swallows taps on links to
   blocked pages before Instagram's own code sees them (the bottom bar, usernames, avatars, shared posts),
   and it refuses in-page address changes to blocked pages. A cheap check twice a second catches anything
   else and bounces back.

Allowed pages: everything under `/direct/` (inbox, threads, new message, requests), the login and
two-factor pages, password reset, and Instagram's security-check pages. While you are logged out the front
page is allowed too, because it is only a login form then. Everything else on instagram.com is blocked.

The web view identifies itself exactly like Mobile Safari, so Instagram does not treat it as an in-app
browser. Nothing depends on Instagram's page layout, so redesigns should not break the blocking; at worst a
tap bounces you to the inbox instead of doing nothing.

## Notifications: what to expect

A wrapper app cannot receive Instagram's own push notifications. Instead, iOS wakes the app briefly in the
background now and then (Background App Refresh); the app then asks Instagram for the inbox with your saved
login and posts a notification for each conversation with a new unread message. Tapping it opens that
conversation, and the app icon shows the unread count.

- **iOS decides the timing**: usually every 15 to 60 minutes while you use the phone normally, less often
  overnight or if you rarely open the app, and never if you swipe the app away in the app switcher.
  It is not instant. The official Instagram app will always be faster because Instagram pushes to it.
- Each time you open the app it notes what is already unread, so you are only told about messages that
  arrive afterwards.
- Keep Settings, General, Background App Refresh on, allow notifications, and avoid Low Power Mode.
- If Instagram signs you out, you get one notification saying so.
- The check uses the same inbox request as Instagram's website. If Instagram changes it, the checks
  silently stop; the app itself keeps working.

## Using it next to a screen-time blocker

Blocker apps on iOS (Opal, Brainrot, one sec, and the rest) all use Apple's Screen Time API. When you block
the Instagram app in one of them, many also add a website rule for instagram.com, and that rule reaches
inside other apps' web views, including this one. If IG DM shows a restriction screen while your blocker
is on:

- In the blocker, edit the block list and look at Apple's own picker: it has separate **Apps**, **Categories**
  and **Websites** sections. Block the Instagram **app** on its own, not the whole Social category, and make
  sure instagram.com is not ticked under Websites.
- If the blocker will not separate them, take Instagram out of it and block the Instagram app with Apple's
  own Screen Time instead: Settings, Screen Time, App Limits, Add Limit, Social, Instagram, one minute per
  day. App Limits only ever block apps, never web views.

## Changing the rules

Open `IGDM/URLPolicy.swift`. The list `allowedPathPrefixes` is everything the app may show. For example,
add `"/p/"` and `"/reel/"` to let shared posts and reels open. Set `openExternalLinksInSafari` to `false`
to block outside links instead of opening them in Safari. Then run the app again from Xcode.

## Troubleshooting

- **The app opens on Instagram's front page ("Share everyday moments…") instead of the login form.**
  Instagram answered "too many requests" for its login page, so the app shows the front page, which has
  the same login form. Tap **Log in** there and carry on.
- **Login keeps failing.** Instagram rate-limits new logins from time to time; wait an hour. Check the
  phone's date and time are set automatically.
- **Blank white page.** Pull down to refresh.
- **No notifications.** Check Settings, Notifications, IG DM; Settings, General, Background App Refresh;
  Low Power Mode off; and that you did not swipe the app away. Then wait, iOS is slow to trust a new app.
- **Seeing what the app is doing.** Run it from Xcode with the phone connected and open the console
  (View, Debug Area, Show Debug Area). Every navigation is logged as `ALLOW`, `BLOCK`, `EXTERNAL`,
  `GUARD` or `BOUNCE`, and every inbox check as `CHECK ok: …` or `CHECK failed: …`.

## Privacy

Everything stays on your phone. The app talks only to Instagram, using the same cookies Safari would. There
is no server, no analytics, no crash reporting, and nothing is collected by the author. Your login cookies
live in the app's own sandbox and are deleted with the app.

## Disclaimer

This is an independent personal project, not affiliated with or endorsed by Instagram or Meta. It shows
Instagram's own website in a web view and, for notifications, calls the same inbox request that website
makes, with your own login, for your own account. Instagram may change its site or terms at any time and
the app may stop working; in theory an account could be flagged for unusual access. Use it at your own risk.

## Licence

MIT. See `LICENSE`.
