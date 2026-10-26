//============================================================================
//
//  controllers.sv - shared MiSTer input library (fleet master copy; copy unchanged, md5-check before overwrite)
//  Copyright (C) 2026 Rodimus
//
//  Combined from the fleet's own input logic (audit 2026-10-24). Each module is self-contained; a core
//  instantiates only what its games need and configures it per game by parameters / MRA bytes / OSD bits.
//
//    ctl_keyboard      PS/2 keyboard -> MAME default keys (13 keys) + a per-core extra-key table
//    ctl_mouse         hps_io ps2_mouse -> event strobe, signed dx (right +) / dy (down +), buttons
//    ctl_tick          frame strobe (vblank rising edge) or divider strobe; both stop while paused
//    ctl_joy4way       4-way restriction, most recently pressed direction wins
//    ctl_stick_dirs    analog stick -> {U, D, L, R} (per-axis threshold = 8-way, or dominant axis = 4-way)
//    ctl_coin_impulse  MAME PORT_IMPULSE(n): a coin press held for exactly n frames from the next vblank
//    ctl_toggle        MAME PORT_TOGGLE: flips on each press (Rack Test, gear shifters)
//    ctl_ids           common control-id vector 0-35 for the MRA input map (pads never linked)
//    ctl_port_map      MRA input map -> game input ports (idle level ^ control, DIP bits, analog overlay)
//    ctl_quad_decoder  quadrature A/B (SNAC trackball) -> count strobe + direction
//    ctl_trackball     2-axis relative counter: trackball / dial / spinner (mouse, spinner, SNAC, stick, D-pad)
//    ctl_paddle        absolute paddle position in [PMIN, PMAX] (paddle, spinner, mouse, stick, D-pad)
//    ctl_dial_mame     MAME IPT_DIAL / IPT_TRACKBALL counter with MAME sensitivity / key delta / wheel mode
//    ctl_ad_stick      MAME IPT_AD_STICK absolute axis (rest / min / max, D-pad ramp with autocentre)
//    ctl_steer         steering counter slewed one count per tick (absolute wheel / paddle, relative spinner)
//    ctl_pedal         accelerator / brake level: digital ramp per frame or one analog stick axis
//    ctl_gun_cursor    light-gun crosshair moved by mouse / stick / D-pad, clamped to the picture
//
//  Conventions: directions are {U, D, L, R}. hps_io joystick bits: 0 R, 1 L, 2 D, 3 U, 4-7 Btn 1-4, 8 Coin,
//  9 Start 1P, 10 Start 2P, 11 Pause, 12-13 Btn 5-6. Analog sticks are {Y, X}, signed, up / left negative.
//  Rules: pads are never linked (player 2's Start = Start 2P only); a user's spelled-out layout is final.
//
//  v2 (2026-10-25). Backward compatible: a v1 instantiation behaves bit-identically. New behaviour comes only from new
//  parameters (defaults = v1) and new ports declared tri0 (an unconnected tri0 input reads 0 = v1).
//    ctl_keyboard   STD_EXT (extended-bit rule for the 13 keys), extra-key table NX / NXO / XKEYS / XINIT -> kbx, pause
//    ctl_port_map   BASE_MODE 1 / 2: per-port DIP byte select (port_sel) and per-bit DIP bit map (dip_bit) from dip_bytes
//    ctl_ids        BTN56 = 0 leaves ids 32-35 at 0
//    ctl_toggle     pause input; ctl_coin_impulse / ctl_paddle / ctl_pedal: PAUSE_MODE
//  The v2 settings that absorb the cores' remaining local blocks (keyboard tables, port builders, pause forms) are
//  in verilator/controllers/lint_cfg.sv, each proven against the core's own block by tb_keyboard_v2 / tb_port_map_v2.
//
//  PAUSE. Every module with a counter, ramp, timer or latch takes `pause` (connect the core's pause_cpu; tie 0 or leave
//  it unconnected to ignore pause). The v2 rule, with pause connected (and PAUSE_MODE = 1 where the module has it):
//    - nothing accumulates or queues while paused: relative motion (mouse, spinner, quadrature, stick / D-pad rate,
//      wheel / paddle deltas) and presses that would start something (coin impulse, toggle) are DISCARDED, not stored;
//    - timers, ramps, slews and dividers FREEZE and continue from where they stopped;
//    - level state keeps tracking: held keys / buttons, the 4-way mask, absolute positions (the knob of ctl_paddle,
//      the stick of ctl_ad_stick), so nothing is stuck or lost on resume.
//      module             paused (v2 rule)                                                  PAUSE_MODE 0 (v1 default)
//      ctl_keyboard       kb / level kbx track keys; toggle kbx ignore presses              (pause port is new)
//      ctl_tick           no strobe; the divider holds; a vblank edge while paused is lost  = v2 (v1 already did this)
//      ctl_joy4way        tracks (level state)                                              -
//      ctl_coin_impulse   frame count holds; a press arriving while paused is discarded    press is latched, fires after
//      ctl_toggle         presses ignored (the button is still tracked: no flip on resume) (pause port is new)
//      ctl_trackball      counters hold; every source's motion is discarded; dir holds     = v2
//      ctl_paddle         position holds; relative motion discarded; on resume the         knob moves made while paused
//                         position jumps to the absolute knob if it moved while paused     are lost until it moves again
//      ctl_dial_mame      counter holds; all motion (incl. wheel / paddle deltas) discarded = v2
//      ctl_ad_stick       D-pad offset ramp / autocentre freezes; value follows the stick   = v2
//      ctl_steer          backlog and tick divider hold; all motion discarded               = v2
//      ctl_pedal          ramps freeze; a released button clears its ramp at once           release clears it at the
//                                                                                           first tick after resume
//      ctl_gun_cursor     cursor holds; mouse / stick / D-pad motion discarded              = v2
//  ctl_mouse, ctl_quad_decoder, ctl_stick_dirs, ctl_ids, ctl_port_map have no state that times or accumulates.
//
//  Redistribution and use in source and synthesized forms, with or without modification, are permitted
//  provided that the above copyright notice is retained. THIS SOFTWARE IS PROVIDED "AS IS" WITHOUT WARRANTY.
//
//============================================================================


//----------------------------------------------------------------------------
// ctl_keyboard: MAME default keys from hps_io ps2_key (template cores' block).
// hps_io packs ps2_key = {toggle, pressed, extended, code}: bit 9 is 1 while the key is DOWN
// (21 fleet cores use ~ps2_key[9] for these active-high regs = inverted keys, 2026-10-24; fixed here).
// kb: [0] up [1] down [2] left [3] right [4] Btn 1 (Ctrl) [5] Btn 2 (Alt) [6] Start 1 (1) [7] Start 2 (2)
//     [8] Coin 1 (5) [9] Coin 2 (6) [10] Service (9) [11] Tilt (T) [12] Pause (P)
// STD_EXT (extended bit ps2_key[8] for the 13 keys): 0 = ignored (v1: right Ctrl / Alt also press Btn 1 / 2, keypad
//   8 / 2 / 4 / 6 also move); 1 = every non-arrow key needs the NON-extended code (left Ctrl / left Alt only, so right
//   Ctrl / Alt are free for the extra table), arrows still take both (Pole Position's casex 'hX75 form).
// Extra-key table: NX entries, entry n = XKEYS[n*24 +: 24] = 24'hMEccbb (one hex digit / byte per field):
//   M  mode   0 unused, 1 level (the key's press / release sets / clears kbx[bb]), 2 toggle (each press flips kbx[bb])
//   E  ext    0 either, 1 non-extended only, 2 extended only (e.g. 24'h12_11_07 = right Alt -> kbx[7])
//   cc PS/2 set-2 code; bb output bit (< NXO). Write XKEYS = {entry NX-1, ..., entry 0}.
//   Several entries may drive one bit: each key event on any of them sets the bit, so the LAST KEY EVENT WINS (MCR /
//   Gottlieb / Williams / SegaSys1 9 + F2 test switch: hold 9, tap F2 -> released). If two entries match one event and
//   drive the same bit, the higher entry wins. A key may be in kb and in the table at once. XINIT = kbx power-up values.
// Pause (port is v2-only; unconnected = v1): kb and level kbx keep tracking presses and releases; toggle entries ignore
//   presses while paused (the switch cannot change behind a frozen game).
//----------------------------------------------------------------------------
module ctl_keyboard #(
    parameter int         STD_EXT = 0,
    parameter int         NX      = 1,        // >= 1 (the default single entry is unused)
    parameter int         NXO     = 1,        // >= 1
    parameter [NX*24-1:0] XKEYS   = {NX{24'h000000}},
    parameter [NXO-1:0]   XINIT   = {NXO{1'b0}}
)
(
    input             clk,
/* verilator lint_off UNUSED */
    input      [10:0] ps2_key,
/* verilator lint_on UNUSED */
    input  tri0       pause,
    output reg [12:0] kb = 13'd0,
    output [NXO-1:0]  kbx
);

reg        old_state = 1'b0;
wire       ev        = old_state != ps2_key[10];
wire       pressed   = ps2_key[9];
wire       ext       = ps2_key[8];
wire [7:0] code      = ps2_key[7:0];
wire       std_ok    = (STD_EXT == 0) || !ext;    // non-arrow keys

always @(posedge clk) begin
    old_state <= ps2_key[10];
    if (ev) begin
        case (code)
            8'h75: kb[0]  <= pressed;   // up
            8'h72: kb[1]  <= pressed;   // down
            8'h6B: kb[2]  <= pressed;   // left
            8'h74: kb[3]  <= pressed;   // right
            8'h14: if (std_ok) kb[4]  <= pressed;   // ctrl
            8'h11: if (std_ok) kb[5]  <= pressed;   // alt
            8'h16: if (std_ok) kb[6]  <= pressed;   // 1
            8'h1E: if (std_ok) kb[7]  <= pressed;   // 2
            8'h2E: if (std_ok) kb[8]  <= pressed;   // 5
            8'h36: if (std_ok) kb[9]  <= pressed;   // 6
            8'h46: if (std_ok) kb[10] <= pressed;   // 9
            8'h2C: if (std_ok) kb[11] <= pressed;   // T
            8'h4D: if (std_ok) kb[12] <= pressed;   // P
            default: ;
        endcase
    end
end

function automatic ext_ok(input [3:0] rule, input x);
    ext_ok = (rule == 4'd0) || (rule == 4'd1 && !x) || (rule == 4'd2 && x);
endfunction

genvar o;
generate
    for (o = 0; o < NXO; o = o + 1) begin : g_x
        reg q = XINIT[o];
        always @(posedge clk) begin
            if (ev) begin
                for (int n = 0; n < NX; n++) begin
                    if (XKEYS[n*24+8 +: 8] == code && {24'd0, XKEYS[n*24 +: 8]} == o && ext_ok(XKEYS[n*24+16 +: 4], ext)) begin
                        if (XKEYS[n*24+20 +: 4] == 4'd1)                            q <= pressed;
                        else if (XKEYS[n*24+20 +: 4] == 4'd2 && pressed && !pause) q <= ~q;
                    end
                end
            end
        end
        assign kbx[o] = q;
    end
endgenerate

endmodule


//----------------------------------------------------------------------------
// ctl_mouse: hps_io ps2_mouse -> ev (one clock per packet), dx (right +), dy (down +; PS/2 is up +),
// both 10-bit signed so a -256 count negates correctly. btn = {middle, right, left}.
//----------------------------------------------------------------------------
module ctl_mouse
(
    input         clk,
/* verilator lint_off UNUSED */
    input  [24:0] ps2_mouse,
/* verilator lint_on UNUSED */
    output        ev,
    output  [9:0] dx,
    output  [9:0] dy,
    output  [2:0] btn
);

reg seen = 1'b0;
always @(posedge clk) seen <= ps2_mouse[24];

assign ev  = ps2_mouse[24] != seen;
assign dx  = {ps2_mouse[4], ps2_mouse[4], ps2_mouse[15:8]};
assign dy  = 10'd0 - {ps2_mouse[5], ps2_mouse[5], ps2_mouse[23:16]};
assign btn = ps2_mouse[2:0];

endmodule


//----------------------------------------------------------------------------
// ctl_tick: MODE 0 = one clock at each vblank rising edge (the fleet's `vblank & ~vbl_d`);
// MODE 1 = divider, one clock every period+1 clocks (counter wraps when >= period; runtime period).
// Pause: no strobe while pause is high; the divider holds and continues on resume; a vblank edge seen while paused is
// lost (the edge detector keeps tracking, so resuming inside vblank gives no strobe). Same in v1.
//----------------------------------------------------------------------------
module ctl_tick #(parameter int MODE = 0, parameter int DW = 18)
(
    input           clk,
    input  tri0     pause,
/* verilator lint_off UNUSED */
    input           vblank,           // MODE 0
    input  [DW-1:0] period,           // MODE 1
/* verilator lint_on UNUSED */
    output          tick
);

generate
    if (MODE == 0) begin : g_vbl
        reg vbl_d = 1'b0;
        always @(posedge clk) vbl_d <= vblank;
        assign tick = vblank & ~vbl_d & ~pause;
    end
    else begin : g_div
        reg [DW-1:0] div = {DW{1'b0}};
        always @(posedge clk) if (!pause) div <= (div >= period) ? {DW{1'b0}} : div + 1'd1;
        assign tick = (div == {DW{1'b0}}) & ~pause;
    end
endgenerate

endmodule


//----------------------------------------------------------------------------
// ctl_joy4way: 4-way joystick, the most recently pressed direction wins (from the MiSTer Pac-Man port;
// byte-identical in 12 fleet cores). en = 0 passes the input through (one clock late). in / out {U, D, L, R}.
//----------------------------------------------------------------------------
module ctl_joy4way
(
    input        clk,
    input        en,
    input  [3:0] in,
    output [3:0] out
);

reg  [3:0] mask = 4'hF;
reg  [3:0] in1 = 4'd0, in2 = 4'd0;
wire [3:0] innew = in1 & ~in2;

assign out = in1 & mask;

always @(posedge clk) begin
    in1 <= in;
    in2 <= in1;

    if (innew[0]) mask <= 4'b0001;
    if (innew[1]) mask <= 4'b0010;
    if (innew[2]) mask <= 4'b0100;
    if (innew[3]) mask <= 4'b1000;

    if ((in & mask) == 4'd0 || !en) mask <= 4'hF;   // == !(in & mask)
end

endmodule


//----------------------------------------------------------------------------
// ctl_stick_dirs: analog stick {Y, X} -> {U, D, L, R}, combinational.
// MODE 0: each axis past +/-THRESH (8-way; SI / Galaxian 40, Konami82 family / DECO 48, Qix / SNK 64).
// MODE 1: dominant axis only, once it reaches THRESH (4-way; MCR right stick, 64).
//----------------------------------------------------------------------------
module ctl_stick_dirs #(parameter int MODE = 0, parameter [6:0] THRESH = 7'd40)
(
    input  [15:0] stick,
    output  [3:0] dir
);

generate
    if (MODE == 0) begin : g_axis
        localparam signed [7:0] T = {1'b0, THRESH};
        wire signed [7:0] x = stick[7:0];
        wire signed [7:0] y = stick[15:8];
        assign dir = {y < -T, y > T, x < -T, x > T};
    end
    else begin : g_dom
        wire       xn = stick[7], yn = stick[15];          // sign bits
        wire [7:0] ax = xn ? 8'd0 - stick[7:0]  : stick[7:0];
        wire [7:0] ay = yn ? 8'd0 - stick[15:8] : stick[15:8];
        wire       h  = ax >= ay;
        wire       on = (h ? ax : ay) >= {1'b0, THRESH};
        assign dir = {on & ~h & yn, on & ~h & ~yn, on & h & xn, on & h & ~xn};
    end
endgenerate

endmodule


//----------------------------------------------------------------------------
// ctl_coin_impulse: MAME PORT_IMPULSE(FRAMES) (Galaga-family block). A press is latched, then the coin is
// held for exactly FRAMES frames from the next vblank. en = 0 passes coin_raw through.
// Pause: the frame count holds (an active pulse stays up and finishes after resume). A press made while paused:
//   PAUSE_MODE 0 (v1) latches it and the pulse starts at the first vblank after resume; PAUSE_MODE 1 discards it (a
//   coin held through the resume does not count either: the press edge was seen while paused). A press latched just
//   before the pause still fires after it.
//----------------------------------------------------------------------------
module ctl_coin_impulse #(parameter [3:0] FRAMES = 4'd2, parameter int PAUSE_MODE = 0)
(
    input       clk,
    input  tri0 pause,
    input       vblank,
    input       en,
    input       coin_raw,
    output      coin
);

reg       coin_d = 1'b0, pend = 1'b0, vbl_d = 1'b0;
reg [3:0] frames = 4'd0;
wire      drop   = (PAUSE_MODE != 0) && pause;

always @(posedge clk) begin
    coin_d <= coin_raw;
    vbl_d  <= vblank;
    if (coin_raw & ~coin_d & ~drop) pend <= 1'b1;
    if (vblank & ~vbl_d & ~pause) begin
        if (pend)                begin frames <= FRAMES; pend <= 1'b0; end
        else if (frames != 4'd0) frames <= frames - 4'd1;
    end
end

assign coin = en ? |frames : coin_raw;

endmodule


//----------------------------------------------------------------------------
// ctl_toggle: MAME PORT_TOGGLE - q flips on each rising edge of btn; clear (e.g. ioctl_download) zeroes it.
// Pause (port is v2-only; unconnected = v1): a press while paused is ignored; btn keeps being tracked, so a button
// still held at resume does not flip q either. clear works while paused.
//----------------------------------------------------------------------------
module ctl_toggle
(
    input      clk,
    input      clear,
    input      btn,
    input tri0 pause,
    output reg q = 1'b0
);

reg btn_d = 1'b0;
always @(posedge clk) begin
    btn_d <= btn;
    if (clear)                      q <= 1'b0;
    else if (btn & ~btn_d & ~pause) q <= ~q;
end

endmodule


//----------------------------------------------------------------------------
// ctl_ids: control ids 0-35 shared by the fleet's gen_mra input maps (Galaga / Pac-Man / SI / Centipede /
// Gottlieb / MCR / Williams numbering). Ids 24-31 are 0 here (each core ORs its analog / right-stick ids in);
// a core ORs extra sources (mouse button, SNAC fire) into the output bits.
//   0 none, 1-4 P1 U D L R, 5-8 P1 Btn 1-4, 9-12 P2 U D L R, 13-16 P2 Btn 1-4, 17-18 coin 1-2,
//   19-20 start 1-2, 21 tilt, 22 service, 23 coin 3, 32-33 P1 Btn 5-6, 34-35 P2 Btn 5-6.
// Start 1 = pad 1's Start only; Start 2 = pad 1's Start 2P or pad 2's Start / Start 2P (never link pads:
// MCR / Gottlieb / SegaSys1 / Williams form; the older cores also fed pad 2's Start into Start 1).
// dir1 / dir2 already include the keyboard arrows and the 4-way restriction; coins arrive after the impulse.
// BTN56 = 0: ids 32-35 stay 0 (Centipede's maps have no Btn 5-6); 1 (default, v1) = pad Btn 5-6.
//----------------------------------------------------------------------------
module ctl_ids #(parameter int BTN56 = 1)
(
/* verilator lint_off UNUSED */
    input  [15:0] joy0,
    input  [15:0] joy1,
    input  [12:0] kb,                 // ctl_keyboard
/* verilator lint_on UNUSED */
    input   [3:0] dir1,               // {U, D, L, R}
    input   [3:0] dir2,
    input         coin1,
    input         coin2,
    input         coin3,
    output [35:0] ctl
);

wire       start1 = joy0[9] | kb[6];
wire       start2 = joy0[10] | joy1[10] | joy1[9] | kb[7];
wire [3:0] btn56  = (BTN56 != 0) ? {joy1[13:12], joy0[13:12]} : 4'd0;

assign ctl =
{
    btn56,                                      // 35-34 P2 Btn 6-5, 33-32 P1 Btn 6-5
    8'd0,                                       // 31-24 core-specific
    coin3,                                      // 23 coin 3
    kb[10],                                     // 22 service
    kb[11],                                     // 21 tilt
    start2,                                     // 20 start 2
    start1,                                     // 19 start 1
    coin2,                                      // 18 coin 2
    coin1,                                      // 17 coin 1
    joy1[7:4],                                  // 16-13 P2 Btn 4-1
    dir2[0], dir2[1], dir2[2], dir2[3],         // 12 R, 11 L, 10 D, 9 U
    joy0[7:6], joy0[5] | kb[5], joy0[4] | kb[4],   // 8-5 P1 Btn 4-1
    dir1[0], dir1[1], dir1[2], dir1[3],         // 4 R, 3 L, 2 D, 1 U
    1'b0                                        // 0 none
};

endmodule


//----------------------------------------------------------------------------
// ctl_port_map: game input ports from the MRA input map, registered (the fleet's in_port loop).
// Per port bit i: map byte m = in_map[i*8 +: 8];
//   ovr_mask[i]            -> ovr_val[i]               (analog field overlay, SI an_mask / an_val)
//   DIP_MODE && m[7]       -> dips[m[4:0]]             (Centipede: 0x80 | n = packed DIP bit n)
//   otherwise              -> base[i] ^ ctl[m[IDW-1:0]] (a pressed control inverts the base level)
// base[i] (port p = i / 8, bit b = i % 8) by BASE_MODE:
//   0 (v1)  idle[i]
//   1       port_sel byte p [7] = 1 ? idle[i] : dip_bytes byte port_sel[p][2:0], bit b        (Phoenix-family port_dip)
//   2       port_sel byte p [7] = 1 ? idle[i] : dip_bytes byte port_sel[p][2:0], bit dip_bit[i] (Gottlieb / Williams /
//           SegaSys1 / MCR: port_dip + the dip_bit permutation; dip_bit[i] = dip_bit[i*3 +: 3])
// dip_bytes = {DIP byte 7, ..., DIP byte 0} (the cores' dip_sw[8]). port_sel / dip_bytes / dip_bit are tri0 (unused in
// BASE_MODE 0). Params: NP ports (8 bits each), IDW control-id bits (CTLW = 2^IDW), DIP_MODE 0 / 1, BASE_MODE 0-2.
//----------------------------------------------------------------------------
module ctl_port_map #(parameter int NP = 4, parameter int IDW = 6, parameter int DIP_MODE = 0, parameter int BASE_MODE = 0)
(
    input                      clk,
    input         [NP*8-1:0]   idle,
/* verilator lint_off UNUSED */
    input         [NP*64-1:0]  in_map,
    input         [31:0]       dips,
    input  tri0   [NP*8-1:0]   port_sel,              // BASE_MODE 1 / 2 (bits 6-3 unused)
    input  tri0   [63:0]       dip_bytes,             // BASE_MODE 1 / 2
    input  tri0   [NP*24-1:0]  dip_bit,               // BASE_MODE 2
/* verilator lint_on UNUSED */
    input   [(1<<IDW)-1:0]     ctl,
    input         [NP*8-1:0]   ovr_mask,
    input         [NP*8-1:0]   ovr_val,
    output reg    [NP*8-1:0]   ports
);

always @(posedge clk) begin
    for (int i = 0; i < NP*8; i++) begin : g_bit
/* verilator lint_off UNUSED */
        reg [7:0] m;                                  // bit 6 unused (ids < 64 or DIP flag)
        reg [7:0] sel;                                // bits 6-3 unused
/* verilator lint_on UNUSED */
        reg [2:0] db;
        reg       base;
        m    = in_map[i*8 +: 8];
        sel  = port_sel[(i/8)*8 +: 8];
        db   = (BASE_MODE == 2) ? dip_bit[i*3 +: 3] : i[2:0];
        base = (BASE_MODE == 0 || sel[7]) ? idle[i] : dip_bytes[{sel[2:0], db}];
        if (ovr_mask[i])                ports[i] <= ovr_val[i];
        else if (DIP_MODE != 0 && m[7]) ports[i] <= dips[m[4:0]];
        else                            ports[i] <= base ^ ctl[m[IDW-1:0]];
    end
end

endmodule


//----------------------------------------------------------------------------
// ctl_quad_decoder: quadrature A/B -> ce (one clock per edge of A or B) and dir, after a 2-FF synchroniser
// (Centipede SNAC = the Crystal Castles core's LETA decoder). Inputs idle high (open collector).
//----------------------------------------------------------------------------
module ctl_quad_decoder
(
    input  clk,
    input  a,
    input  b,
    output ce,
    output dir
);

reg [1:0] as = 2'b11, bs = 2'b11;
reg [2:0] qa = 3'd0, qb = 3'd0;
always @(posedge clk) begin
    as <= {as[0], a};
    bs <= {bs[0], b};
    qa <= {qa[1:0], as[1]};
    qb <= {qb[1:0], bs[1]};
end

assign ce  = qa[1] ^ qa[2] ^ qb[1] ^ qb[2];
assign dir = qa[1] ^ qb[2];

endmodule


//----------------------------------------------------------------------------
// ctl_trackball: two free-running counters (X, Y; screen convention X right +, Y down +) for trackballs,
// dials and spinners. Generalised from Centipede (unit / base shifts, SNAC, direction latch), Pac-Man, Qix,
// Gottlieb / Williams / SegaSys1 and Exidy's dial. Every source on the same clock is summed (the cores'
// if / else chains dropped a stick step when a mouse packet landed on the tick clock).
//   mouse   : mouse_dx / mouse_dy (ctl_mouse) << MOUSE_SH per packet
//   spinner : X += spinner[7:0] << SPIN_SH per event
//   tick    : (stick_en) stick axis >>> STICK_RSH while past +/-DZ (LIVE_ANY: either axis past DZ drives
//             both), else D-pad +/-DPAD_STEP (opposite directions cancel); then << unit_sh
//   quad    : +/-(1 << unit_sh) per quad_ce (native counter direction; rev does not apply)
//   rev[n]  : negates the mouse / spinner / tick delta of axis n
// Output = counter >> (base_sh + 1 if speed = 2 Slow, - 1 if speed = 1 Fast), low OUT_W bits.
// dir[n] = sign of the last change of output n (Atari trackball DIR flip-flop / MAME read_trackball).
// Per-core settings that reproduce the old logic: see verilator/controllers/tb_trackball.sv.
// Pause: counters hold; motion from every source (mouse, spinner, quadrature, tick) arriving while paused is
// discarded; dir holds. Same in v1.
//----------------------------------------------------------------------------
module ctl_trackball #(
    parameter int CW        = 12,     // counter bits (<= 24)
    parameter int OUT_W     = 8,      // output bits (<= CW)
    parameter int MOUSE_SH  = 0,
    parameter int SPIN_SH   = 0,
    parameter int STICK_RSH = 3,
    parameter int DPAD_STEP = 6,
    parameter int DZ        = 12,
    parameter int LIVE_ANY  = 0
)
(
    input              clk,
    input              reset,
    input  tri0        pause,
    input        [1:0] rev,           // {Y, X}
    input        [1:0] unit_sh,
    input        [3:0] base_sh,
    input        [1:0] speed,         // 0 Normal, 1 Fast, 2 Slow (3 = Normal)

    input              mouse_ev,
    input        [9:0] mouse_dx,
    input        [9:0] mouse_dy,
    input        [8:0] spinner,       // hps_io: [8] toggles per event, [7:0] signed delta (X axis)
    input        [1:0] quad_ce,       // {Y, X}
    input        [1:0] quad_dir,      // 1 = count down
    input              tick,
    input              stick_en,
    input       [15:0] stick,         // {Y, X} signed
    input        [3:0] dpad,          // {U, D, L, R}

    output [OUT_W-1:0] x,
    output [OUT_W-1:0] y,
    output reg   [1:0] dir = 2'b00
);

reg  [CW-1:0] cx = {CW{1'b0}}, cy = {CW{1'b0}};
reg           spin_seen = 1'b0;

wire signed [23:0] sx = {{16{stick[7]}},  stick[7:0]};
wire signed [23:0] sy = {{16{stick[15]}}, stick[15:8]};
wire signed [31:0] sx32 = {{24{stick[7]}},  stick[7:0]};    // dead-zone compares at int width (no int-param slices)
wire signed [31:0] sy32 = {{24{stick[15]}}, stick[15:8]};
wire lx = (sx32 > DZ) || (sx32 < -DZ);
wire ly = (sy32 > DZ) || (sy32 < -DZ);
wire live_x = (LIVE_ANY != 0) ? (lx | ly) : lx;
wire live_y = (LIVE_ANY != 0) ? (lx | ly) : ly;

function automatic signed [23:0] tstep(input live, input signed [23:0] a, input pos, input neg);
/* verilator lint_off UNUSED */
    reg signed [31:0] st;                                    // D-pad step at int width; low 24 bits used
/* verilator lint_on UNUSED */
    begin
        st    = (pos ^ neg) ? (pos ? DPAD_STEP : -DPAD_STEP) : 0;
        tstep = live ? (a >>> STICK_RSH) : st[23:0];
    end
endfunction

wire               do_tick = tick & stick_en;
wire signed [23:0] tx = do_tick ? (tstep(live_x, sx, dpad[0], dpad[1]) <<< unit_sh) : 24'sd0;
wire signed [23:0] ty = do_tick ? (tstep(live_y, sy, dpad[2], dpad[3]) <<< unit_sh) : 24'sd0;
wire signed [23:0] mx = mouse_ev ? ({{14{mouse_dx[9]}}, mouse_dx} <<< MOUSE_SH) : 24'sd0;
wire signed [23:0] my = mouse_ev ? ({{14{mouse_dy[9]}}, mouse_dy} <<< MOUSE_SH) : 24'sd0;
wire               spin_ev = spinner[8] != spin_seen;
wire signed [23:0] sp = spin_ev ? ({{16{spinner[7]}}, spinner[7:0]} <<< SPIN_SH) : 24'sd0;
wire signed [23:0] unit = 24'sd1 <<< unit_sh;
wire signed [23:0] qx = quad_ce[0] ? (quad_dir[0] ? -unit : unit) : 24'sd0;
wire signed [23:0] qy = quad_ce[1] ? (quad_dir[1] ? -unit : unit) : 24'sd0;
wire signed [23:0] ax = mx + sp + tx;
wire signed [23:0] ay = my + ty;
/* verilator lint_off UNUSED */
wire signed [23:0] dx = (rev[0] ? -ax : ax) + qx;    // low CW bits used (wrap arithmetic)
wire signed [23:0] dy = (rev[1] ? -ay : ay) + qy;
/* verilator lint_on UNUSED */

always @(posedge clk) begin
    spin_seen <= spinner[8];
    if (reset) begin
        cx <= {CW{1'b0}};
        cy <= {CW{1'b0}};
    end
    else if (!pause) begin
        cx <= cx + dx[CW-1:0];
        cy <= cy + dy[CW-1:0];
    end
end

wire [4:0] sh = {1'b0, base_sh} + ((speed == 2'd2) ? 5'd1 : 5'd0) - ((speed == 2'd1 && base_sh != 4'd0) ? 5'd1 : 5'd0);
/* verilator lint_off UNUSED */
wire [CW-1:0] xs = cx >> sh;                          // low OUT_W bits used
wire [CW-1:0] ys = cy >> sh;
/* verilator lint_on UNUSED */
assign x = xs[OUT_W-1:0];
assign y = ys[OUT_W-1:0];

reg  [OUT_W-1:0] x_d = {OUT_W{1'b0}}, y_d = {OUT_W{1'b0}};
wire [OUT_W-1:0] ddx = x - x_d;
wire [OUT_W-1:0] ddy = y - y_d;
always @(posedge clk) begin
    x_d <= x;
    y_d <= y;
    if (ddx != {OUT_W{1'b0}}) dir[0] <= ddx[OUT_W-1];
    if (ddy != {OUT_W{1'b0}}) dir[1] <= ddy[OUT_W-1];
end

endmodule


//----------------------------------------------------------------------------
// ctl_paddle: absolute paddle position in [PMIN, PMAX] (MAME IPT_PADDLE). From Exidy's exidy_paddle, the
// parameterised form of Centipede's paddle_ctl (Warlords: PMIN 1D, PMAX CB, PCEN 80).
//   paddle (hps_io paddle_N): absolute, the position follows the knob over the full range
//   spinner and mouse X: relative, half a count per count at 1.0x; stick X: up to 8 counts per tick,
//   D-pad 5 per tick (tick = frame). Sensitivity 1.0 .75 .5 .25 .125 1.25 1.5 2.0 x; reverse flips all.
// Pause: the position holds; spinner / mouse / stick / D-pad motion arriving while paused is discarded. The absolute
//   knob is level state: PAUSE_MODE 1 compares it with its pre-pause value on resume, so if it was turned while paused
//   the position jumps to it on the first clock after resume; PAUSE_MODE 0 (v1) forgets moves made while paused (the
//   position follows the knob again only when it next moves).
//----------------------------------------------------------------------------
module ctl_paddle #(parameter [7:0] PMIN = 8'h1D, parameter [7:0] PMAX = 8'hCB, parameter [7:0] PCEN = 8'h80,
                    parameter int PAUSE_MODE = 0)
(
    input             clk,
    input             reset,
    input  tri0       pause,
    input             tick,
    input       [2:0] sensitivity,
    input             reverse,

    input       [7:0] paddle,
    input       [8:0] spinner,
    input             mouse_ev,       // tie 0 to ignore the mouse
    input       [9:0] mouse_dx,
    input       [7:0] stick_x,        // signed
    input             left,
    input             right,

    output      [7:0] pos
);

localparam [10:0] LO = {PMIN, 3'd0}, HI = {PMAX, 3'd0}, MID = {PCEN, 3'd0};
localparam [15:0] SPAN = {8'd0, PMAX - PMIN};

// value * sensitivity in 1/8 counts
function automatic signed [15:0] scale_q3(input signed [9:0] v, input [2:0] s);
    reg signed [15:0] e;
    begin
        e = {{6{v[9]}}, v};
        case (s)
            3'd0:    scale_q3 = e <<< 3;
            3'd1:    scale_q3 = (e <<< 2) + (e <<< 1);
            3'd2:    scale_q3 = e <<< 2;
            3'd3:    scale_q3 = e <<< 1;
            3'd4:    scale_q3 = e;
            3'd5:    scale_q3 = (e <<< 3) + (e <<< 1);
            3'd6:    scale_q3 = (e <<< 3) + (e <<< 2);
            default: scale_q3 = e <<< 4;
        endcase
    end
endfunction

reg        spin_seen = 1'b0;
reg  [7:0] pad_d = 8'h80;
reg [10:0] posq = MID;                               // position in 1/8 counts

wire signed [9:0] spin_d  = (spinner[8] != spin_seen) ? $signed({{2{spinner[7]}}, spinner[7:0]}) : 10'sd0;
wire signed [9:0] mouse_d = mouse_ev ? $signed(mouse_dx) : 10'sd0;
wire signed [7:0] sx      = stick_x;
wire signed [9:0] sx_e    = {{2{sx[7]}}, sx};
wire signed [9:0] frame_d = (sx > 8'sd12 || sx < -8'sd12) ? (sx_e >>> 4) : right ? 10'sd5 : left ? -10'sd5 : 10'sd0;

wire signed [15:0] d_q3 = (scale_q3(spin_d, sensitivity) >>> 1) + (scale_q3(mouse_d, sensitivity) >>> 1) +
                          (tick ? scale_q3(frame_d, sensitivity) : 16'sd0);
wire signed [15:0] nxt  = $signed({5'd0, posq}) + (reverse ? -d_q3 : d_q3);

// absolute knob: 00-FF -> PMIN-PMAX
/* verilator lint_off UNUSED */
wire [15:0] knob  = {8'd0, reverse ? ~paddle : paddle} * SPAN;   // high byte used
/* verilator lint_on UNUSED */
wire [10:0] abs_q = {(PMIN + knob[15:8]), 3'd0};

always @(posedge clk) begin
    spin_seen <= spinner[8];
    if (PAUSE_MODE == 0 || !pause) pad_d <= paddle;
    if (reset)                          posq <= MID;
    else if (pause)                     posq <= posq;
    else if (paddle != pad_d)           posq <= abs_q;
    else if (nxt < $signed({5'd0, LO})) posq <= LO;
    else if (nxt > $signed({5'd0, HI})) posq <= HI;
    else                                posq <= nxt[10:0];
end

assign pos = posq[10:3];

endmodule


//----------------------------------------------------------------------------
// ctl_dial_mame: MAME IPT_DIAL / IPT_TRACKBALL axis, a free-running 8-bit counter (MCR mcr_dial, itself from
// Pole Position's pp_steering). MAME ioport analog_field units, sensitivity s = sens * 100 / 128 %:
//   mouse s / 100 counts per count; spinner twice the mouse; held key keydelta * s / 100 counts per frame;
//   stick (rate) 16 * s / 100 counts per frame at full deflection; stick (wheel) / paddle: the counter tracks
//   the device, s / 100 counts per unit (+-128 units). OSD sensitivity / direction as Pole Position.
// sens = MAME sensitivity * 128 / 100, keyd = MAME key delta (MRA bytes). 3-stage pipeline.
// Pause: the counter holds; all motion arriving while paused is discarded, including wheel / paddle movement (their
//   last-value registers keep tracking, so nothing jumps on resume) and deltas still in the pipeline. Same in v1.
//----------------------------------------------------------------------------
module ctl_dial_mame
(
    input             clk,
    input             reset,
    input  tri0       pause,
    input             frame,          // once per MAME frame
    input       [7:0] sens,
    input       [7:0] keyd,
    input             reverse,        // MAME PORT_REVERSE ^ OSD direction
    input       [2:0] osd_sens,       // 1.0 .75 .5 .25 .125 1.25 1.5 2.0 x
    input             wheel,          // analog stick is a wheel (absolute) instead of a rate

    input       [8:0] spinner,
    input             mouse_ev,
    input       [8:0] mouse_d,        // signed
    input       [7:0] stick,          // signed
    input       [7:0] paddle,         // 0-255, absolute (an idle paddle adds nothing)
    input             use_paddle,
    input             dec,
    input             inc,

    output      [7:0] pos
);

function automatic signed [27:0] osd_scale(input signed [27:0] v, input [2:0] s);   // * {8,6,4,2,1,10,12,16} / 8
    case (s)
        3'd0:    osd_scale = v;
        3'd1:    osd_scale = (v >>> 1) + (v >>> 2);
        3'd2:    osd_scale = v >>> 1;
        3'd3:    osd_scale = v >>> 2;
        3'd4:    osd_scale = v >>> 3;
        3'd5:    osd_scale = v + (v >>> 2);
        3'd6:    osd_scale = v + (v >>> 1);
        default: osd_scale = v <<< 1;
    endcase
endfunction

reg               spin_seen = 1'b0;
reg signed [8:0]  stk_last = 9'sd0, pad_last = 9'sd0;
reg signed [23:0] posq = 24'sd0;                       // position in 1/256 counts

wire signed [9:0]  spin_d = (spinner[8] != spin_seen) ? $signed({{2{spinner[7]}}, spinner[7:0]}) : 10'sd0;
wire signed [9:0]  mous_d = mouse_ev ? $signed({mouse_d[8], mouse_d}) : 10'sd0;
wire signed [8:0]  sx     = $signed({stick[7], stick});
wire               live   = (sx > 9'sd12) || (sx < -9'sd12);
wire signed [9:0]  key_v  = (inc && !dec) ? $signed({2'b00, keyd}) : (dec && !inc) ? -$signed({2'b00, keyd}) : 10'sd0;

wire signed [8:0]  pad_t  = use_paddle ? ($signed({1'b0, paddle}) - 9'sd128) : 9'sd0;
wire signed [8:0]  stk_t  = (wheel && live) ? sx : 9'sd0;

// every source in 1/8 mouse counts, then ONE multiply by the sensitivity: 1/256 counts = raw8 * sens / 4
wire signed [17:0] ev8    = 18'sd8 * ($signed({{8{spin_d[9]}}, spin_d}) * 18'sd2 + {{8{mous_d[9]}}, mous_d} +
                                      {{9{stk_t[8]}}, stk_t} - {{9{stk_last[8]}}, stk_last} +
                                      {{9{pad_t[8]}}, pad_t} - {{9{pad_last[8]}}, pad_last});
wire signed [17:0] fr8    = (!wheel && live) ? {{9{sx[8]}}, sx} : live ? 18'sd0 : 18'sd8 * {{8{key_v[9]}}, key_v};
wire signed [17:0] raw8   = ev8 + (frame ? fr8 : 18'sd0);

reg  signed [17:0] raw8_q = 18'sd0;
reg         [7:0]  sens_q = 8'd0;
reg  signed [27:0] prod_q = 28'sd0;
/* verilator lint_off UNUSED */
wire signed [27:0] d_q    = osd_scale(prod_q >>> 2, osd_sens);   // low 24 bits used
/* verilator lint_on UNUSED */
wire signed [27:0] prod   = {{10{raw8_q[17]}}, raw8_q} * $signed({20'd0, sens_q});

always @(posedge clk) begin
    spin_seen  <= spinner[8];
    stk_last   <= stk_t;
    pad_last   <= pad_t;
    raw8_q     <= (reset || pause) ? 18'sd0 : raw8;
    sens_q     <= sens;
    prod_q     <= reset ? 28'sd0 : prod;
    if (reset)       posq <= 24'sd0;
    else if (!pause) posq <= posq + (reverse ? -d_q[23:0] : d_q[23:0]);
end

assign pos = posq[15:8];

endmodule


//----------------------------------------------------------------------------
// ctl_ad_stick: MAME IPT_AD_STICK absolute axis (MCR mcr_inputs). val = rest + stick * (hi - rest) / 128
// (or * (rest - lo) / 128 below the rest value), clamped to [lo, hi]. While the stick is inside +/-DZ a held
// D-pad moves an offset keyd per tick (frame) towards the end, and back to rest when released (autocentre).
// Stick axis signed, + = right / down; inc = right / down, dec = left / up.
// Pause: the D-pad offset (ramp and autocentre) freezes and continues on resume, so a D-pad released while paused
//   recentres after resume; val keeps following the stick (level state). Same in v1.
//----------------------------------------------------------------------------
module ctl_ad_stick #(parameter [6:0] DZ = 7'd4)
(
    input        clk,
    input        reset,
    input  tri0  pause,
    input        tick,
    input  [7:0] rest,
    input  [7:0] lo,
    input  [7:0] hi,
    input  [7:0] keyd,
    input  [7:0] stick,
    input        inc,
    input        dec,
    output [7:0] val
);

localparam signed [8:0] DZP = {2'b00, DZ};

function automatic [7:0] ad_val(input [7:0] r, input signed [8:0] off, input [7:0] l, input [7:0] h);
    reg        [7:0]  span;
    reg signed [17:0] v;
    begin
        span   = (off >= 9'sd0) ? h - r : r - l;
        v      = ($signed({{9{off[8]}}, off}) * $signed({10'd0, span})) >>> 7;   // $signed: a concatenation is unsigned
        v      = $signed({10'd0, r}) + v;
        ad_val = (v < $signed({10'd0, l})) ? l : (v > $signed({10'd0, h})) ? h : v[7:0];
    end
endfunction

function automatic signed [8:0] ramp(input signed [8:0] v, input up, input dn, input [7:0] k);
    reg signed [10:0] n, w, kk;
    begin
        w  = {{2{v[8]}}, v};
        kk = $signed({3'd0, k});
        n  = (up && !dn) ? w + kk : (dn && !up) ? w - kk : (w > kk) ? w - kk : (w < -kk) ? w + kk : 11'sd0;
        ramp = (n > 11'sd128) ? 9'sd128 : (n < -11'sd128) ? -9'sd128 : n[8:0];
    end
endfunction

reg  signed [8:0] key_off = 9'sd0;
wire signed [8:0] s    = $signed({stick[7], stick});
wire              live = (s > DZP) || (s < -DZP);

assign val = ad_val(rest, live ? s : key_off, lo, hi);

always @(posedge clk) begin
    if (reset)              key_off <= 9'sd0;
    else if (tick && !pause) key_off <= live ? 9'sd0 : ramp(key_off, inc, dec, keyd);
end

endmodule


//----------------------------------------------------------------------------
// ctl_steer: steering counter (Pole Position pp_steering; MAME IPT_DIAL turned into ticks by a custom chip).
// Spinner (1 count per count) and mouse X (half) are relative; mode 1 analog stick X / mode 2 paddle are
// ABSOLUTE (the counter tracks the device, +-64 counts at full lock); mode 0 D-pad ramps 750 counts / s.
// All feed one pending accumulator that moves steer_pos at most one count per tick (clk / 16384), so a
// signed 8-bit delta read by the game never aliases. Sensitivity / direction as ctl_paddle.
// Pause: steer_pos, the backlog and the tick divider hold; spinner / mouse / D-pad / wheel / paddle motion arriving
//   while paused is discarded (the absolute target keeps tracking, so nothing jumps on resume); a backlog from before
//   the pause keeps slewing after it. Same in v1.
//----------------------------------------------------------------------------
module ctl_steer
(
    input        clk,
    input        reset,
    input  tri0  pause,
    input  [1:0] mode,                // 0 D-pad, 1 analog stick / wheel, 2 paddle
    input  [2:0] sensitivity,
    input        reverse,
    input        left,
    input        right,
    input  [8:0] spinner,
    input        mouse_ev,
    input  [9:0] mouse_dx,
    input  [7:0] analog_x,            // signed
    input  [7:0] paddle,
    output reg [7:0] steer_pos = 8'h80
);

reg [13:0] tdiv = 14'd0;
always @(posedge clk) if (!pause) tdiv <= tdiv + 14'd1;
wire tick = (tdiv == 14'd0) & ~pause;

function automatic signed [15:0] scale_q3(input signed [9:0] v, input [2:0] s);
    reg signed [15:0] e;
    begin
        e = {{6{v[9]}}, v};
        case (s)
            3'd0:    scale_q3 = e <<< 3;
            3'd1:    scale_q3 = (e <<< 2) + (e <<< 1);
            3'd2:    scale_q3 = e <<< 2;
            3'd3:    scale_q3 = e <<< 1;
            3'd4:    scale_q3 = e;
            3'd5:    scale_q3 = (e <<< 3) + (e <<< 1);
            3'd6:    scale_q3 = (e <<< 3) + (e <<< 2);
            default: scale_q3 = e <<< 4;
        endcase
    end
endfunction

reg               spin_seen = 1'b0;
wire              spin_ev   = (spinner[8] != spin_seen);
wire signed [9:0] spin_d    = spin_ev  ? $signed({{2{spinner[7]}}, spinner[7:0]}) : 10'sd0;
wire signed [9:0] mouse_d   = mouse_ev ? $signed(mouse_dx) : 10'sd0;

wire signed [8:0] ana_raw = $signed({analog_x[7], analog_x});
wire signed [8:0] pad_raw = $signed({1'b0, paddle}) - 9'sd128;
wire signed [8:0] abs_raw = (mode == 2'd2) ? pad_raw :
                            ((ana_raw > 9'sd6) || (ana_raw < -9'sd6)) ? ana_raw : 9'sd0;
wire              abs_on  = (mode == 2'd1) || (mode == 2'd2);
wire signed [15:0] abs_tgt = abs_on ? (scale_q3({abs_raw[8], abs_raw}, sensitivity) >>> 1) : 16'sd0;
reg  signed [15:0] abs_last = 16'sd0;

wire signed [15:0] pad_step = (mode == 2'd0 && (left ^ right)) ? (right ? 16'sd2 : -16'sd2) : 16'sd0;

wire signed [15:0] rel_q3  = scale_q3(spin_d, sensitivity) + (scale_q3(mouse_d, sensitivity) >>> 1);
wire signed [15:0] abs_d   = abs_tgt - abs_last;
wire signed [15:0] in_q3   = rel_q3 + (tick ? pad_step : 16'sd0) + abs_d;
wire signed [15:0] dir_q3  = reverse ? -in_q3 : in_q3;

reg  signed [15:0] pending = 16'sd0;
wire signed [15:0] pend_in = pending + dir_q3;
localparam signed [15:0] PEND_MAX = 16'sd2048;        // +-256 counts backlog

reg  [1:0] mode_q = 2'd0;
reg        rev_q  = 1'b0;

always @(posedge clk) begin
    spin_seen <= spinner[8];
    mode_q    <= mode;
    rev_q     <= reverse;
    abs_last  <= abs_tgt;
    if (reset) begin
        steer_pos <= 8'h80;
        pending   <= 16'sd0;
    end
    else if (pause) begin
        pending   <= pending;
    end
    else if (mode != mode_q || reverse != rev_q) begin
        pending   <= 16'sd0;                                // no jump when the OSD mode changes
    end
    else if (tick && pend_in >= 16'sd8) begin
        steer_pos <= steer_pos + 8'd1;
        pending   <= (pend_in - 16'sd8 > PEND_MAX) ? PEND_MAX : pend_in - 16'sd8;
    end
    else if (tick && pend_in <= -16'sd8) begin
        steer_pos <= steer_pos - 8'd1;
        pending   <= (pend_in + 16'sd8 < -PEND_MAX) ? -PEND_MAX : pend_in + 16'sd8;
    end
    else begin
        pending   <= (pend_in > PEND_MAX) ? PEND_MAX : (pend_in < -PEND_MAX) ? -PEND_MAX : pend_in;
    end
end

endmodule


//----------------------------------------------------------------------------
// ctl_pedal: accelerator and brake levels 0..FULL (Pole Position). A held button ramps its pedal +RAMP per
// tick (frame) to FULL (MAME keyboard pedal), released = 0. With analog_en one stick axis drives both:
// up = accelerator, down = brake, |axis| * FULL / 128 with a +-DZ dead zone. A held button wins.
// Pause: the ramps freeze (a held pedal keeps its level and continues ramping after resume); the analog level follows
//   the stick. A button released while paused: PAUSE_MODE 1 clears its ramp at once (a press again before resume
//   starts from 0); PAUSE_MODE 0 (v1) clears it at the first tick after resume (a re-press resumes the old level).
//----------------------------------------------------------------------------
module ctl_pedal #(parameter [7:0] FULL = 8'h90, parameter [7:0] RAMP = 8'd16, parameter [7:0] DZ = 8'd8,
                   parameter int PAUSE_MODE = 0)
(
    input        clk,
    input  tri0  pause,
    input        tick,
    input        accel_btn,
    input        brake_btn,
    input        analog_en,
    input  [7:0] axis,                // signed, up negative
    output [7:0] accel,
    output [7:0] brake
);

wire  [7:0] mag   = axis[7] ? (8'd0 - axis) : axis;   // |axis|, -128 -> 0x80
/* verilator lint_off UNUSED */
wire [15:0] scl   = {8'd0, mag} * {8'd0, FULL};      // bits 14-7 used
/* verilator lint_on UNUSED */
wire  [7:0] lvl   = (mag < DZ) ? 8'h00 : scl[14:7];
wire  [7:0] a_acc = (analog_en &&  axis[7]) ? lvl : 8'h00;
wire  [7:0] a_brk = (analog_en && !axis[7]) ? lvl : 8'h00;

reg [7:0] d_acc = 8'h00, d_brk = 8'h00;
always @(posedge clk) begin
    if (tick && !pause) begin
        d_acc <= !accel_btn ? 8'h00 : (d_acc >= FULL - RAMP) ? FULL : d_acc + RAMP;
        d_brk <= !brake_btn ? 8'h00 : (d_brk >= FULL - RAMP) ? FULL : d_brk + RAMP;
    end
    else if (PAUSE_MODE != 0 && pause) begin
        if (!accel_btn) d_acc <= 8'h00;
        if (!brake_btn) d_brk <= 8'h00;
    end
end

assign accel = accel_btn ? d_acc : a_acc;
assign brake = brake_btn ? d_brk : a_brk;

endmodule


//----------------------------------------------------------------------------
// ctl_gun_cursor: light-gun crosshair (Space Invaders claybust / gunchamp, copied to SegaSys1 Shooting Master).
// Moved by each mouse packet, else once per tick (frame) by the left stick (>>> 4 past +/-12) or the D-pad
// (3 per frame); clamped to 0..XMAX / 0..YMAX. flip negates the movement (CRT Flip turns controls with the
// picture). The trigger is the core's (mouse left / Btn 1 / Ctrl).
// Pause: the cursor holds; mouse / stick / D-pad motion arriving while paused is discarded. Same in v1.
//----------------------------------------------------------------------------
module ctl_gun_cursor #(parameter [7:0] XMAX = 8'd255, parameter [7:0] YMAX = 8'd223,
                        parameter [7:0] X0 = 8'd128, parameter [7:0] Y0 = 8'd112)
(
    input            clk,
    input  tri0      pause,
    input            tick,
    input            flip,
    input            mouse_ev,
    input      [9:0] mouse_dx,
    input      [9:0] mouse_dy,        // down +
    input     [15:0] stick,           // {Y, X} signed
    input      [3:0] dpad,            // {U, D, L, R}
    output reg [7:0] x = X0,
    output reg [7:0] y = Y0
);

wire signed [7:0] ana_x = stick[7:0], ana_y = stick[15:8];
wire signed [9:0] ex = {{2{ana_x[7]}}, ana_x}, ey = {{2{ana_y[7]}}, ana_y};
wire signed [9:0] stick_dx = (ana_x > 8'sd12 || ana_x < -8'sd12) ? (ex >>> 4) :
                             dpad[0] ? 10'sd3 : dpad[1] ? -10'sd3 : 10'sd0;
wire signed [9:0] stick_dy = (ana_y > 8'sd12 || ana_y < -8'sd12) ? (ey >>> 4) :
                             dpad[2] ? 10'sd3 : dpad[3] ? -10'sd3 : 10'sd0;
wire signed [9:0] mdx = mouse_dx, mdy = mouse_dy;
wire signed [9:0] gdx = mouse_ev ? mdx : stick_dx;
wire signed [9:0] gdy = mouse_ev ? mdy : stick_dy;
wire signed [9:0] dx  = flip ? -gdx : gdx;
wire signed [9:0] dy  = flip ? -gdy : gdy;
wire signed [10:0] nx = $signed({3'b000, x}) + {dx[9], dx};
wire signed [10:0] ny = $signed({3'b000, y}) + {dy[9], dy};

always @(posedge clk) begin
    if ((mouse_ev || tick) && !pause) begin
        x <= (nx < 11'sd0) ? 8'd0 : (nx > $signed({3'b000, XMAX})) ? XMAX : nx[7:0];
        y <= (ny < 11'sd0) ? 8'd0 : (ny > $signed({3'b000, YMAX})) ? YMAX : ny[7:0];
    end
end

endmodule
