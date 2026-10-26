# Design notes

Source: approved canvas "Mac DB Client Concept" — https://claude.ai/artifact/QGiA7Q1jrViPwYCH61thLW
Snapshots of each artboard live in `design/project/*.dc.html` (HTML mockups; reference only, not shipped).

Artboards → app screens
| File | Screen | Phase |
|---|---|---|
| Main.dc.html | Connection window — table data, tabs, sidebar, inline edits, row inspector | 3–4 |
| Connections.dc.html | Saved connections launcher | 3 |
| Query.dc.html | Query editor, history/snippets, autocomplete, multi-result tabs | 5 |
| Filters.dc.html | Column filter popover, chips, saved filters, Show as SQL | 4 |
| Export.dc.html | Export dialog (mysqldump over SSH) | 7 |
| Console.dc.html | SQL console + SSH terminal | 7 |

## Tokens (light; derive dark variants as semantic NSColor/asset colors)
- Fonts: mockups use Inter / JetBrains Mono as web stand-ins → native app uses **SF Pro** (system) and **SF Mono** (`.monospaced`).
- Accent `#2459D6` (hover `#1A43A8`); selected-row/active-item bg `#E3EBFB` text `#173E99`; selected grid row `#EEF3FD`.
- Text `#1C1D22`, secondary `#5C5F6A`, tertiary `#8A8D98`; chrome bg `#F6F6F8`, sidebar `#FAFAFB`, separators `#E2E3E8`, grid row rule `#F0F1F4`.
- Tags: Production `#C4314B` (white "PROD" badge, 11pt semibold, 0.04em tracking), Staging `#E0A030`, Local `#2E9E5B`.
- Query/SQL keyword purple `#6A3FC2`; string `#1F7A4D`; function `#0F6E8C`; number `#B05A00`; comment `#8A8D98`.
- Pending edit: cell bg `#FFF4D6` + 3px leading bar `#D48806`; "N unsaved edits · Review" pill bg `#FFF7E6` border `#E8B04A` text `#7A4B00`.
- Status pill (e.g. publish) bg `#E2F4E8` text `#1F6B3F`; connected dot `#2E9E5B`.
- Radii: window 12, cards 10, controls 8, small 6, badges 4; filter chips fully rounded.
- Tab dot: table = accent, query = purple, console = text color.
