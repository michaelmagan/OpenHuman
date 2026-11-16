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
- A test that reads pixels sets its window's `colorSpace` to `.sRGB` first.
  A snapshot takes the window's space, Display P3 on a MacBook's own screen,
  where sRGB red reads 0.92, 0.2, 0.14, so theme colours stop matching.
- Streamed AI text reaches a view without its trailing whitespace until the
  next chunk or the end of the answer: `PromptScaffoldingFilter` holds it back
  in case a prompt tag follows. A test that waits for a streamed chunk
  compares it trimmed (`SummaryLayoutJumpTests.shown`).
