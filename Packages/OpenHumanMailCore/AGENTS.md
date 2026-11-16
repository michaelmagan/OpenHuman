# AGENTS.md: OpenHumanMailCore

- `CalendarEventStore.isLowPower` reads the Mac's Low Power Mode, which makes
  the store refresh every five minutes instead of every minute. A test that
  steps the clock a minute pins it with `env.calendarEvents.isLowPower = { false }`.
- Numbers, sizes and clock times follow the Mac's locale, and development Macs
  run with region settings such as `en_US@rg=nlzzzz` (5.000, 4,2 MB, 13:00).
  Compare against a value formatted the same way, or pass a fixed `Locale`
  where the API takes one; never hard-code "5,000" or "1:00 PM".
