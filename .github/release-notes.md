Chase Scene 1.1.0 restores the original chase soundtrack and adds optional rolling credits.

- Bundles `mouse_control_theme.mp3` as the default audio. Hot Potato Hustle remains an optional alternative.
- Adds independent music/credits toggles, full-screen or corner credits, a silent preview, and custom OTF/TTF fonts.
- Uses fuzzy TV rendering with fictional task-related role titles and pun names. Chewy is the included approximation; the exact Benny Hill font is not verified.
- Adds task/credits metadata and `set_credits` to the portable MCP server.
- Stops music and credits on end, interruption, lost signal or restart. An orange warning preserves an unknown state; late hook renewals cannot restart playback.
- Makes software mouse detection opt-in for new installs. Ordinary utilities can trigger that heuristic; hooks/MCP are recommended.

Install the latest release:

```sh
curl -fsSL https://raw.githubusercontent.com/mhrtly/chase-scene/main/install.sh | bash
```

Or download **Chase-Scene.zip**, unzip it and move **Chase Scene.app** to Applications. Open the app, connect your AI in the welcome window or Settings, and optionally enable Rolling credits. Codex requires reviewing new hooks with `/hooks`.

Universal app for macOS 13+ (Apple silicon and Intel), ad-hoc signed. For a manually downloaded copy, macOS may require **System Settings → Privacy & Security → Open Anyway** on first launch. See the [README](https://github.com/mhrtly/chase-scene#readme) for setup and separate media licensing.
