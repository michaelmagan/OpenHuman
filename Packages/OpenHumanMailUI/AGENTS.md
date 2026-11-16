# AGENTS.md: OpenHumanMailUI

- AppKit calls `viewWillDisappear` and `viewDidAppear` when a view is only
  hidden (`isHidden`), not just when it leaves the window. The calendar hides
  the mail view, so code that removes a window-wide monitor there, such as the
  KeyRouter's key monitor, first checks that the view left the window.
