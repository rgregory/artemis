# Artemis

A small Mac app that shows which of your installed applications run without
Apple's [App Sandbox](https://developer.apple.com/documentation/security/app-sandbox).

A sandboxed app can only touch its own files plus whatever it has asked
permission for. An app without a sandbox can read and change anything you can.
Artemis tells you which is which.

## Run it

You need macOS 14 or later and Xcode 15 or later.

    ./build.sh run

That builds `build/Artemis.app` and opens it. Use `./build.sh install` to put
it in /Applications instead. You can also open `Package.swift` in Xcode and
press Run.

## Using it

The app opens on the list of apps with no sandbox. Click the tiles at the top
to switch between unsandboxed, sandboxed, and everything. Select an app to see
who signed it and what permissions it asks for. An orange dot next to a name
means that app is running unsandboxed right now.

The toolbar lets you hide the apps that came with macOS, rescan, and export
the list as a CSV.

## Managed Applications

Select an app that has no sandbox and choose Manage in the details panel.
Artemis writes a sandbox (seatbelt) profile for it and creates a launcher in
`~/Applications/Managed Applications`. Started from that launcher, or from
the Launch button, a managed application can no longer:

- read or change passwords and keys (`~/.ssh`, cloud credentials, keychain
  files, browser profiles, 1Password data)
- read Mail, Messages, Contacts or Calendar data
- write to login items, launch agents, shell startup files or other apps
- accept connections from other machines

Three checkboxes adjust this: incoming connections, all network access, and
Documents, Desktop, Downloads and iCloud. The Managed tile at the top lists
every app you have added.

The seatbelt only applies when the app is started through Artemis or its
launcher. Opening the original app runs it unprotected. Profiles are kept in
`~/Library/Application Support/Artemis/Profiles`. This relies on
`sandbox-exec`, which Apple has marked deprecated but still ships.

## Replace App

A managed app is only protected when it is started from Artemis or its
launcher. Replace App, in the details sidebar, closes most of that gap. It
moves the real app to `~/Applications/Managed Applications/Originals` and
puts a launcher with the same name and icon where the app used to be, so the
Dock, Finder and Spotlight all start it with its seatbelt. Restore Original
App puts everything back, and so does Stop Managing.

What it does not cover: a file or link that opens in the app can still start
the real app directly. The app's own updater may complain that it has moved.
macOS may ask for permission before Artemis can move an app, and apps
installed by an administrator for all users may refuse to move.

## Exposure

Each app is given an exposure rating, and the list is sorted with the most
exposed first:

- Pulls: it takes in content it does not control, such as web pages,
  messages, downloads or links.
- Agent: it acts on instructions from an AI model, an agent, scripts or
  other automation.
- Pulls + agent: both, which is the highest risk for an app with no sandbox.

The rating comes from the app's declared link types, whether it is built on
a browser engine, whether it can control other apps, and a built-in list of
well-known browsers, chat apps, terminals, editors and AI tools. These are
signals, not proof, and the list is not complete. Hover over the rating, or
open the details sidebar, to see the reasons.

## Logging

While Artemis is open it records what each managed application does:

- when it was added, changed or removed
- each launch with its seatbelt, from Artemis or from its launcher
- when a launch started from Artemis ended, how long it ran and its exit code
- each time it was opened without its seatbelt
- each attempt the seatbelt blocked: the process, what it tried, and the path
  or address, grouped into the same categories the profile uses

Each managed app's card shows the totals. The details sidebar has the recent
events and an Export Log button. Everything is appended to
`~/Library/Application Support/Artemis/Logs/events.jsonl`, one JSON object
per line.

Limits: nothing is recorded while Artemis is closed. Blocked attempts are
read from the macOS system log, which needs an administrator account, and
macOS drops repeats, so the counts are a minimum. Artemis also keeps at most
one identical blocked attempt every five seconds.

## Privacy prompts from macOS

The first time you use Artemis, macOS may show a privacy prompt that names
Artemis, such as "Artemis would like to access data from other apps". You
have to answer it before the action it interrupted can finish. There are two
reasons you will see one.

**Artemis itself.** Artemis reads every installed app's signature, and it
writes profiles and launchers into your home folder. It is not sandboxed and
does not have Full Disk Access, so macOS asks before letting it reach
protected locations. Choose Allow if you want the scan and Managed
Applications to work fully. If you choose Don't Allow, Artemis keeps running
but may show less detail for some apps.

**A managed app you launched from Artemis.** macOS holds the launching app
responsible for what the launched app asks for. When a managed app reaches
for something macOS protects (Documents, Desktop, Downloads, another app's
data, the camera and so on), the prompt can name Artemis, or the app's
launcher, and not the app itself. Answer it as if the managed app were
asking, because it is. Allowing it gives that access to anything Artemis
launches, not only that one app.

The seatbelt and these prompts are separate layers. The seatbelt blocks its
list of locations outright, with no prompt. Everything else is still subject
to macOS privacy prompts as usual.

To review or change an answer later, open System Settings > Privacy &
Security and look for Artemis under the relevant category. To be asked
again from scratch, run:

    tccutil reset All com.rgregory.artemis

## Themes

View > Theme switches between five looks. The choice is remembered.

- Standard: the normal macOS appearance.
- Retro: white panels with dark borders and hard drop shadows.
- OS 9: Platinum grey with bevelled panels.
- Copland: a cooler blue-grey with deeper bevels and a teal accent.
- Things 3: white rounded cards with soft shadows and a blue accent.

## How it works

Every signed Mac app carries a list of entitlements. Artemis reads that list
for each app and looks for one entry: `com.apple.security.app-sandbox`. If it
is there and set to true, the app is sandboxed. It is the same thing you would
see from `codesign -d --entitlements - SomeApp.app`.

For apps that are open, Artemis also asks macOS whether the running process is
really in a sandbox.

## What it doesn't catch

- It checks the app itself, not the helper programs tucked inside it. Those
  can be set up differently.
- Some apps, Chrome for one, sandbox parts of themselves when they start
  without declaring it. They show up as unsandboxed here.
- It reads signatures but doesn't verify them, so it won't notice an app that
  has been tampered with.
- It only looks at apps. Command-line tools and background services aren't
  covered.

Artemis is not sandboxed itself. It couldn't inspect other apps if it were.
