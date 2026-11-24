# Planned and open

What is proposed, open, or not started. Newest thinking at the top of each section.

## Before agents use it

These need the owner, since each changes live configuration on the Mac.

- **Try it once.** Nobody has launched the app yet. Check the menu, the lamp's placement and size, that the lamp's button takes the screen without taking focus, and that Settings opens in front.
- **Add the MCP server for every agent.** For Claude Code, `claude mcp add --scope user` with the helper in the installed app (the README has the command). Other agents need their own entries.
- **Tell agents the rule in `~/dev/AGENTS.md`**, so a session asks for the screen even when it does not think to look at the server's instructions.
- **Join the release poller:** a `[repo mac-tally-lamp]` section in `mac-app-release-poller/config.ini`, then its "Adding a repo" steps. Until then a push to `main` ships nothing.

## Open questions

- **Enforcing it.** Today an agent that does not ask can still take the screen. One way: a Claude Code `PreToolUse` hook on screen-driving tools (Peekaboo, computer use) that asks the app whether this session holds the screen and refuses the call if not. The hook and the MCP server would need to agree on which session is which. Both run under the same agent process, so its process ID may be enough.
- **Noticing the person without a click.** Claim the screen for the person when the keyboard or mouse moves. Agents' synthetic input may look the same as a person's to macOS, so this needs a probe before it is built.
- **A forgotten claim.** The person's claim never lapses. If they walk away holding it, agents wait forever. Maybe it lapses after some minutes with no input.
- **The lamp in agents' screenshots.** Agents that capture the screen will see the lamp in the corner. A window can ask to be left out of captures, but that may also hide it from Screen Sharing, which the owner may use to watch the Mac remotely.
- **Telling a waiting agent sooner.** MCP cannot reach an agent between its calls, so an agent that stopped waiting learns its turn came only when it asks again. Today an agent is only in line while it waits inside the call, which avoids the question.
- **The menu bar menu has no render.** It is a real menu, which cannot be drawn offscreen. A stand-in view, as `meeting-agenda-clock` has for its New Agenda menu, would let pull requests show it.
