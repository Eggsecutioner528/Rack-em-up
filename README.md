# Rack 'Em Up / The Hustler (Konami GX765) MiSTer FPGA Core

A MiSTer FPGA port of Konami's 1987 arcade pool game **Rack 'Em Up**, and its Japanese release **The Hustler**, written from scratch in Verilog and SystemVerilog around the real board's chips.

**Version 1.1** (release `releases/RackEmUp_20261010_v1.1.rbf`). Version 1.1 adds a CRT picture rotation for the analog output (through a DDR3 buffer), a Sound Settings page with a stereo option, a DIP Switches page, and a Start 2 button.

One core, one `.mra`: you choose the version in the OSD (**Game Version**):

- Rack 'Em Up (version L)
- The Hustler (Japan version M)
- The Hustler (Japan version J)

This is the "Simple Arcade" build. HDMI and the analog (CRT) output have independent settings in the OSD: the HDMI picture can be rotated, flipped and shaped, and the analog output is either the raw, unrotated 15 kHz raster the arcade board produces (the default) or a rotated, scaled picture for a normally mounted CRT, with picture position and flip options.

---

## About the Game

Rack 'Em Up is a nine ball pool game with a shot view: you line up the shot (aim, English, power) while a player cutscene plays out after each shot. It runs on Konami's **GX765** board, the same chip family as Battlantis (GX777) and Blades of Steel (GX797): a K007342 tilemap chip, a K007420 sprite chip, an HD6309E main CPU, a Z80 sound CPU and two YM3812 FM chips. The game is a vertical monitor game.

---

## Installing

You need the MiSTer SDRAM module (the sprite ROM lives in SDRAM) and your own legally obtained ROM sets in `/media/fat/games/mame/`:

- `rackemup.zip` (MAME name `rackemup`, version L)
- `thehustl.zip` (MAME name `thehustl`, version M, holds only the files that differ from Rack 'Em Up)
- `thehustlj.zip` (MAME name `thehustlj`, version J, holds only the files that differ from Rack 'Em Up)

1. Copy `RackEmUp_20261010_v1.1.rbf` to `/media/fat/_Arcade/cores/`.
2. Copy `RackEmUp.mra` to `/media/fat/_Arcade/`.
3. Put the three zips in `/media/fat/games/mame/`.
4. Start **Rack 'Em Up / The Hustler** from the Arcade menu.

All three ROM sets are loaded together. If you only own one of them the `.mra` can be edited to drop the parts of the others, but the simplest way is to keep all three zips. This repository contains no ROM data.

---

## OSD Options

The menu has **Game Version** at the top, then three sub menus: **Video**, **Sound Settings** and **DIP Switches**.

**Video**

- **HDMI Orientation**: Horizontal (default) rotates the picture so the vertical monitor game stands upright on a normal landscape display, with black bars at the sides. Vertical sends the raw raster, for a display that is itself mounted vertically.
- **Flip Monitor**: turns the HDMI picture 180 degrees. The game's own flip request is ignored on purpose (it toggles at times a real board does not), so only this option flips the picture.
- **Aspect ratio**: Original (the arcade monitor's 4:3, shown as 3:4 once rotated), Pixel Perfect (square pixels), Full Screen.
- **CRT Orientation** (analog output only, independent of the HDMI options): Vertical (raw) is the unrotated 15 kHz raster of the real board, for a vertical arcade monitor or a CRT turned on its side. Horizontal (rotated) rotates and scales the picture through a DDR3 buffer for a normally mounted CRT. The rotated picture follows the same sync and costs one frame of delay.
- **CRT Flip**: turns the CRT picture by 180 degrees in either orientation (counter clockwise instead of clockwise when rotated, upside down when raw). It is the only rotation control.
- **CRT Size** (rotated picture): Auto picks the largest picture that fits the frame, or choose one of 16 sizes from 98x112 to 203x232.
- **CRT V Position** and **CRT H Position**: move the picture by shifting the sync, in both orientations. The two options always mean the direction you see on the CRT in the chosen orientation.

The MiSTer's own menu keeps the same size on the CRT in both orientations.

**Sound Settings** (the first entry of every option is the original sound)

- **FM Chip 1 Volume** and **FM Chip 2 Volume**: 100% (the real board) down to Off.
- **Output**: Mono (original, both chips mixed) or Stereo (chip 1 on the left, chip 2 on the right).

**DIP Switches** (the first entry of every option is the factory default, so a fresh install plays like the real board):

- Balls: 3, 4, 7 or 2
- Time To Aim: 20s, 17s, 15s or 25s (the first shot of a rack gets 5 seconds more)
- Difficulty: Normal, Easy, Difficult, Very Difficult
- Demo Sounds: On or Off
- Cabinet: Upright or Cocktail
- Upright Controls: Single or Dual (not used by The Hustler)
- Flip Screen: Off or On
- Service Mode: Off or On (toggling it restarts the game, because the game only reads the service switch at start up)
- Coin A and Coin B: 1 coin 1 credit by default, with the full 16 entry Konami coinage table and a Free Play or No Coin B entry

**Game Version**: Rack 'Em Up (L), The Hustler (M), The Hustler (J). Changing it restarts the game.

**Controls** are mirrored for the two players: the first controller is player 1 and the second controller is player 2, each with the same layout. The buttons are Shoot, English, Coin, Start and Start 2. Map each controller model once in MiSTer's own button mapping screen (Define joystick buttons); two identical pads share the mapping, and you can press Space on a keyboard to skip a button you do not need (Start 2 is last). With one controller, Start 2 lets you start a two player game; the game alternates the players on the same pad. On the keyboard, 5 and 6 are the coins, 1 and 2 are the starts, and player 2 plays on R F D G with A and S for the buttons.

---

## How This Core Came Together

1. The real board was studied from the schematics and the MAME driver (`battlnts.cpp`, which covers the whole GX765 and GX777 family).
2. The CPU, sound and chip cores were brought in from open projects (see the credits) and checked against MAME frame by frame, using a GPU accelerated pixel comparison of this core's picture against MAME's. That is how a one scanline offset of the sprite layer was found: the pool player cutscenes and the title screen now match MAME pixel for pixel in nearly every frame (a few transition frames differ slightly).
3. The whole tile ROM lives in on chip memory and the sprite ROM is read through an SDRAM cache. This removed the black lines and holes in the picture that earlier builds, which read tiles from SDRAM, could not get rid of.
4. The CRT rotation works through a DDR3 buffer: every pixel is also written rotated into DDR3 and read back line by line at the board's own timing, so the analog sync stays exactly the arcade sync.
5. All three versions are loaded into SDRAM at once; a small copy engine moves the chosen version's program and tile ROM into the on chip memory and restarts the game whenever Game Version changes.

---

## Known Open Issues

- The CRT rotation costs one frame of delay on the analog picture.
- Game speed and sound have not been measured side by side against a real board.
- The game sets the K007342 flip bit in places where it does not in MAME (the cause is not known); the core ignores it.

---

## A Note on Development Process

This core was developed with substantial assistance from **Claude** (Anthropic's AI assistant) and, earlier in the project, Google's **Gemini**, used for RTL implementation, cross checking against the MAME driver and the schematics, simulation and hardware debugging. It is disclosed here so nobody mistakes this for an entirely machine generated core: the direction, the testing on a real MiSTer, every decision about what was acceptable and the final judgement of what works were the author's.

---

## Bibliography and Credits

- **Roger Taylor**: [Nitrobotics/hd6309](https://github.com/Nitrobotics/hd6309), the Hitachi HD6309 native mode CPU core the main program needs.
- **Jose Tejada (jotego)**: the `jtopl` (YM3812 / OPL2) core from the [JTCORES](https://github.com/jotego/jtcores) project, GPL 3, used for both FM chips.
- **Daniel Wallner and the T80 contributors**: the T80 Z80 core used for the sound CPU.
- **Sorgelig and the MiSTer FPGA project**: the platform framework (`sys/`, `hps_io`, `arcade_video`, `screen_rotate`) and the SDRAM controller this core's `sdram.sv` is built on.
- **The MAME project** (mamedev.org): `battlnts.cpp`, `k007342.cpp`, `k007420.cpp` and `konamipt.h` were the authoritative reference for the ROM layout, the chip behaviour and the draw order.
- **Konami**: the original 1987 arcade hardware and games. All game assets and ROM content remain Konami's property.
- The Battlantis and Blades of Steel cores by the same author, whose chip implementations this core shares.

The code is released under the GNU General Public License (see `LICENSE` and the header of each file; the `jt*` cores are GPL 3).
