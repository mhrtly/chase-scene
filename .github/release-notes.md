Chase Scene 1.2.0 makes credits easier to read and turns them into a continuous workflow feed.

- Much larger, heavier white lettering, with a thick dark outline and stronger shadow. The fuzzy television texture remains.
- Credits enter one at a time, with an activity line. There is no fixed six-name reel or empty pause between loops.
- New task updates replace only unused credits; visible rows keep moving.
- The controlling AI can continually author fresh fictional roles and pun names through MCP `set_credits`, or put a `// chase-credits:` JSON comment alongside each JS desktop action. No extra tool call is needed for the hook format.
- Local task-aware wordplay fills gaps between AI updates; the app makes no external inference calls.
- Completed row textures are released, and the feed stops when control ends or its signal is lost.

The original `mouse_control_theme.mp3` is still the bundled default. Chewy remains an approximation of the television lettering; custom OTF/TTF fonts are supported.

Install or update:

```sh
curl -fsSL https://raw.githubusercontent.com/mhrtly/chase-scene/main/install.sh | bash
```

Or download **Chase-Scene.zip** below. Universal native app for macOS 13+ (Apple silicon and Intel), ad-hoc signed. For manual downloads, macOS may require **Privacy & Security → Open Anyway** on first launch. See the [README](https://github.com/mhrtly/chase-scene#readme) and [agent guide](https://github.com/mhrtly/chase-scene/blob/main/AGENT_GUIDE.md).
