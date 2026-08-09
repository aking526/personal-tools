# Visual verification checklist

Everything here needs human eyes. Screenshots were unavailable during the build (macOS
Screen Recording permission isn't granted to the terminal), so no agent has ever *seen*
this app run — only confirmed it compiles, passes 43 tests, launches, and stays up.

Run `./run.sh` and walk this list. Anything that fails is a real bug, not a misunderstanding.

## Highest priority

These three are the ones most likely to be wrong, and the most consequential if they are.

- [ ] **Stopping the timer puts the cursor in the new note field without a click.** This is
      the app's core flow. Type immediately after pressing Stop — the characters should land
      in the note. If they don't, the `.onChange`/`@FocusState` wiring in `TimerPanel` is wrong.
- [ ] **The menu bar clock ticks every second while a timer runs, including while its popover
      or another menu is open.** Freezing during menu tracking means the ticker lost its
      `.common` run loop mode.
- [ ] **Start a timer on one project, switch to a different project (or page to another week)
      while it runs, then press Stop.** The app should snap back to the timer's own project and
      current week, show the new session, and focus its note. This path was broken once already.

## Projects and the window

- [ ] Window opens at roughly 880×540, two panes below the top bar.
- [ ] With no projects the bar reads "No projects yet".
- [ ] **New** opens a naming alert; creating "Thesis" makes it the menu title.
- [ ] Creating "Client" switches the title; the menu lists both, checkmark on the selected one.
- [ ] Selecting "Thesis" from the menu switches back.
- [ ] **Delete Thesis…** confirms with "Delete Project and 0 Sessions"; Cancel leaves it alone;
      confirming removes it and selects "Client".
- [ ] Deleting a project **whose timer is currently running** warns that the running time will
      be discarded too.
- [ ] A project name long enough to overflow the switcher truncates rather than pushing
      **New** off the edge.
- [ ] Quit and relaunch — projects survive.

## Stopwatch

- [ ] With no project, Start is disabled and the stopwatch reads `00:00:00` in grey.
- [ ] Pressing Start turns the stopwatch to the accent color, counts up once a second, and the
      button becomes a red **Stop**.
- [ ] **Digits do not jitter or shift horizontally as they change.** This is the
      `.monospacedDigit()` check — its absence is what makes a readout look cheap.
- [ ] ~5 seconds then Stop returns the stopwatch to `00:00:00`; a full minute makes
      "THIS WEEK" read `1m`.
- [ ] Start a timer, **quit without stopping**, relaunch: the stopwatch is still running with
      elapsed time carried across the restart. (This is the crash-safety guarantee.)
- [ ] Typing a space inside a note does **not** start or stop the timer. The bare space-bar
      shortcut was removed for exactly this reason, so this should now be safe — worth
      confirming once.

## Week view

- [ ] Seven rows, `Mon` through `Sun` — Monday first, not Sunday.
- [ ] Today's row label is bolder than the rest.
- [ ] Days with no time show `—`, not `0:00`.
- [ ] A minute of tracked time produces a bar on today's row reading `0:01`.
- [ ] `‹` moves to the previous week: the header becomes a clickable link, rows go to `—`, and
      the right panel's heading changes from "THIS WEEK" to the date range with a `0m` total.
- [ ] Clicking the header link returns to the current week and the data comes back.
- [ ] Paging back across a month boundary shows a label like `Jan 26 – Feb 1`.
- [ ] Dragging the split divider resizes both panes without clipping the totals column.

## Notes

- [ ] With no sessions the panel reads "No sessions this week."
- [ ] Stopping produces a row with the day, an empty note field, and the duration.
- [ ] Typing a note and pressing Enter keeps it; quit and relaunch and it's still there.
- [ ] Escape instead of typing leaves the note blank and the session still recorded.
- [ ] Several sessions list newest-first.
- [ ] Paging to the previous week empties the list; paging back restores it.
- [ ] Start-then-immediately-stop (under a second) adds no row at all.
- [ ] Typing a note while a timer ticks does not drop characters on the once-a-second redraw.
- [ ] Type fast — every character lands. Notes are held locally and written back half a
      second after you stop typing, rather than on every keystroke.
- [ ] Type and then click away, hit Escape, or page to another week without pressing Return:
      the note is saved in all three cases. Quit and relaunch to confirm.

## Manual entry

- [ ] **Log Time** in the notes header opens the editor defaulted to the last hour; Add
      creates the row and puts the cursor in its note.
- [ ] Cancel writes nothing — no row appears, the week total is unchanged.
- [ ] Setting the end at or before the start disables Add and shows the red warning.
- [ ] Page back a week, then **Log Time**: the default dates land in *that* week, not today.
- [ ] Add an entry dated in a different week from the one on screen: the view follows it
      rather than leaving you looking at a week the entry isn't in.
- [ ] The day bar on the left panel grows by the amount you logged.

## Session editor

- [ ] Double-clicking a row opens a popover with start/end pickers and the derived duration.
- [ ] Changing the end time updates Duration immediately, before saving.
- [ ] End before start turns the duration red, shows a warning, and disables Save.
- [ ] Fixing it and pressing Save closes the popover; the row and the week bars both update.
- [ ] Right-click offers **Edit Times…** and **Delete Session**; deleting shrinks the week total.
- [ ] Deleting from inside the editor also closes the popover.
- [ ] Quit and relaunch: edits persisted.

## Menu bar

- [ ] A `timer` icon appears while idle; the main window still opens on launch (the app did
      not become menu-bar-only).
- [ ] Clicking it lists your projects; clicking one starts its timer **and** the main window's
      switcher follows to that project.
- [ ] While running, the popover shows project name, elapsed time, and a red Stop.
- [ ] Stopping from the menu bar adds the session to the main window's notes list.
- [ ] Starting from the menu bar while another project's timer runs stops and records the first.
- [ ] **Quit TimeLogger** quits the app.
- [ ] Menu bar width jitter as the clock rolls over is acceptable to you.

## Appearance

- [ ] Switch System Settings → Appearance between Light and Dark with the app open: text stays
      legible in both, nothing is hardcoded to one.
- [ ] Changing the system accent color recolors the bars, the running stopwatch, and Start.
- [ ] Resizing to minimum clips or overlaps nothing.
- [ ] The empty state (no projects at all) reads sensibly rather than as a bare skeleton.

## Your data file

```
cat ~/Library/Containers/com.alistair.TimeLogger/Data/Library/Application\ Support/TimeLogger/store.json
```

Expect readable pretty-printed JSON with ISO-8601 dates. This is the file to back up — it is
the only copy of your history.

If the app ever reports it can't read this file, it now renames the unreadable copy to
`store.json.corrupt-<uuid>` alongside it rather than overwriting it, and tells you where it
went. Don't delete that file until you've checked whether anything is recoverable from it.
