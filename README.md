<p align="center">
  <img src=".github/icon.png" width="160" alt="the ohrtstagram icon, a calico jack on Instagram's gradient">
</p>

<p align="center">
  <img src="https://img.shields.io/badge/Instagram-418.2.0-E4405F?logo=instagram&logoColor=white" alt="Instagram 418.2.0">
  <img src="https://img.shields.io/badge/iOS-sideloaded%2C%20no%20jailbreak-222?logo=apple&logoColor=white" alt="iOS, sideloaded, no jailbreak">
  <img src="https://img.shields.io/badge/built%20on-Linux-333?logo=linux&logoColor=white" alt="built on Linux">
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-GPL--3.0-blue" alt="License: GPL-3.0"></a>
</p>

# ohrtstagram

Instagram on my phone with the parts I don't want taken out and a few things added. It is the real insta app with a tweak injected into it, built on [SCInsta](https://github.com/SoCuul/SCInsta) and sideloaded with SideStore. No jailbreak.

Pinned to Instagram 418.2.0. Every hook is checked against that version at build time.

## What it does

- **Less junk.** No Reels tab, ads, suggested posts or Meta AI.
- **A feed that ends.** Once you're caught up, it stops.
- **Profile facts.** A line on every profile: account id, account type, whether they follow you.
- **Your history.** Load your Instagram export and that line also shows when you followed each other and how much you've liked, commented, watched and messaged. It keeps counting from there.

Off by default, and not tried on a phone yet:

- **Following feed.** Only people you follow, newest first.
- **Caught up wall.** The feed stops at the last post you saw.
- **DM mode.** Opens on messages, hides the home tab.
- **Time budget.** Covers the app once your minutes for the day are up.
- **Grayscale.**
- **Follow back.** Who you follow that doesn't follow you, with an unfollow button on each.

## Install

You need an iPhone, a free Apple account, and a computer once.

1. **Get the IPA from me.** It isn't in releases because it has Instagram's app in it.
2. **Install [SideStore](https://sidestore.io).** This is the part that needs the computer.
3. **Get the IPA onto your phone.** AirDrop or Files.
4. **Add it.** SideStore, My Apps, the plus, pick the IPA.
5. **Open it and log in.** It sits next to the real Instagram.

On a free Apple account:

- Apps expire after 7 days. SideStore refreshes them. If it won't open, refresh it there.
- Three sideloaded apps max, SideStore included.
- No push notifications.

To update, add the new IPA the same way. Login and settings stay.

## Settings

Hold the three lines at the top right of your profile, or hold four fingers anywhere. Mine are under Focus, SCInsta's are below.

## Your history on a profile

Instagram's app doesn't know when you followed someone. Your data export does.

1. Accounts Center, Your information and permissions, Download your information. Pick JSON.
2. Download the zip on your phone and tap it in Files to unzip it.
3. Settings, Focus, Profiles, "Read in an export". Go into the unzipped folder and tap Open.

Dates and counts only, and nothing leaves the phone. Every count is something you did, not them.

## If it won't open

- Two failed starts in a row and the third opens as plain Instagram. Turn off whatever you changed last.
- If it's worse than that: iPhone Settings, ohrtstagram, "Start with everything off".

## Credits

- [SCInsta](https://github.com/SoCuul/SCInsta) by SoCuul, the tweak this is built on
- [zxPluginsInject](https://github.com/asdfzxcvbn/zxPluginsInject) by asdfzxcvbn, keeps a sideloaded copy logged in
- [InstaSane](https://github.com/n3d1117/InstaSane), where the following feed hook comes from
- [FLEX](https://github.com/FLEXTool/FLEX), the inspector in debug builds

GPL-3.0, like SCInsta. Not affiliated with Instagram or Meta. Modified apps are against Instagram's rules and can get an account restricted.
