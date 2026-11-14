# Artemis

A Mac app that shows which of your installed applications run without Apple's
[App Sandbox](https://developer.apple.com/documentation/security/app-sandbox),
ranks them by how exposed they are, and lets you put a seatbelt on the ones
you choose.

A sandboxed app can only touch its own files plus whatever it has asked
permission for. An app without a sandbox can read and change anything you can.
Artemis tells you which is which, and for the unsandboxed ones it can limit
the damage a compromised or misbehaving app could do.

## Run it

You need macOS 14 or later and Xcode 15 or later.

    ./build.sh run

That builds `build/Artemis.app` and opens it. Use `./build.sh install` to put
it in /Applications instead. You can also open `Package.swift` in Xcode and
press Run.

## Using it

The app opens on the list of apps with no sandbox, most exposed first. The
four tiles at the top switch between No sandbox, Managed, Sandboxed and All
applications.

Each row shows:

- Exposure: a five-bar heat meter that fills and warms with the app's
  exposure, plus arrows for its two directions: down if it pulls in outside
  content, up if it acts for an agent (see [Exposure](#exposure)).
- Sandbox: a green shield (sandboxed), an open lock (none), a blue shield
  (managed by Artemis), or a fanned stack of cards, one per sandbox, for apps
  with their own (see [Sandbox layers](#sandbox-layers)).
- Manage: a + button to manage it, a blue shield once managed, an Apple logo
  for apps that are part of macOS (can't be managed), or a dash when it's
  already sandboxed.
- Signature: a seal, green when signed with the hardened runtime, amber for
  ad hoc, red for unsigned, next to where it came from.

A pulsing orange dot next to a name means that app is running without a
sandbox right now.

Double-click an app to open the details sidebar. It is closed by default; the
Details button in the toolbar also toggles it. Right-click an app for Manage,
Reveal in Finder and the copy commands.

The toolbar lets you hide the apps that came with macOS, export the list as a
CSV, and rescan.

## Managed Applications

A managed application is an unsandboxed app that Artemis has written a
sandbox (seatbelt) profile for and can start inside it. The app itself is not
modified.

To manage one, right-click it and choose Manage, or use the Manage button in
the details sidebar. A sheet shows what will always be blocked, the four
choices you can make, and how the protection applies. Confirming writes the
profile and creates a launcher in `~/Applications/Managed Applications`.

Started with its seatbelt, a managed application can't:

- read or change passwords and keys (`~/.ssh`, cloud and command-line
  credentials, other browsers' profiles, 1Password data)
- read Mail, Messages, Contacts or Calendar data
- write to login items, launch agents, shell startup files or other apps
- accept connections from other machines

Four checkboxes adjust this: incoming connections, all network access,
Documents, Desktop, Downloads and iCloud, and the Keychain. The Keychain is
left open by default, because blocking `~/Library/Keychains` makes browsers
and anything else that saves passwords report "Keychain Not Found".
Everything else works as before.
The app can still update itself, and a browser or password manager keeps
access to its own data.

Apps that ship with macOS can't be managed, and apps that are already
sandboxed don't need it.

Some apps sandbox their own helper processes: Chromium, Chrome, Edge, Brave,
Firefox, and anything built on Electron or CEF. macOS won't start one sandbox
inside another (the Activity log shows `forbidden-sandbox-reinit`), so these
only run managed with their own sandbox switched off. Artemis detects them,
warns in the Manage sheet, and won't manage one until you tick "Turn off its
own sandbox". For a web browser this is a bad trade and not recommended: the
browser's own sandbox contains a hostile page far better than a seatbelt.

### Sandbox layers

"No sandbox" describes one process: the app's main executable doesn't opt in
to App Sandbox. Chromium-based apps (Chrome, Edge, Brave, Arc, Electron and
CEF apps) and Firefox are built from many processes, and lock each helper into
its own Seatbelt profile as it starts. Renderers that run web pages get the
strictest profile; the GPU, network and utility services get their own. A
hostile page has to escape the renderer and then exploit a second, more
trusted process before it reaches your files. The main process is the one
left with your full permissions.

Artemis badges these apps in indigo with the number of sandboxed process
kinds it found, for example "4 sandboxes" for Chrome, and shows a Sandbox layers panel in
the details sidebar. While the app is running, the panel asks the kernel about
every process inside the bundle, groups them by role (from Chromium's
`--type=` and `--utility-sub-type=` arguments, or Firefox's process type) and
shows how many of each are sandboxed. It warns when renderers or web content
run unsandboxed, which means the app was started with `--no-sandbox` or its
developer turned sandboxing off (common in older Electron apps). When the app
isn't running, the panel reads the helpers from the bundle instead.

The panel also appears for other apps that ship sandboxed XPC services or
helpers, such as Sparkle's downloader.

### The Managed view

The Managed tile shows one card per managed app:

- its state: Protected now, Not running, or Running unprotected
- what it can't do, and what the current options leave unrestricted
- a live trace of CPU, disk reads, disk writes and blocked attempts over the
  last two minutes, while it is running with its seatbelt
- totals from the log: blocked attempts, runs without the seatbelt, and the
  last protected launch
- Launch Protected, Replace App and Options buttons

Right-click a card to reveal its launcher or to delete it from Managed
Applications. Deleting removes the profile and launcher, not the app.

### When a managed app is running unprotected

The seatbelt only applies when the app is started from Artemis or from its
launcher. Opened any other way, it runs with your full permissions.

Artemis makes that state obvious: the card gets a red banner and border, its
protections are struck through, and the Managed tile turns red with a count.
Quit & Relaunch Protected asks the app to quit and starts it again with its
seatbelt.

The state is read during a scan, so it updates on rescan or after a launch,
not the instant you open something from the Dock.

### Where things are kept

- Profiles: `~/Library/Application Support/Artemis/Profiles`
- Launchers: `~/Applications/Managed Applications`
- Logs: `~/Library/Application Support/Artemis/Logs`

A managed app can't write to any of these.

This relies on `sandbox-exec`, which Apple has marked deprecated but still
ships.

## Replace App

Replace App closes most of the gap left by launching an app the usual way. It
moves the real app to `~/Applications/Managed Applications/Originals` and
puts a launcher with the same name and icon where the app used to be, so the
Dock, Finder and Spotlight all start it with its seatbelt. Restore Original
App puts everything back, and so does removing the app from Managed
Applications.

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
open the details sidebar, to see the reasons. The rating is included in the
CSV export.

## Logging

While Artemis is open it records what each managed application does:

- when it was added, changed, replaced, restored or removed
- each launch with its seatbelt, from Artemis or from its launcher
- when a launch started from Artemis ended, how long it ran and its exit code
- each time it was opened without its seatbelt
- each attempt the seatbelt blocked: the process, what it tried, and the path
  or address, grouped into the same categories the profile uses

Each managed app's card shows the totals. The details sidebar has the recent
events and an Export Log button. Everything is appended to
`~/Library/Application Support/Artemis/Logs/events.jsonl`, one JSON object
per line.

Limits:

- Nothing is recorded while Artemis is closed.
- Blocked attempts are read from the macOS system log, which needs an
  administrator account. If that fails, the Activity box says so.
- macOS drops repeated denials, and Artemis keeps at most one identical
  blocked attempt every five seconds, so the counts are a minimum.
- The live trace covers the app's main process, not helpers it starts, and
  has no network channel.

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

View > Theme switches between six looks. The choice is remembered.

- Standard: the normal macOS appearance.
- Retro: white rounded panels with dark borders and hard drop shadows.
- OS 9: Platinum grey with square, bevelled panels.
- Copland: a cooler blue-grey with rounded corners, deeper bevels and a teal
  accent.
- Things 3: white rounded cards with soft shadows and a blue accent.
- Ink: dark. Blue-black window, slate panels and a cyan accent.

Status colours (red, orange, green, indigo, blue) are deeper than the system
ones in light themes and lighter in dark ones, so badges stay readable.

## How it works

Every signed Mac app carries a list of entitlements. Artemis reads that list
for each app and looks for one entry: `com.apple.security.app-sandbox`. If it
is there and set to true, the app is sandboxed. It is the same thing you would
see from `codesign -d --entitlements - SomeApp.app`.

For apps that are open, Artemis also asks macOS whether the running process is
really in a sandbox. That is how it tells a managed app running with its
seatbelt from one running without it.

A managed app's profile allows everything by default and then denies a fixed
list of locations and operations. Its launcher is a small app that starts the
real one under `sandbox-exec` with that profile.

## What it doesn't catch

- It checks the app itself, not the helper programs tucked inside it. Those
  can be set up differently.
- Some apps, Chrome for one, sandbox parts of themselves when they start
  without declaring it. They show up as unsandboxed here.
- It reads signatures but doesn't verify them, so it won't notice an app that
  has been tampered with.
- It only looks at apps. Command-line tools and background services aren't
  covered.
- A seatbelt blocks files, not keychain items: an app can still use keychain
  entries it was already allowed to use.
- "Block all network access" does not stop DNS lookups, which go through a
  macOS service.

Artemis is not sandboxed itself. It couldn't inspect other apps if it were.
