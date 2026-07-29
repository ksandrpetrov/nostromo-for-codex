# Nostromo Codex — UI/UX research

## Executive conclusion

Nostromo Codex should behave like a one-handed extension of Codex, not like
gaming-device configuration software. The main product job is:

> Configure the controller once, then work in Codex with confidence without
> moving the right hand away from the pointing device.

The current implementation has the required low-level capabilities, but its
interface exposes implementation concepts, mixes setup with diagnostics, and
allows configuration UI to execute actions with external consequences.

Steve Jobs is treated as a demanding design persona, not as an available
research participant. The resulting design is evaluated against observable
criteria: immediate comprehension, few choices per step, reversible edits,
native macOS behavior, and no surprising external action.

## Evidence

### Facts

- The connected device identifies as Razer Nostromo `1532:0111` through two
  HID interfaces.
- Razer documents 16 programmable keys, a scroll wheel, an eight-way thumb
  pad, an adjustable hand rest, and multiple keymaps.
- The application supports 16 keys, eight D-pad directions, wheel gestures,
  six task slots, Codex commands, skills, plugin prompts, macOS shortcuts,
  profiles, calibration, lighting, and an authenticated ChatGPT bridge.
- No user configuration exists on the inspected machine, so first-run quality
  is a release-blocking path rather than an edge case.
- The existing automated baseline covers protocol and state-machine behavior,
  but physical and live-ChatGPT acceptance is still marked `NOT RUN`.

### Inferences

- The wide palm rest and grouped thumb controls make spatial and motor memory
  more useful than a list of bindings.
- The configuration window will normally be behind ChatGPT, so feedback shown
  only inside that window is not useful during daily work.
- Technical labels such as `bridge`, `usage/cookie`, `plugin://` and numeric
  key codes increase cognitive load without helping the primary workflow.

### Unknowns requiring physical validation

- Which default bindings are most comfortable for the owner's hand.
- Whether diagonal D-pad actions can be triggered reliably during sustained
  daily use.
- Whether a transient HUD or hardware LEDs provide sufficient confirmation in
  the owner's actual multi-display layout.

## Current-state audit

| Severity | Finding | Consequence | Design response |
|---|---|---|---|
| P1 | “Проверить” executes the selected binding | It can send composer contents, approve a request, or run a shortcut | Replace it with an input-only test mode that never dispatches |
| P1 | Restart terminates ChatGPT immediately | Unsaved composer contents can be lost | Require an explicit confirmation sheet |
| P1 | First launch starts HID and may launch ChatGPT before setup | The app changes external state before explaining what it needs | Guided setup; no launch or restart before completion |
| P1 | On-screen control geometry does not closely mirror the physical thumb cluster | A correct configuration can be assigned to the wrong physical control | Build a single accurate interactive hardware twin |
| P2 | Permissions are located under Diagnostics | First-run blockers look like engineering problems | Put readiness and recovery in Connection and onboarding |
| P2 | Profile deletion/import has no preview, Undo, or confirmation | Configuration can be changed accidentally | Confirm destructive edits and retain a recoverable snapshot |
| P2 | Shortcuts are edited as numeric key codes | The control is unusable without implementation knowledge | Capture the actual key combination |
| P2 | Runtime HUD is inside the settings window | Profile and gesture feedback is invisible while working in Codex | Use a nonactivating floating HUD plus persistent menu status |
| P2 | Russian and English copy are mixed | Vocabulary is harder to learn and scan | Use one English product vocabulary throughout |
| P2 | Accessibility metadata is almost absent | VoiceOver and keyboard-only operation cannot be relied upon | Add labels, hints, focus order, non-color status, and Reduce Motion |

## Primary journeys

### First run

1. See the product job and connected-device requirement.
2. Grant Input Monitoring in response to an explicit explanation.
3. Verify the installed ChatGPT build and choose a starter keymap.
4. Press highlighted controls in input-only mode.
5. Review readiness and explicitly start Codex.

### Daily use

1. Glance at the menu bar: Ready, Attention, or Off.
2. Work in ChatGPT using task, composer, mode, and navigation controls.
3. Receive short task/profile/mode feedback without focus leaving ChatGPT.
4. Open the keymap only when a binding needs to change.

### Recovery

1. The menu bar and Connection view name the failed prerequisite.
2. The interface offers one specific next action.
3. Errors that require attention remain available until resolved.
4. Disconnect always releases PTT, pressed actions, and momentary profiles.

## Target information architecture

```text
Menu bar
├── readiness
├── active profile
├── enable controller
├── launch/restart Codex
└── open keymap

Main window
├── Keymap        physical twin + assignment inspector
├── Profiles      create, duplicate, rename, delete
├── Connection    device, permission, ChatGPT, bridge
└── Diagnostics   calibration, raw HID, compatibility override
```

The keymap is the signature experience. All surrounding chrome is native,
quiet, and adaptive. The hardware twin uses carbon keycaps, monospaced control
numbers, a single blue selection/press signal, and status color only when it
has semantic meaning.

## Validation protocol

Run the same task script on the current and redesigned builds:

1. Complete setup from a clean configuration.
2. Identify and change Task 3, Push to talk, Plan mode, and Attach files.
3. Create a profile for another application and record a shortcut.
4. Disconnect/reconnect the device and recover.
5. Restart ChatGPT through Nostromo without losing an unfinished composer.
6. Complete the setup and keymap paths using keyboard-only navigation and
   VoiceOver.

Record completion, wrong-control selections, unintended actions, backtracking,
requests for help, and qualitative comfort. The redesigned build is accepted
only if all scenarios complete without an unintended external action and
without documentation.

