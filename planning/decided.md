# Decided

What the app does and why. These were chosen when the app was scaffolded on 2026-11-24, from the owner's brief: a lamp in the menu bar with a larger display for when an agent takes the screen, agents reaching it through MCP to see who has the screen and to queue, and the person at the Mac able to claim it. The owner has not reviewed the choices below yet. Moving one to `planned.md` reopens it.

## How agents reach the app

**A stdio MCP server inside the app bundle, one copy per agent session, talking to the app over a Unix socket.** The agent's client starts `mac-tally-lamp-mcp`, which holds one socket connection to the app for the session's life. When the session ends, crash included, the connection closes and the app drops the session's hold and its place in line. A shared HTTP server would need leases and heartbeats to notice a dead agent, and could not tell sessions apart.

**An agent is named after its working folder**, with the worktree after it: `acme-web (wt-03)`. `request_screen` takes a `name` to override it. Two sessions with the same name get their numbers.

**The MCP server starts the app in the background, once per session,** if nothing answers on the socket. If the person quits the app later, that session leaves it quit.

**No MCP SDK.** The server needs `initialize`, `ping`, `tools/list`, `tools/call`, cancellation, and progress, about 400 lines with the tool texts. The recipes allow no dependency but Sparkle unless truly needed.

## The rules

**The person at the Mac always wins.** Their claim never lapses. Taking the screen from an agent drops that agent's hold, and it hears why at its next call. It is not put back in line, so an agent that had finished never gets the screen back without asking.

**An agent's hold lapses only while others wait.** It lasts the hold limit, 10 minutes unless Settings says otherwise, counted from the later of the agent's last `request_screen` and the moment the first waiter arrived. With nobody waiting, an agent keeps the screen until it lets go or its session ends.

**Waiting happens inside the `request_screen` call.** The call waits up to `wait_seconds` (300 by default, 1800 at most) and polls the app once a second. It sends a progress notification every 10 seconds when the client asks for them. An agent that is not inside that call is never in line, so the screen never goes to an agent that is not there to take it. A cancelled call leaves the line.

**It is cooperative.** It tells agents whose turn it is. Nothing stops an agent that does not ask.

## The lamp and the menu bar

**The lamp is a card in the bottom-right corner of the main screen, shown only while an agent has the screen.** It floats above other windows and over full-screen apps, on every Space, and never takes focus, so it cannot pull focus from the app the agent is driving. Its Take the Screen button is meant to work without activating the app, which nobody has tried yet. Bottom-right is a guess at the corner agents click least.

**The menu bar icon is an SF Symbol:** a bulb while the screen is free, a lit bulb while an agent has it, a person while the person at the Mac has it, with the number waiting beside it. A slashed bulb means the socket failed.

## Running

**Claims live in memory only.** A restart clears them, and the MCP servers connect again at their next call.

**Updates wait until nobody has the screen or waits for it**, then install and relaunch. A relaunch would clear the line.

## Experiments

None yet.
