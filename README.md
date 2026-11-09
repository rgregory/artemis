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
