# Godot MCP Integration - Setup Complete

Successfully integrated Godot MCP with Continuous-Claude!

## What Was Installed

### 1. MCP Server Configuration
- **Global config**: `~/.claude/mcp_config.json` - Godot server added
- **Project config**: `.claude/mcp.json` - Local configuration
- **Connection**: Godot MCP server connects to Godot Editor on port 6400

### 2. Wrapper Scripts (`~/.claude/scripts/`)

| Script | Purpose | Usage |
|--------|---------|-------|
| `godot_scene_info.py` | Get scene hierarchy | `mcp-exec ~/.claude/scripts/godot_scene_info.py` |
| `godot_get_properties.py` | Query node properties | `mcp-exec ~/.claude/scripts/godot_get_properties.py --node "NodeName"` |
| `godot_create_object.py` | Create new nodes | `mcp-exec ~/.claude/scripts/godot_create_object.py --type "Node2D" --name "MyNode"` |
| `godot_delete_object.py` | Delete nodes | `mcp-exec ~/.claude/scripts/godot_delete_object.py --name "NodeName"` |
| `godot_find_objects.py` | Find nodes by name | `mcp-exec ~/.claude/scripts/godot_find_objects.py --name "Player"` |
| `godot_set_property.py` | Set node properties | `mcp-exec ~/.claude/scripts/godot_set_property.py --node "Sprite" --property "visible" --value "true"` |
| `godot_set_transform.py` | Set position/rotation/scale | `mcp-exec ~/.claude/scripts/godot_set_transform.py --name "Player" --position 100 200` |
| `godot_editor_control.py` | Control editor | `mcp-exec ~/.claude/scripts/godot_editor_control.py --command PLAY` |

### 3. Skill Integration
- **Skill**: `~/.claude/skills/godot-mcp/SKILL.md` - Complete reference documentation
- **Auto-activation**: Added to `skill-rules.json` - triggers on Godot-related keywords

## How It Works

**Continuous-Claude Pattern:**
```
User prompt → Skill suggestion → Wrapper script → MCP server → Godot Editor
```

**Example flow:**
1. You say: "Create a sprite at position 100, 200"
2. Hook suggests: `godot-mcp` skill
3. I run: `mcp-exec ~/.claude/scripts/godot_create_object.py --type "Sprite2D" --name "NewSprite" --position 100 200`
4. MCP server connects to Godot on port 6400
5. Godot creates the sprite
6. Result returned to conversation

## Quick Examples

### Get Current Scene Info
```bash
mcp-exec ~/.claude/scripts/godot_scene_info.py
```

### Query Camera2D Properties (Already Tested!)
```bash
mcp-exec ~/.claude/scripts/godot_get_properties.py --node "Camera2D"
```
Returns:
```json
{
  "name": "Camera2D",
  "position": [80.0, 72.0],
  "rotation": 0.0,
  "scale": [1.0, 1.0],
  "visible": true
}
```

### Create a Test Object
```bash
mcp-exec ~/.claude/scripts/godot_create_object.py \
  --type "Sprite2D" \
  --name "TestSprite" \
  --position 400 300
```

### Control the Editor
```bash
# Play scene
mcp-exec ~/.claude/scripts/godot_editor_control.py --command PLAY

# Stop scene
mcp-exec ~/.claude/scripts/godot_editor_control.py --command STOP
```

## Natural Language Usage

Just ask me in plain language! The skill will auto-activate:

- "What's in the current Godot scene?"
- "Create a sprite named Player at position 100, 200"
- "Set the Camera2D zoom to 2.0"
- "Play the scene"
- "Find all nodes named Enemy"
- "Delete the TestObject node"

## Verification

Test the integration:
```bash
# Check MCP server is in config
grep "godot" ~/.claude/mcp_config.json

# Test a simple query
mcp-exec ~/.claude/scripts/godot_scene_info.py

# Verify Godot connection
lsof -i :6400
```

Expected output:
- MCP server connects to Godot
- Returns scene information as JSON
- No errors about missing modules

## Troubleshooting

**"ModuleNotFoundError: No module named 'runtime'"**
- Use `mcp-exec` command, not `python` directly
- Format: `mcp-exec ~/.claude/scripts/godot_*.py`

**"Error connecting to Godot"**
- Verify Godot is running
- Check MCP panel shows "Listening on port 6400"
- Run: `lsof -i :6400` to verify connection

**"Script not found"**
- Use full path: `~/.claude/scripts/godot_*.py`
- Or relative if running from project: `scripts/godot_*.py`

**Skill doesn't auto-activate**
- Restart Claude Code to reload skill-rules.json
- Use explicit keywords: "godot scene", "godot node", "create sprite"

## Important Fix Applied

**Issue**: Godot MCP server had incompatible `FastMCP` initialization
**Fix**: Changed `description=` to `instructions=` in `server.py:line 46`
**Location**: `/Users/drake.thomsen/Documents/godot-projects/Godot-MCP/python/server.py`

## Architecture Notes

**Why wrapper scripts?**
- Continuous-Claude doesn't expose MCP tools directly to Claude's context
- Wrapper scripts keep tokens low (vs loading all tool schemas)
- Scripts provide better error handling and CLI interfaces

**Continuous-Claude vs Official Claude Code**
- Official Claude Code: MCP tools appear in tool palette
- Continuous-Claude: MCP tools called via wrapper scripts + `mcp-exec`
- Benefit: Token efficiency (110 tokens for skill vs 30k+ for all tool schemas)

## Next Steps

You can now:
1. ✅ Query Godot scene state from Claude
2. ✅ Create/modify/delete nodes programmatically
3. ✅ Control the Godot editor (play, stop, save)
4. ✅ Automate game development workflows

**Optional enhancements:**
- Add more specialized scripts for specific game mechanics
- Create workflow skills for common patterns (e.g., "create player character")
- Integrate with TDD workflow for Godot game development

## References

- **Godot MCP**: https://github.com/Dokujaa/Godot-MCP
- **Continuous-Claude**: https://github.com/parcadei/Continuous-Claude
- **Skill docs**: `~/.claude/skills/godot-mcp/SKILL.md`
- **MCP config**: `~/.claude/mcp_config.json`

---

**Status**: ✅ Fully functional - tested with Camera2D query
**Last updated**: 2025-12-26
**Session**: Godot MCP integration setup
