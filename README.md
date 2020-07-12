# ForceSurvival
Forces survival mode on/off for the current map and/or all future maps.

# Chat/Console Commands
- `.togglesurvival` toggles survival mode for the current map.  
- `.cancelsurvival` cancels an in-progress survival mode vote and disables future votes.  
   - votes can't actually be cancelled, so this will just undo the mode change if the vote passes, and kill any players that respawned. 
- `.survival` shows the current ForceSurvival mode  
- `.survival X` changes ForceSurvival mode and disables survival mode votes.
    - 1 = Force survival mode **ON** for all maps
    - 0 = Force survival mode **OFF** for all maps
    - -1 = Don't force anything (default)

# Installation
1. Download the latest [release](https://github.com/wootguy/ForceSurvival/releases) and extract to `svencoop_addon`
1. Add this to `default_plugins.txt`
```
    "plugin"
    {
        "name" "ForceSurvival"
        "script" "ForceSurvival"
    }
```
