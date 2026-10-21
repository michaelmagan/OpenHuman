<p align="center">
  <img src="docs/images/logo.png" alt="Mail by OpenHuman app icon" width="128" height="128">
</p>

<h1 align="center">OpenHuman</h1>

<p align="center">
  <b>Mail by OpenHuman is a keyboard-first Gmail client for macOS, with AI that runs on your Mac.</b>
</p>

<p align="center">
  <img alt="macOS 26 or later on Apple silicon" src="https://img.shields.io/badge/macOS-26%2B%20%C2%B7%20Apple%20silicon-17614d?style=flat-square&logo=apple&logoColor=white">
  <img alt="Swift 6.4" src="https://img.shields.io/badge/Swift-6.4-F05138?style=flat-square&logo=swift&logoColor=white">
  <a href="LICENSE"><img alt="License: Apache 2.0" src="https://img.shields.io/badge/license-Apache%202.0-3a3a3a?style=flat-square"></a>
  <img alt="Status: early development" src="https://img.shields.io/badge/status-early%20development-c98a1b?style=flat-square">
</p>

<p align="center">
  <a href="#core-features">Core features</a> ·
  <a href="#download-and-install">Download</a> ·
  <a href="#build">Build</a> ·
  <a href="docs/cli/README.md">CLI</a> ·
  <a href="CONTRIBUTING.md">Contributing</a>
</p>

<br>

OpenHuman is an open-source, clean-room clone of Superhuman.

It is Swift-native, runs locally (including its AI features), and is agent-ready, with a command-line interface for external AI agents.

This is a very early alpha, so expect bugs. It runs on Apple silicon Macs with macOS 26.0 or later. Its author has only tested it on macOS 27 on Apple silicon. Features that depend on macOS 27, such as Apple's on-device model, degrade gracefully on macOS 26 and offer alternatives. It is built with Xcode 27 and Swift 6.4.

[Download the signed and notarized release](https://github.com/michaelmagan/OpenHuman/releases/tag/v0.1.0), or build from source. Maintainers can follow the [release guide](docs/release/RELEASE-HOWTO.md) to build, verify and publish a DMG, or let GitHub Actions do it ([automated releases](docs/release/SPARKLE.md)). Homebrew installation will be announced when ready.

<br>

<p align="center">
  <img src="docs/images/inbox.png" alt="The inbox in the Light theme, split into Important, Newsletters and Other, with conversations from invented example senders" width="100%">
  <br>
  <sub>The inbox, split into Important, Newsletters and Other. Every screenshot here shows invented sample data.</sub>
</p>

<table>
  <tr>
    <td width="50%" valign="top">
      <img src="docs/images/reply.png" alt="A reply written inline under the last message, with Send, Send later and Remind me buttons">
      <br>
      <sub>Reply inline, then send now, send later, or get a reminder.</sub>
    </td>
    <td width="50%" valign="top">
      <img src="docs/images/undo-send.png" alt="The inbox in the Dark theme with a Reply sent notice and an Undo button">
      <br>
      <sub>A few seconds to take back a send, in the Dark theme.</sub>
    </td>
  </tr>
  <tr>
    <td width="50%" valign="top">
      <img src="docs/images/search.png" alt="The search field open over the inbox, listing search operators such as from:, to:, subject: and has:attachment">
      <br>
      <sub>Search with Gmail operators such as from: and has:attachment.</sub>
    </td>
    <td width="50%" valign="top">
      <img src="docs/images/calendar.png" alt="A conversation with the calendar sidebar open and a new event drafted from the email">
      <br>
      <sub>Your calendar beside the conversation, with an event drafted from the email.</sub>
    </td>
  </tr>
</table>

## Core features

- **Keyboard first.** Superhuman-style shortcuts, a command palette on ⌘K, and shortcuts you can change.
- **Split inbox.** Important mail apart from the rest, plus your own splits made from any search. “Why is this here?” explains where a conversation landed.
- **Snooze, reminders and send later.** Snooze a conversation, get a reminder if nobody replies, schedule a send, and undo a send while its undo window is open.
- **Search.** Gmail search syntax, related matches from an index built on your Mac, and a Gmail lookup for mail that is not on your Mac yet.
- **AI on your Mac.** Summaries, quick replies, rewrites and Ask AI about your mail. AI runs on your Mac by default, and providers that would send mail off your Mac stay off until you allow them. Every prompt can be read and edited in Settings.
- **Calendar beside your mail.** Your Google Calendar day next to the conversation, events created from an email, and free times inserted into a reply.
- **Less noise.** Mute a conversation, block a sender or a domain, unsubscribe, and clear out old mail with Get me to zero.
- **Safe by design.** Mail never deletes mail permanently, empties Trash or Spam, or changes Gmail settings or filters, and ⌘Z undoes changes; a sent message can be taken back during its undo window.
- **Themes.** Six built-in themes, and [your own](docs/themes.md) as plain JSON files.
- **A CLI for agents.** `openhuman` reads the same local mail, writes drafts for you to review, and never sends. It includes an MCP server. See the [CLI documentation](docs/cli/README.md).

## Download and install

[Download version 0.1.0](https://github.com/michaelmagan/OpenHuman/releases/tag/v0.1.0). This early alpha release is a Developer ID signed, Apple-notarized DMG for Apple silicon Macs running macOS 26.0 or later.

Open the DMG and drag OpenHuman Mail to Applications. On first launch, follow onboarding to create and import your own Google Desktop app OAuth client. No shared Google client is bundled.

### Updates

Releases after 0.1.0 update themselves with [Sparkle](https://sparkle-project.org): use **Check for Updates…** in the app menu, or allow automatic daily checks when Mail asks on its second launch (Settings › General › Updates changes it later). A check sends the app's version to GitHub and nothing about you or your mail, and an update installs only if it is signed with OpenHuman's key. Version 0.1.0 has no updater: install the next release by hand once.

## Opening an unsigned build

macOS may block unsigned builds because they are not notarized by Apple. To open one, try to open the app once. Then open System Settings, click Privacy & Security, and scroll to Security. Click Open Anyway, enter your login password, and click OK. The Open Anyway button stays available for about an hour after you first try to open the app.

Local development builds and CI development artifacts use ad-hoc signing and are not notarized by Apple.

## Build

```sh
Tools/bootstrap.sh
Tools/ci/build-app.sh
open Apps/Mail/Mail.xcodeproj
```

For the CLI:

```sh
cd Packages/OpenHumanCLI
swift build -c release --product openhuman
.build/release/openhuman --help
```

See [Build and test](docs/BUILD.md), [CLI documentation](docs/cli/README.md),
and [Contributing](CONTRIBUTING.md). First-launch onboarding explains how to
create and import your own Google Desktop OAuth client. Mail and settings are stored locally on your Mac. Sign-in credentials are kept in your Keychain.

## Source layout

| Directory | Contents |
| --- | --- |
| `Apps/Mail/` | macOS application, XcodeGen project, and application tests |
| `Packages/` | Shared Swift packages, mail storage and sync, UI, AI, and CLI |
| `Tools/ci/` | Build, test, packaging, and architecture checks |
| `Tools/release/` | Versioning, Developer ID signing, notarization, DMG, release notes and appcast tooling |
| `appcast.xml` | Sparkle update feed, changed only by release pull requests |
| `docs/cli/` | CLI user guide, agent guide, and JSON schema |
| `skills/openhuman-mail/` | Agent integration for the local CLI |

## License

[Apache License 2.0](LICENSE).
