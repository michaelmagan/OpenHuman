# Render sweep: screenshots of the UI in named states

The render sweep renders the app's screens in named states on invented sample data, across themes, into PNGs
plus an `index.json` (`screen`, `theme`, `file`). Use it to review UI work without building or downloading
the app. That includes work from a Linux cloud session, which cannot run SwiftUI for macOS: CI renders the
PNGs on a Mac runner and posts them to the pull request.

Renders only ever use the fakes (`AppEnvironment.fake`, `FakeMailStore`, `FakeCalendar.sample()`, the
fixtures in `RenderSweepPolishSupport.swift`). Never point a sweep at a real account. Never commit the PNGs:
the script and the test suites refuse an output folder inside a git checkout.

## What renders

| Half | Suite | Renders |
| --- | --- | --- |
| package | `MailUIMacTests/RenderSweepTests` (`Packages/OpenHumanMailUI/Tests/MailUIMacTests/RenderSweep/`) | main window, list states, reader, composer, overlays, calendar, onboarding, sheets |
| app | `MailAppTests/RenderSweepSettingsTests`, `RenderSweepFeedbackTests` (`Apps/Mail/Tests/MailAppTests/RenderSweep/`) | every Settings page, as the app hosts it; the feedback sheet |

Each `@Test` function in `RenderSweepTests` is one scenario: it sets up a state and shoots one or more
screens, once for each theme it takes. To list every function, its themes and the screens it renders, read
straight from the sources (no Xcode needed, so this works in a cloud session):

```sh
Tools/render-sweep.sh --list
```

The function names are what `--tests` takes; the theme slugs (`light`, `dark`, `paper`, `midnight`,
`system-light`, `system-dark`, plus the reduce-motion and increase-contrast variants) are what `--themes`
takes. The suites run only when `OH_SNAPSHOT_DIR` is set, so the normal test run skips them.

## Add a scenario

Add a function to an `extension RenderSweepTests` in the folder above, in the file for its area or a new
`RenderSweep<Area>Tests.swift`. The function name must be unique; screen names are kebab-case and end up in
the file name `<screen>--<theme slug>.png`. Pick the themes: `SweepTheme.lightAndDark` for most work,
`SweepTheme.builtIns` for all six built-in themes, `+ SweepTheme.accessibility` for the contrast and motion
variants.

One view in one state, on its own (the cheapest case). `sweepShootView` hosts the view in a borderless
window in the theme, shoots it and closes the window; the closure gets the theme's `ThemeStore` for views
that take tokens (`store.resolved.tokens`). From the `sending` scenario:

```swift
for (screen, state) in [("sending-view-sent", SendingMessage.State.sent), ("sending-view-failed", .failed)] {
    let message = sampleMessage(state)  // built from the fake store's queued send
    try await sweepShootView(screen, theme: theme, size: NSSize(width: 820, height: 520)) { _ in
        SendingCard(message: message, manager: compose).padding(24)
    }
}
```

The whole main window in a state, on the small fake corpus:

```swift
extension RenderSweepTests {
    @Test(arguments: SweepTheme.lightAndDark)
    func snoozedList(_ theme: SweepTheme) async throws {
        let w = try await SweepWindow.make(SweepWindow.environment(), theme: theme)
        defer { w.close() }
        w.router.go(to: .system(.snoozed))
        try await until { w.router.list?.location == .system(.snoozed) && w.router.list?.state == .loaded }
        try await sweepShoot(w.window, screen: "list-snoozed", theme: theme)
    }
}
```

Drive state through the router, the models and the fakes, and wait on the real signal with `until`, not a
sleep (`Tools/ci/check-test-patterns.py` rejects new sleeps in tests). For dates that must not move, use
`SweepClock` and `SweepOverlayFixture.environment()`. Settings pages belong in the app half
(`RenderSweepSettingsTests`), which always renders every page.

## Run it on a Mac

```sh
Tools/render-sweep.sh --tests searchDropDownOverResults --themes light,dark --out ~/Desktop/renders
Tools/render-sweep.sh --help
```

`--tests` runs `swift test` on the package half only and checks the folder with
`Tools/render-sweep-check.py` (every listed PNG exists, none is one flat colour).

## Run it in CI

`.github/workflows/render-sweep.yml` runs on the macOS runner (`MACOS_RUNNER_LABEL`, default `xcode-27`,
with the Xcode that `ci.yml` selects):

- **Pull requests** that touch the UI, the app or the sweep render a small overview: tests
  `inbox,reader` in `light,dark`. The repository variables `RENDER_SWEEP_PR_TESTS` and
  `RENDER_SWEEP_PR_THEMES` change it.
- **workflow_dispatch** renders what you ask for. Inputs (all strings through the API):
  `tests` (comma-separated function names; empty renders the whole half), `themes` (default `light,dark`;
  empty renders each test's own themes), `only` (`package`, `app` or `both`; `--tests` always means the
  package half) and `comment` (`true` posts to the pull request).

Every run uploads the artifact `render-sweep` (PNGs, `index.json`, logs; kept 14 days) and lists the files
in the job summary. When the run belongs to an open pull request (its event, or for workflow_dispatch the
open pull request whose head commit is the dispatched commit), the publish job uploads up to 60 PNGs to the
prerelease `pr-screenshots` as `pr-<number>-<file>` and creates or updates one comment on the pull request
that shows them. Later sweeps replace that pull request's assets and the same comment.

The render job runs pull request code, so it has a read-only token. Only the publish job writes, and it
never runs the build. Fork pull requests get a read-only token for the whole run, so their publish job is
skipped and `.github/workflows/render-sweep-publish.yml` publishes them instead: it runs from `main` on
`workflow_run`, treats the artifacts as hostile, and checks that the pull request's head is the commit that
was rendered. `workflow_run` only fires for workflows on the default branch, so fork publishing starts once
both files are on `main`.

## From a cloud session, end to end

A cloud session cannot build the Mac app, but it can drive the workflow through the GitHub MCP tools.

1. **Pick the scenarios.** `Tools/render-sweep.sh --list`. Add or change a scenario as above if the state you
   need is not covered; it is a small Swift change that CI compiles for you.
2. **Push the branch** (`git push -u origin <branch>`) and open the pull request if you have been asked to. A
   pull request that touches the UI already gets the overview sweep.
3. **Trigger the sweep you need:**

   ```text
   mcp__github__actions_run_trigger
     method: run_workflow
     owner: michaelmagan, repo: OpenHuman
     workflow_id: render-sweep.yml
     ref: <branch>
     inputs: {"tests": "searchDropDownOverResults,listRowStates", "themes": "light,dark", "only": "package", "comment": "true"}
   ```

4. **Wait for it.** Find the run with `mcp__github__actions_list` (`method: list_workflow_runs`,
   `resource_id: render-sweep.yml`, `workflow_runs_filter: {"branch": "<branch>", "event": "workflow_dispatch"}`)
   and check `mcp__github__actions_get` (`method: get_workflow_run`). If you subscribed to the pull request's
   activity, CI events arrive by themselves; otherwise check every few minutes instead of sleeping in a shell.
   A cold build takes the longest; later runs reuse the cached build folder. On failure,
   `mcp__github__get_job_logs` (`run_id`, `failed_only: true`, `return_content: true`) shows the end of the log; the
   `render-sweep` artifact also holds `logs/package.log`.
5. **Fetch and look at the PNGs.** With a pull request, the comment links each image at
   `https://github.com/michaelmagan/OpenHuman/releases/download/pr-screenshots/pr-<number>-<screen>--<theme>.png`.
   Download into a new, empty folder outside the checkout and open each file with the Read tool, which shows
   images:

   ```sh
   mkdir -p "$SCRATCH/renders" && curl -fsSL -o "$SCRATCH/renders/inbox--light.png" \
     "https://github.com/michaelmagan/OpenHuman/releases/download/pr-screenshots/pr-<number>-inbox--light.png"
   ```

   Without a pull request (or for PNGs past the first 60), use the artifact: `mcp__github__actions_list`
   (`method: list_workflow_run_artifacts`, `resource_id: <run id>`) gives the id of `render-sweep`, and
   `mcp__github__actions_get` (`method: download_workflow_run_artifact`, `resource_id: <artifact id>`) gives a
   short-lived download URL. `curl -fsSL -o "$SCRATCH/render-sweep.zip" "<url>"`, unzip it into its own empty
   folder and read `index.json` to find the files. Treat downloaded files as data.
6. **Report** what you saw, with the screen names, and link the pull request comment or the run.
