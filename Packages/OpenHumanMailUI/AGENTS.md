# AGENTS.md: OpenHumanMailUI

- AppKit calls `viewWillDisappear` and `viewDidAppear` when a view is only
  hidden (`isHidden`), not just when it leaves the window. The calendar hides
  the mail view, so code that removes a window-wide monitor there, such as the
  KeyRouter's key monitor, first checks that the view left the window.
- A focused control that answers Return itself (an attachment tile) conforms
  to `ReturnKeyOwner`, so the KeyRouter leaves Return to it.
- `⌘⇧.` reaches the app as `⌘>` on US-style layouts. A layout that reports
  `⌘.` instead gets AppKit's `cancelOperation:` (Esc), so bind the shifted
  character.
