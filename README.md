[update-readmes]   Mode: rewrite — migrating to template structure...
# linux-over-the-air

[![Built with Ona](https://ona.com/build-with-ona.svg)](https://app.ona.com/#https://github.com/Interested-Deving-1896/linux-over-the-air) [![KDE Eco](https://img.shields.io/badge/KDE%20Eco-certified-brightgreen?logo=kde&logoColor=white&style=flat-square)](https://eco.kde.org/) [![Blue Angel](https://img.shields.io/badge/Blue%20Angel-DE--UZ%20215-0055a4?style=flat-square)](https://www.blauer-engel.de/en/certification/criteria)



<!-- AI:start:what-it-does -->
_Description pending._
<!-- AI:end:what-it-does -->

## Architecture

<!-- AI:start:architecture -->
_Architecture documentation pending._
<!-- AI:end:architecture -->

## Install

<!-- Add installation instructions here. This section is yours — the AI will not modify it. -->

```bash
git clone https://github.com/Interested-Deving-1896/linux-over-the-air.git
cd linux-over-the-air
```

## Usage

<!-- Add usage examples here. This section is yours — the AI will not modify it. -->

## Configuration


Copy `config/system.toml` to `/etc/lota/system.toml` and edit:

```toml
[system]
arch = "amd64"
distro = "debian"
filesystem = "ext4"

[channels]
active = "stable"
server_url = "http://your-server:8080"

[firmware]
policy = "before_os"

[android]
enabled = false   # set true for Android targets
avb_mode = "unlocked"
```

## CI

<!-- AI:start:ci -->
_CI documentation pending._
<!-- AI:end:ci -->

## Mirror chain

<!-- AI:start:mirror-chain -->
This repo is maintained in [`Interested-Deving-1896/linux-over-the-air`](https://github.com/Interested-Deving-1896/linux-over-the-air) and mirrored through:

```
Interested-Deving-1896/linux-over-the-air  ──►  OpenOS-Project-OSP/linux-over-the-air  ──►  OpenOS-Project-Ecosystem-OOC/linux-over-the-air
```

Changes flow downstream automatically via the hourly mirror chain in
[`fork-sync-all`](https://github.com/Interested-Deving-1896/fork-sync-all).
Direct commits to OSP or OOC are detected and opened as PRs back to `Interested-Deving-1896`.
<!-- AI:end:mirror-chain -->

## Contributors

<!-- AI:start:contributors -->
| Contributor | Commits |
|---|---|
| [@Interested-Deving-1896](https://github.com/Interested-Deving-1896) | 198 |
<!-- AI:end:contributors -->

## Origins

<!-- AI:start:origins -->
_Original project — no upstream influences recorded._
<!-- AI:end:origins -->

## Resources

<!-- AI:start:resources -->
_No additional resource files found._
<!-- AI:end:resources -->

## Accessibility

<!-- AI:start:accessibility -->
This repo uses automated accessibility auditing via `check-accessibility.yml`.

Checks include: CODEOWNERS ownership coverage, README screen-reader compatibility,
WCAG 2.1 AA HTML compliance, audio overview (espeak-ng), and Braille output (liblouis).




Run the [Check Accessibility](https://github.com/Interested-Deving-1896/linux-over-the-air/actions/workflows/check-accessibility.yml)
workflow to generate the first report and accessibility artifacts.
See the [W3C Web Content Accessibility Guidelines (WCAG)](https://www.w3.org/WAI/standards-guidelines/wcag/)
for the underlying accessibility reference.
<!-- AI:end:accessibility -->

## License

<!-- AI:start:license -->
[GPL-3.0](https://github.com/Interested-Deving-1896/linux-over-the-air/blob/main/LICENSE) © 2026 [Interested-Deving-1896](https://github.com/Interested-Deving-1896)
<!-- AI:end:license -->
