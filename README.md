# CodaTV

A Claude Code plugin that streams real-time tool activity, instance status, and session metrics to a CodaTV ESP32-C3 TFT display over USB serial.

## Prerequisites

- **CodaTV device** — ESP32-C3 with 240x240 TFT display running the CodaTV firmware
- **jq** — JSON processor (`brew install jq` on macOS, `apt install jq` on Linux)
- **Claude Code** — installed and running

## Installation

Add the marketplace and install:

```bash
/plugin marketplace add codatv/codatv
/plugin install codatv@codatv
```

Or install from a local clone:

```bash
git clone https://github.com/codatv/codatv.git
claude --plugin-dir /path/to/codatv
```

## Configuration

Create `~/.claude/codatv.local.md` to customize the display:

```markdown
---
# CodaTV Display Settings

max_agents: 4              # Agent rows visible (1-6)
max_instances: 3           # Instance cards visible (1-4)
instance_lines: 2          # Lines per instance (1 or 2)
show_clock: true           # Show clock in header
show_diff: true            # Show git diff stats per instance
show_context_pct: true     # Show context window %
serial_port: ""            # Override auto-detection (e.g. /dev/cu.usbmodem11101)
---
```

All settings are optional. Defaults are used when the file doesn't exist.

## What It Shows

**Header** — "CLAUDE CODE" title, live clock, activity indicator

**Agent List** — Real-time tool invocations:
- Running tools (sorted to top) with instance-colored accent bars
- Completed tools with green checkmark, auto-removed after 10 seconds

**Instance Panel** — One card per Claude Code session:
- Session status: WORK (active) / DONE (waiting for input)
- Context window usage %
- Git diff stats (+lines / -lines)
- Git branch name and model (line 2)

Each session gets a unique color (cyan, magenta, orange, blue, pink, lime, silver, red) so you can tell which tools belong to which instance.

## Serial Protocol

The plugin communicates with the ESP32 via newline-delimited text commands at 115200 baud:

| Command | Format | Description |
|---------|--------|-------------|
| `A` | `A,idx,name,R/I,instance,detail` | Update agent at index |
| `I` | `I,inst,W/A/S,tools,ctx%,+add,-del,label,branch,model` | Update instance card |
| `T` | `T,HH:MM:SS` | Set clock |
| `D` | `D,instance` | Remove instance (session closed) |
| `C` | `C` | Clear all agents and instances |
| `CFG` | `CFG,agents,instances,inst_lines,clock` | Apply display config |

## Port Detection

The plugin auto-detects the ESP32 serial port by scanning:
- macOS: `/dev/cu.usbmodem*`
- Linux: `/dev/ttyUSB*`, `/dev/ttyACM*`

Override with the `serial_port` setting or the `CODATV_PORT` environment variable.

## Troubleshooting

**Display not updating:**
- Check the device is plugged in: `ls /dev/cu.usbmodem*`
- Verify jq is installed: `which jq`
- Restart Claude Code after installing the plugin

**Wrong data showing:**
- Clear state: `rm -f /tmp/codatv-state.json /tmp/codatv-ctx/*`
- Send clear command: `echo "C" > /dev/cu.usbmodem11101`

**Multiple sessions showing same color:**
- Clear state file to reset instance assignments

## License

MIT
