<p align="center">
  <img src="Useful Information/Juno First.png" width="800">
</p>

<h1 align="center">Juno First FPGA Core</h1>

<p align="center">
  Arcade hardware implementation for MiSTer FPGA
</p>

---

## Overview

FPGA implementation of **Juno First (1983)**, originally developed and released by Konami.

This core targets MiSTer FPGA and aims for accurate gameplay behavior, video timing, and sound reproduction.

---

## Game Information

| Field        | Value |
|--------------|--------|
| Title        | Juno First |
| Year         | 1983 |
| Developer    | Konami |
| Genre        | Shoot 'em up |
| Players      | 1–2 alternating |

---

## Controls

Default MiSTer gamepad mapping:

| Input | Action |
|-------|--------|
| D-Pad / Joystick | Move |
| B | Fire |
| A | Warp |
| Right Shoulder | Insert Coin |
| Select | 1 Player Start |
| Start | 2 Player Start |
| Left Shoulder | Pause |

---

## Features

- Arcade-accurate CPU timing
- Sprite priority and layer handling
- High score saving support
- MiSTer-compatible .mra provided
- Verified ROM definitions with checksums

---

## ROM Requirements

ROM files are **not included**.

To use this arcade core, you must provide legally obtained ROM files.

To simplify setup:

- `.mra` files are provided in the **Releases** section.
- The `.mra` specifies all required ROM files along with checksums.
- The ROM `.zip` filename corresponds to the naming convention used by the MAME project.

For setup instructions and environment configuration, refer to:

MiSTer Arcade ROM guide:  
https://github.com/MiSTer-devel/Main_MiSTer/wiki/Arcade-Roms

---

## Installation

1. Copy the core `.rbf` file to your MiSTer `/_Arcade/cores` folder.
2. Copy the `.mra` file to your MiSTer `/_Arcade` folder.
3. Place the appropriate ROM `.zip` files in your `/games/mame` directory.
4. Launch the core from the MiSTer Arcade menu.

---

## Legal Notice

This project contains **no copyrighted game data**.

Users are responsible for obtaining and using ROM files in accordance with applicable laws.

Do not request ROM files in issues or discussions.

---

## Credits

FPGA core development: RodimusFVC  
Original arcade game © Konami (1983)

---