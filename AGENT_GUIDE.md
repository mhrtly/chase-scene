# Live credits for computer-use agents

The credits are a live workflow feed. During desktop control, continually author **new** fictional role titles and pun names that describe the specific step you're doing now. Send one to three rows whenever the workflow changes. Don't submit one fixed cast list for an entire task.

## With the MCP server

1. Call `begin_control` before desktop actions.
2. Call `set_credits` between actions with a short, non-sensitive `task` and fresh `credits` rows. Pass your `session_id` when using MCP sessions; omit it for hook-driven control.
3. Renew with `keepalive` during long pauses, and call `end_control` after all pending actions finish.

Example arguments for `set_credits`:

```json
{
  "task": "Place Safari on the left",
  "credits": [
    {"role": "Left wing coordination", "name": "Lefty Wright"},
    {"role": "Head of making room", "name": "Clara Space"}
  ]
}
```

## With existing JS computer-use hooks

Put a **single-line** comment near the beginning of the JavaScript `code` argument. This sends the AI's own current activity and jokes alongside the action, without another tool call:

```js
// chase-credits: {"task":"Place Safari on the left","credits":[{"role":"Left wing coordination","name":"Lefty Wright"}]}
await safariWindow.click(12);
await safariWindow.getAXState();
```

Use new jokes at the next meaningful workflow step. The hook recognizes this explicit comment within the first eight lines; it does not inspect transcripts or treat arbitrary script strings as metadata. Invalid comments fall back to ordinary topic detection and do not block the action. Keep the JSON below 4 KiB, the task below 160 characters, and each role/name below 64 characters. The usual tool permissions still apply.

For tools without a JS `code` input, use MCP `set_credits` or the equivalent local `signal` action. The MCP server's instructions also explain this workflow to connected agents.

## What happens on screen

Large white letters have a thick dark outline and shadow, while keeping the fuzzy television texture. The default is large, centered, full-screen lettering with only the role and name. The user can turn on **Show task topic** to include the current activity above them; agents should keep sending accurate task context whether the line is visible or hidden. New updates replace unused rows, while visible credits keep scrolling; the next new row enters within one row interval, usually a few seconds.

The app supplies local, task-aware wordplay between AI updates. Those gap fillers are templates, not another AI inference call. The app cannot invent an agent's actual intent from an unlabeled click; the controlling AI supplies that context. Music and credits remain tied to a live control signal. Metadata never begins control by itself.
