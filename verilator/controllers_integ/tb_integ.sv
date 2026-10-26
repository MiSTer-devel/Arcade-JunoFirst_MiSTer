// tb_integ: input-path equivalence test for the controllers.sv wave-2 integration (CTL-2026-10-25).
// new_in = the live top level's input path (library v2), old_* = the pre-integration path, verbatim (gen.py), with the
// intended differences applied by asserted scripted edits: k keyboard acts on press, s pad-2 Start = Start 2 only,
// t trackball dropped-step / opposite-D-pad fix, p pause rule (library pause table), c core-specific (SI trackball).
// Every checked cycle: dut must equal old_all (old + every intended difference), else FAIL. Where dut != old_in, each
// differing bit is classified by the single intent that explains it (dut == old_x in that bit), else "combined".
// Configurations run in 4 modes, a quarter each, in the order 0, 2, 1, 3: bit 0 keyboard events on, bit 1 random pause on. In mode 0 (the
// first quarter: no keyboard, pause never asserted, no history of either) dut must also equal old_base (= old + s + t + c only), i.e. match exactly apart from 2, 3 (and 5).
// Defines: NOUT output bits, CFGN index-1 bytes loaded, CFGS configurations, CYC checked cycles per configuration,
// FIXUP (include fixup.svh = statements run after randomising cfgbytes[]), BREAK (flip one dut bit once: must give FAIL 1).
`ifndef CFGS
 `define CFGS 4
`endif
`ifndef CYC
 `define CYC 50000
`endif
`ifndef CFGN
 `define CFGN 64
`endif
module tb_integ(input clk);
localparam int NO = `NOUT;

wire        CLK_SYS = clk, clk_sys = clk, CLK_49M = clk, CLK_40M = clk, CLK_48M = clk, clk_48 = clk, CLK_24M = clk;
wire        CLK_10M = clk, CLK_12M = clk, clk_12 = clk, clk_24 = clk, CLK_18M = clk, CLK_6M = clk, clk_sys_i = clk;
reg         reset = 1'b0;
reg  [10:0] ps2_key = 11'd0;
reg  [24:0] ps2_mouse = 25'd0;
reg  [15:0] joystick_0 = 16'd0, joystick_1 = 16'd0, joystick_2 = 16'd0, joystick_3 = 16'd0;
reg  [15:0] joystick_r_analog_0 = 16'd0, joystick_r_analog_1 = 16'd0;
reg  [15:0] joystick_l_analog_0 = 16'd0, joystick_l_analog_1 = 16'd0, joystick_analog_0 = 16'd0, joystick_analog_1 = 16'd0;
reg   [8:0] spinner_0 = 9'd0, spinner_1 = 9'd0, spinner_2 = 9'd0, spinner_3 = 9'd0;
reg   [7:0] paddle_0 = 8'h80, paddle_1 = 8'h80;
reg         vblank = 1'b0, vbl = 1'b0, VBlank = 1'b0, pause_cpu = 1'b0, ioctl_download = 1'b0, ioctl_wr = 1'b0;
reg   [7:0] ioctl_index = 8'd0, ioctl_dout = 8'd0;
reg  [24:0] ioctl_addr = 25'd0;
reg  [26:0] ioctl_addr27 = 27'd0;
reg [127:0] status = 128'd0;
reg         an_sel_i = 1'b0;
wire [15:0] joy_la0 = joystick_l_analog_0, joy_la1 = joystick_l_analog_1;

wire [NO-1:0] o_dut, o_a, o_k, o_s, o_t, o_p, o_c, o_base, o_all;
new_in   dut (.*, .o(o_dut));
old_in   rA  (.*, .o(o_a));
old_k    rK  (.*, .o(o_k));
old_s    rS  (.*, .o(o_s));
old_t    rT  (.*, .o(o_t));
old_p    rP  (.*, .o(o_p));
old_c    rC  (.*, .o(o_c));
old_base rBs (.*, .o(o_base));
old_all  rB  (.*, .o(o_all));

localparam int LOAD = 1000 + 4 * (`CFGN + 8);
longint chg = 0, cyc = 0, fail = 0, fail0 = 0, checked = 0, ev_kb = 0, n_pause_cyc = 0, n_pause_on = 0;
longint n_cls[6];   // k s t p c combined
int     cfg = -1, mode = 0, vper = 1600, vcnt = 0;
int     pause_left = 0;
reg   [1:0] coin_p = 2'b00;
reg [31:0] r, r2;
reg  [7:0] cfgbytes[`CFGN];
reg  [7:0] dips[8];
reg [NO-1:0] o_brk, o_prev, d_all, d_x, left;
`ifndef XCODES
 `define XCODES 8'h1C, 8'h1B, 8'h23
`endif
reg  [7:0] codes[16] = '{8'h75, 8'h72, 8'h6B, 8'h74, 8'h14, 8'h11, 8'h16, 8'h1E, 8'h2E, 8'h36, 8'h46, 8'h2C, 8'h4D,
                         `XCODES};                           // XCODES: the core's three extra-table keys

function automatic [15:0] axis2(input [31:0] q);
    reg [7:0] a, b;
    begin
        a = (q[2:0] < 3'd3) ? 8'd0 : (q[2:0] == 3'd3) ? 8'h80 : (q[2:0] == 3'd4) ? 8'h7F : q[15:8];
        b = (q[18:16] < 3'd3) ? 8'd0 : (q[18:16] == 3'd3) ? 8'h80 : (q[18:16] == 3'd4) ? 8'h7F : q[31:24];
        axis2 = {b, a};
    end
endfunction

task automatic new_config();
    cfg++;
    mode = (cfg * 4 / `CFGS == 1) ? 2 : (cfg * 4 / `CFGS == 2) ? 1 : cfg * 4 / `CFGS;   // order 0, 2, 1, 3: no keyboard history before 2
    for (int i = 0; i < `CFGN; i++) begin r = $random; cfgbytes[i] = r[7:0]; end
`ifdef FIXUP
    `include "fixup.svh"
`endif
    for (int i = 0; i < 8; i++) begin r = $random; dips[i] = r[7:0]; end
    r = $random; status = {r, r ^ 32'h5A5A5A5A, ~r, r};
    r = $random; vper = 1200 + r[10:0];
    pause_cpu = 1'b0; pause_left = 0;
    $display("  config %0d: mode %0d (keyboard %s, pause %s), cfg[0..1] %02h %02h, vblank period %0d", cfg, mode,
             mode[0] ? "on" : "off", mode[1] ? "on" : "off", cfgbytes[0], cfgbytes[1], vper);
endtask

always @(negedge clk) begin
    // ---- check (outputs settled after the last posedge)
    if (cyc > 0 && (cyc % (LOAD + `CYC)) > LOAD) begin
        checked++;
        o_brk = o_dut;
        if (o_dut !== o_prev) chg++;
        o_prev = o_dut;
`ifdef BREAK
        if (cyc == 3 * (LOAD + `CYC) / 2) o_brk[0] = ~o_brk[0];
`endif
        if (o_brk !== o_all) begin
            fail++;
            if (fail <= 10) $display("  FAIL @%0d cfg %0d: dut %h old+intended %h old %h", cyc, cfg, o_brk, o_all, o_a);
        end
        else if (mode == 0 && o_brk !== o_base) begin
            fail0++;
            if (fail0 <= 10) $display("  FAIL(mode 0) @%0d cfg %0d: dut %h old+s+t+c %h", cyc, cfg, o_brk, o_base);
        end
        else if (o_brk !== o_a) begin
            d_all = o_brk ^ o_a;
            left  = d_all;
            d_x = left & ~(o_brk ^ o_k); if (d_x != 0) n_cls[0]++; left &= ~d_x;
            d_x = left & ~(o_brk ^ o_s); if (d_x != 0) n_cls[1]++; left &= ~d_x;
            d_x = left & ~(o_brk ^ o_t); if (d_x != 0) n_cls[2]++; left &= ~d_x;
            d_x = left & ~(o_brk ^ o_p); if (d_x != 0) n_cls[3]++; left &= ~d_x;
            d_x = left & ~(o_brk ^ o_c); if (d_x != 0) n_cls[4]++; left &= ~d_x;
            if (left != 0) n_cls[5]++;
        end
        if (pause_cpu) n_pause_cyc++;
    end
    // ---- stimulus
    cyc++;
    if (cyc % (LOAD + `CYC) == 1) begin
        if (cfg + 1 == `CFGS) begin
            $display("RESULT tb_integ: configs %0d, checked cycles %0d, FAIL %0d, FAIL(mode 0 exact) %0d", `CFGS, checked, fail, fail0);
            $display("  dut output changed on %0d checked cycles; key events %0d; paused cycles %0d, pause onsets %0d",
                     chg, ev_kb, n_pause_cyc, n_pause_on);
            $display("  dut != old (all intended), cycles with bits explained by: keyboard %0d, pad-2 Start %0d, trackball %0d, pause %0d, core-specific %0d, only combined %0d",
                     n_cls[0], n_cls[1], n_cls[2], n_cls[3], n_cls[4], n_cls[5]);
            $finish;
        end
        else new_config();
    end
    begin : stim
        longint ph = cyc % (LOAD + `CYC);
        ioctl_wr = 1'b0;
        // config load: index 1 bytes, then index 254 bytes 0-7, with ioctl_download high (as the MRA load)
        if (ph >= 1 && ph < LOAD - 400) begin
            ioctl_download = 1'b1;
            if (ph[1:0] == 2'd0) begin
                int k = int'(ph >> 2) - 1;                  // ph 4 = byte 0
                if (k < `CFGN) begin ioctl_index = 8'd1; ioctl_addr = 25'(k); ioctl_dout = cfgbytes[k]; ioctl_wr = 1'b1; end
                else if (k < `CFGN + 8) begin ioctl_index = 8'd254; ioctl_addr = 25'(k - `CFGN); ioctl_dout = dips[k - `CFGN]; ioctl_wr = 1'b1; end
            end
        end
        else ioctl_download = 1'b0;
        // the OSD rewrites a DIP byte now and then; rare mid-run ioctl_download pulse
        r = $random;
        if (ph > LOAD && r[15:0] == 16'd7) begin ioctl_index = 8'd254; r2 = $random; ioctl_addr = 25'(r2[2:0]); ioctl_dout = r2[15:8]; ioctl_wr = 1'b1; end
        if (ph > LOAD && r[19:0] == 20'd99) ioctl_download = 1'b1;
        ioctl_addr27 = {2'b00, ioctl_addr};
        reset = ioctl_download | (ph > LOAD && r[31:12] == 20'd5);
        // vblank
        vcnt = (vcnt + 1 >= vper) ? 0 : vcnt + 1;
        vblank = vcnt < vper / 8;
        vbl = vblank; VBlank = vblank;
        // pads: a few bits change per cycle, held otherwise
        r = $random;
        if (r[2:0] == 3'd0) joystick_0[r[7:4]] = ~joystick_0[r[7:4]];
        if (r[10:8] == 3'd0) joystick_1[r[15:12]] = ~joystick_1[r[15:12]];
        if (r[18:16] == 3'd0) joystick_2[r[23:20]] = ~joystick_2[r[23:20]];
        if (r[26:24] == 3'd0) joystick_3[r[31:28]] = ~joystick_3[r[31:28]];
        r = $random;
        if (r[11:0] == 12'd0) begin r2 = $random; joystick_0 = r2[15:0]; joystick_1 = r2[31:16]; end
        // coins: own sparse process (a press every ~16k clocks, held ~64), so impulse pulses do not overlap
        if (r[25:12] == 14'd0) coin_p[0] = 1'b1; else if (r[31:26] == 6'd0) coin_p[0] = 1'b0;
        r2 = $random;
        if (r2[13:0] == 14'd0) coin_p[1] = 1'b1; else if (r2[19:14] == 6'd0) coin_p[1] = 1'b0;
        joystick_0[8] = coin_p[0]; joystick_1[8] = coin_p[1];
        // keyboard events
        r = $random;
        if (r[5:0] == 6'd0 && mode[0]) begin
            r2 = $random;
            ps2_key = {~ps2_key[10], r2[0], r2[1] & r2[2], (r2[7:4] < 4'd13 || r2[8]) ? codes[r2[7:4]] : r2[23:16]};
            ev_kb++;
        end
        // analog sticks, paddles, spinners, mouse
        r = $random;
        if (r[7:0] == 8'd0) begin r2 = $random; joystick_r_analog_0 = axis2(r2); end
        if (r[15:8] == 8'd0) begin r2 = $random; joystick_r_analog_1 = axis2(r2); end
        if (r[23:16] == 8'd0) begin r2 = $random; joystick_l_analog_0 = axis2(r2); joystick_analog_0 = joystick_l_analog_0; end
        if (r[31:24] == 8'd0) begin r2 = $random; joystick_l_analog_1 = axis2(r2); joystick_analog_1 = joystick_l_analog_1; end
        r = $random;
        if (r[8:0] == 9'd0) begin r2 = $random; paddle_0 = r2[7:0]; end
        if (r[17:9] == 9'd0) begin r2 = $random; paddle_1 = r2[7:0]; end
        if (r[23:18] == 6'd0) begin r2 = $random; spinner_0 = {~spinner_0[8], r2[7:0]}; end
        if (r[29:24] == 6'd0) begin r2 = $random; spinner_1 = {~spinner_1[8], r2[15:8]}; end
        r = $random;
        if (r[6:0] == 7'd0) begin r2 = $random; spinner_2 = {~spinner_2[8], r2[7:0]}; end
        if (r[13:7] == 7'd0) begin r2 = $random; spinner_3 = {~spinner_3[8], r2[15:8]}; end
        if (r[19:14] == 6'd0) begin r2 = $random; ps2_mouse = {~ps2_mouse[24], r2[23:0]}; end
        if (r[31:20] == 12'd0) an_sel_i = ~an_sel_i;
        // pause: onsets at random; each lasts 1-256 clocks (half), 1-4096 (a quarter) or 1-16384 clocks (a quarter)
        r = $random;
        if (pause_left > 0) begin pause_left--; if (pause_left == 0) pause_cpu = 1'b0; end
        else if (mode[1] && ph > LOAD && r[10:0] == 11'd0) begin
            r2 = $random;
            pause_left = r[13] ? {24'd0, r2[7:0]} + 1 : r[14] ? {20'd0, r2[11:0]} + 1 : {18'd0, r2[13:0]} + 1;
            pause_cpu = 1'b1; n_pause_on++;
        end
    end
end

endmodule
