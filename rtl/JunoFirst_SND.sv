//============================================================================
//
//  Juno First sound board
//  Based on MAME junofrst.cpp audio implementation
//
//  Sound system: Z80 (1.789 MHz) + AY-8910 + i8039 (8 MHz) + 8-bit DAC
//
//============================================================================

module JunoFirst_SND
(
	input                reset,
	input                clk_49m,
	input                clk_8m,

	// Controls/DIP interface (muxed here, read by CPU board)
	input         [15:0] dip_sw,
	input          [1:0] coin,
	input          [1:0] start_buttons,
	input          [3:0] p1_joystick, p2_joystick,
	input                p1_fire,
	input                p2_fire,
	input                p1_warp,
	input                p2_warp,
	input                btn_service,
	input                cpubrd_A5, cpubrd_A6,
	input                cs_controls_dip1, cs_dip2,
	output         [7:0] controls_dip,

	// Sound command interface from CPU board
	input                irq_trigger,
	input                cs_sounddata,
	input          [7:0] cpubrd_Din,

	// Audio output
	output signed [15:0] sound,
    output         [7:0] debug_p1,

	// Pause
	input                pause,

	// FIX-2026-05-24: video PLL underclock signal — needed to compensate
	// the cen_1m79 frac_cen so Z80/AY pitch stays correct when status[21]
	// underclocks CLK_49M ~1% for 60Hz vsync alignment.
	input                underclock,

	// ROM loading
	input                sndrom_cs_i,   // Z80 sound ROM chip select
	input                sndrom_wr,     // Z80 sound ROM write enable (ioctl_wr for index 1)
	input                mcurom_cs_i,   // i8039 MCU ROM chip select
	input                mcurom_wr,     // i8039 MCU ROM write enable (ioctl_wr for index 2)
	input         [24:0] ioctl_addr,
	input          [7:0] ioctl_data
);

//------------------------------------------------------- Controls mux -------------------------------------------------------//

wire [7:0] controls_dip1 =
    ({cpubrd_A6, cpubrd_A5} == 2'b00) ? {3'b111, start_buttons, btn_service, coin} :
    ({cpubrd_A6, cpubrd_A5} == 2'b01) ? {2'b11, p1_fire, p1_warp,
                                          p1_joystick[1], p1_joystick[0],
                                          p1_joystick[3], p1_joystick[2]} :
    ({cpubrd_A6, cpubrd_A5} == 2'b10) ? {2'b11, p2_fire, p2_warp,
                                          p2_joystick[1], p2_joystick[0],
                                          p2_joystick[3], p2_joystick[2]} :
    ({cpubrd_A6, cpubrd_A5} == 2'b11) ? dip_sw[7:0] :
    8'hFF;
assign controls_dip = cs_controls_dip1 ? controls_dip1 :
                      cs_dip2          ? dip_sw[15:8] :
                      8'hFF;

//------------------------------------------------------- Clock generation ---------------------------------------------------//

reg [8:0] div = 9'd0;
always_ff @(posedge clk_49m) begin
	div <= div + 9'd1;
end
wire cen_3m = !div[3:0];
wire cen_dcrm = !div;

// Z80 + AY-8910: 1.789773 MHz target (real hardware: 14.318181 MHz / 8)
// FIX-2026-05-24: video PLL underclock (~1% slow CLK_49M when status[21]=1
// for 60Hz vsync alignment) would otherwise drag the AY ~17 cents flat.
// Conditional n/m compensates so target ~1.789773 MHz is maintained either
// way. Numbers per March-2026 chat history.
//   underclock=0: 49.152  * 30/824 = 1.78951 MHz (0.014% low)
//   underclock=1: ~48.665 * 31/843 = 1.78969 MHz (0.005% low)
// Comment claimed 67/1838 elsewhere but that exceeds 10-bit m and was wrong.
wire [9:0] sound_cen_n = underclock ? 10'd31  : 10'd30;
wire [9:0] sound_cen_m = underclock ? 10'd843 : 10'd824;
wire cen_1m79;
jtframe_frac_cen #(10) sound_cen
(
	.clk(clk_49m),
	.n(sound_cen_n),
	.m(sound_cen_m),
	.cen({9'bZZZZZZZZZ, cen_1m79})
);

//------------------------------------------------------- Sound latch (main CPU -> Z80) --------------------------------------//

reg [7:0] soundlatch = 8'd0;
always_ff @(posedge clk_49m) begin
	if(!reset)
		soundlatch <= 8'd0;
	else if(cen_3m && cs_sounddata)
		soundlatch <= cpubrd_Din;
end

//------------------------------------------------------- Z80 sound CPU ------------------------------------------------------//

wire [15:0] snd_A;
wire [7:0] snd_Dout;
wire n_m1, n_mreq, n_iorq, n_rd, n_wr, n_rfsh;

T80s Z80_snd
(
	.RESET_n(reset),
	.CLK(clk_49m),
	.CEN(cen_1m79 & ~pause),
	.INT_n(snd_n_irq),
	.M1_n(n_m1),
	.MREQ_n(n_mreq),
	.IORQ_n(n_iorq),
	.RD_n(n_rd),
	.WR_n(n_wr),
	.RFSH_n(n_rfsh),
	.A(snd_A),
	.DI(snd_Din),
	.DO(snd_Dout)
);

// Z80 address decoding (MAME audio_map):
//   0x0000-0x0FFF = ROM (4KB)
//   0x2000-0x23FF = RAM (1KB)
//   0x3000        = soundlatch read
//   0x4000        = AY-8910 address write
//   0x4001        = AY-8910 data read
//   0x4002        = AY-8910 data write
//   0x5000        = soundlatch2 write (to i8039)
//   0x6000        = i8039 IRQ trigger
wire cs_sndrom    = (~n_mreq & n_rfsh & (snd_A[15:12] == 4'h0));
wire cs_sndram    = (~n_mreq & n_rfsh & (snd_A[15:10] == 6'b001000));
wire cs_slatch_r  = (~n_mreq & n_rfsh & (snd_A[15:12] == 4'h3) & n_wr);
wire cs_ay_addr   = (~n_mreq & n_rfsh & (snd_A == 16'h4000) & ~n_wr);
wire cs_ay_drd    = (~n_mreq & n_rfsh & (snd_A == 16'h4001) & n_wr);
wire cs_ay_dwr    = (~n_mreq & n_rfsh & (snd_A == 16'h4002) & ~n_wr);
wire cs_slatch2_w = (~n_mreq & n_rfsh & (snd_A[15:12] == 4'h5) & ~n_wr);
wire cs_mcu_irq   = (~n_mreq & n_rfsh & (snd_A[15:12] == 4'h6) & ~n_wr);

// Z80 data input mux
wire [7:0] snd_Din = cs_sndrom              ? sndrom_D :
                     (cs_sndram & n_wr)      ? sndram_D :
                     cs_slatch_r             ? soundlatch :
                     cs_ay_drd               ? ay_D :
                     8'hFF;

// Z80 IRQ — edge detect on irq_trigger (MAME sh_irqtrigger_w: fires on 0->1)
wire irq_clr = (~reset | ~(n_iorq | n_m1));
reg snd_n_irq = 1;
reg last_irq_state = 0;
always_ff @(posedge clk_49m) begin
	if(!reset) begin
		snd_n_irq <= 1;
		last_irq_state <= 0;
	end
	else begin
		if(irq_clr)
			snd_n_irq <= 1;
		else if(irq_trigger && !last_irq_state)
			snd_n_irq <= 0;
		last_irq_state <= irq_trigger;
	end
end

//------------------------------------------------------- Z80 ROM & RAM -----------------------------------------------------//

wire [7:0] sndrom_D;
eprom_4k snd_rom
(
	.ADDR(snd_A[11:0]),
	.CLK(clk_49m),
	.DATA(sndrom_D),
	.ADDR_DL(ioctl_addr),
	.CLK_DL(clk_49m),
	.DATA_IN(ioctl_data),
	.CS_DL(sndrom_cs_i),
	.WR(sndrom_wr)
);

wire [7:0] sndram_D;
spram #(8, 10) snd_ram
(
	.clk(clk_49m),
	.we(cs_sndram & ~n_wr),
	.addr(snd_A[9:0]),
	.data(snd_Dout),
	.q(sndram_D)
);

//------------------------------------------------------- Soundlatch2 (Z80 -> i8039) ----------------------------------------//

reg [7:0] soundlatch2 = 8'd0;
always_ff @(posedge clk_49m) begin
	if(!reset)
		soundlatch2 <= 8'd0;
	else if (cen_1m79 && cs_slatch2_w)
		soundlatch2 <= snd_Dout;
end

//------------------------------------------------------- i8039 IRQ ----------------------------------------------------------//

// Sync Z80 write to 0x6000 into MCU domain as a *level* (held until MCU clears it)
reg [2:0] mcu_irq_sync = 3'b111;   // start inactive
always_ff @(posedge clk_8m) begin
    mcu_irq_sync <= {mcu_irq_sync[1:0], cs_mcu_irq};
end
wire synced_mcu_irq = mcu_irq_sync[2];   // clean level in MCU domain

// IRQ latch — exactly as real hardware / MAME does it
// Z80 write → assert INT (active low)
// MCU writes P2.7 low → clear latch
reg mcu_irq_latch_n = 1'b1;
always_ff @(posedge clk_8m) begin
    if (!reset)                    // reset polarity matches the rest of the module
        mcu_irq_latch_n <= 1'b1;
    else if (synced_mcu_irq)       // ←←← LEVEL, not edge
        mcu_irq_latch_n <= 1'b0;
    else if (!mcu_p2_out[7])       // MCU cleared it
        mcu_irq_latch_n <= 1'b1;
end

//------------------------------------------------------- i8039 MCU ---------------------------------------------------------//

wire [7:0] mcu_db_o;
wire [7:0] mcu_p1_out;
wire [7:0] mcu_p2_out;
wire       mcu_rd_n;
wire       mcu_psen_n;
wire       mcu_ale;

// Program-fetch address = {P2[3:0], ALE-latched db_o[7:0]} (canonical MCS-48
// multiplexed bus — matches the working Gyruss core's GYRUSS_SOUND.v:473-477).
reg  [7:0] mcu_pcad_latch = 8'h00;
always @(negedge mcu_ale) mcu_pcad_latch <= mcu_db_o;
wire [11:0] mcu_prog_addr = {mcu_p2_out[3:0], mcu_pcad_latch};

// MCU ROM (4KB) - jfs2_p4.bin
wire [7:0] mcurom_D;

// DIAG-REVERT-2026-05-25: ROM-integrity walker. After a settle delay,
// sweeps all 4096 addresses on clk_8m, XORing each byte. Expected XOR
// signature for jfs2_p4.bin = 8'h37. LED reports match post-walk. During
// the walk the 8039 is held in reset (see reset_n_i wiring on the
// t8039_notri instance below). The 10-second reset hold is what made
// the DAC work — its precise role is still being investigated.
reg [25:0] walker_settle    = 26'h0;
reg [12:0] walker_addr      = 13'h0;
reg [7:0]  walker_xor       = 8'h0;
reg        walker_done      = 1'b0;
reg [1:0]  walker_state     = 2'h0;
wire       walker_running   = (&walker_settle) & ~walker_done;
always @(posedge clk_8m) begin
    if (!reset) begin
        walker_settle <= 26'h0;
        walker_addr   <= 13'h0;
        walker_xor    <= 8'h0;
        walker_done   <= 1'b0;
        walker_state  <= 2'h0;
    end else if (!(&walker_settle)) begin
        walker_settle <= walker_settle + 26'h1;
    end else if (!walker_done) begin
        case (walker_state)
            2'd0: walker_state <= 2'd1;
            2'd1: begin
                walker_xor   <= walker_xor ^ mcurom_D;
                walker_state <= 2'd2;
            end
            2'd2: begin
                if (walker_addr == 13'd4095) walker_done <= 1'b1;
                walker_addr  <= walker_addr + 13'h1;
                walker_state <= 2'd0;
            end
            default: walker_state <= 2'd0;
        endcase
    end
end
wire        rom_xor_match = walker_done & (walker_xor == 8'h37);
wire [11:0] mcurom_addr   = walker_running ? walker_addr[11:0] : mcu_prog_addr;

eprom_4k mcu_rom
(
	.ADDR(mcurom_addr),
	.CLK(clk_8m),
	.DATA(mcurom_D),
	.ADDR_DL(ioctl_addr),
	.CLK_DL(clk_49m),
	.DATA_IN(ioctl_data),
	.CS_DL(mcurom_cs_i),
	.WR(mcurom_wr)
);

// Sound command latch (Z80 -> 8039 via MOVX). Cross from clk_49m to clk_8m.
reg [7:0] soundlatch2_sync1, soundlatch2_sync2;
always_ff @(posedge clk_8m) begin
    soundlatch2_sync1 <= soundlatch2;
    soundlatch2_sync2 <= soundlatch2_sync1;
end

// db_i mux (Gyruss GYRUSS_SOUND.v:479):
//   PSEN_n asserted → program ROM byte
//   RD_n   asserted → soundlatch2 (MOVX read of Z80 command)
//   else            → 8'hFF (pull-ups)
wire [7:0] mcu_db_in = ~mcu_psen_n ? mcurom_D       :
                      ~mcu_rd_n   ? soundlatch2_sync2 :
                                    8'hFF;

// 8039 via t8039_notri — Arnim Laeuger's canonical 8039 toplevel. Wraps
// t48_core with the correct xtal3 loopback / reset-polarity / RAM contract,
// and exposes the multiplexed MCS-48 bus (ale_o / psen_n_o / rd_n_o / wr_n_o /
// db). External program ROM is fetched via db_i gated by psen_n, just like
// real hardware and like the working Gyruss core.
//
// gate_port_input_g defaults to 1 (real 8039 quasi-bidirectional port
// behavior: p1_i / p2_i AND'd with the output register).
t8039_notri i8039_mcu (
	.xtal_i(clk_8m),
	.xtal_en_i(~pause),
	// DIAG-REVERT-2026-05-25: hold 8039 in reset while the ROM walker
	// runs. This was the configuration that produced working DAC audio.
	.reset_n_i(reset & walker_done),
	// T0 / T1 tied LOW to match the working Gyruss core (which leaves these
	// ports unconnected → VHDL/Verilog default = 0).
	.t0_i(1'b0),
	.t0_o(),
	.t0_dir_o(),
	.t1_i(1'b0),
	.int_n_i(mcu_irq_latch_n),
	.ea_i(1'b1),                      // external program ROM (8039 has no internal ROM)
	.rd_n_o(mcu_rd_n),
	.psen_n_o(mcu_psen_n),
	.wr_n_o(),
	.ale_o(mcu_ale),
	.db_i(mcu_db_in),
	.db_o(mcu_db_o),
	.db_dir_o(),
	.p1_i(8'hFF),
	.p1_o(mcu_p1_out),
	.p1_low_imp_o(),
	.p2_i(8'hFF),
	.p2_o(mcu_p2_out),
	.p2l_low_imp_o(),
	.p2h_low_imp_o(),
	.prog_n_o()
);

// i8039 status fed back to Z80 via AY port A (bits 2:0)
wire [2:0] i8039_status = mcu_p2_out[6:4];

//------------------------------------------------------- AY-8910 -----------------------------------------------------------//

// Port A read: timer[3:0] in bits 7:4, i8039_status in bits 2:0
// Timer = Z80 cycle count / 512 (MAME: total_cycles / (1024/2))
reg [12:0] snd_cycle_cnt = 13'd0;
always_ff @(posedge clk_49m) begin
	if(!reset)
		snd_cycle_cnt <= 13'd0;
	else if(cen_1m79)
		snd_cycle_cnt <= snd_cycle_cnt + 13'd1;
end
wire [3:0] ay_timer = snd_cycle_cnt[12:9];
wire [7:0] ay_portA_in = {ay_timer, 1'b0, i8039_status};

// BC1/BDIR for AY-8910
wire ay_bdir = cs_ay_addr | cs_ay_dwr;
wire ay_bc1  = cs_ay_addr | cs_ay_drd;

wire [7:0] ay_D;
wire [7:0] ayA_raw, ayB_raw, ayC_raw;

jt49_bus #(.COMP(3'b100)) AY1
(
	.rst_n(reset),
	.clk(clk_49m),
	.clk_en(cen_1m79),
	.bdir(ay_bdir),
	.bc1(ay_bc1),
	.din(snd_Dout),
	.sel(0),
	.dout(ay_D),
	.A(ayA_raw),
	.B(ayB_raw),
	.C(ayC_raw),
	.IOA_in(ay_portA_in),
	.IOB_in(8'h00)
);

// Note: AY port B output controls RC filter switching per channel.
// MAME portB_w: bits [1:0]=ch.A filter, [3:2]=ch.B, [5:4]=ch.C
// Each pair selects capacitance: bit0=47nF, bit1=220nF (additive)
// For initial implementation, no dynamic filter switching — just DC removal.
// TODO: Add switchable RC filters for accuracy.

//------------------------------------------------------- DAC output --------------------------------------------------------//

// i8039 P1 -> 8-bit R2R DAC (100K/200K ladder)
// Convert unsigned 8-bit to signed 16-bit
wire signed [15:0] dac_sound = {~mcu_p1_out[7], mcu_p1_out[6:0], 8'd0};

//------------------------------------------------------- Audio mixing ------------------------------------------------------//

// DC offset removal for AY channels
wire signed [15:0] ayA_dcrm, ayB_dcrm, ayC_dcrm;

jt49_dcrm2 #(16) dcrm_A (.clk(clk_49m), .cen(cen_dcrm), .rst(~reset),
                          .din({3'd0, ayA_raw, 5'd0}), .dout(ayA_dcrm));
jt49_dcrm2 #(16) dcrm_B (.clk(clk_49m), .cen(cen_dcrm), .rst(~reset),
                          .din({3'd0, ayB_raw, 5'd0}), .dout(ayB_dcrm));
jt49_dcrm2 #(16) dcrm_C (.clk(clk_49m), .cen(cen_dcrm), .rst(~reset),
                          .din({3'd0, ayC_raw, 5'd0}), .dout(ayC_dcrm));

// FIX-2026-05-24: DAC needs DC removal too — real hardware AC-couples the
// audio analog-side, but our digital mix sums raw. Without this, a stuck
// P1=0xFF (8039 not running) injects +32512 DC into the mix and eats most
// of the dynamic range → AYs clip on positive peaks. Even when the 8039
// runs correctly, typical 8-bit unsigned samples bias around mid-scale and
// would still benefit from being centered.
// FIX-2026-05-25: jt49_dcrm2 expects UNSIGNED input ("input is unsigned" per
// its header comment). Previously we fed dac_sound (signed, with the MSB
// flipped to convert P1 to signed range), which the filter interpreted as
// unsigned with a discontinuity at the sign boundary → filter integrator
// thrashed and the AC output was attenuated / distorted. Feed raw P1
// shifted to the high byte (matches the pattern used by the AY voices).
wire signed [15:0] dac_dcrm;
jt49_dcrm2 #(16) dcrm_DAC (.clk(clk_49m), .cen(cen_dcrm), .rst(~reset),
                            .din({mcu_p1_out, 8'd0}), .dout(dac_dcrm));

// DIAG-REVERT-2026-05-25e: full mix with DAC boosted ×4. AY voices were
// audible but DAC was way too quiet at unity gain — typical because the
// 8039 doesn't drive P1 across the full 0..255 range, so dac_dcrm AC
// content is narrow vs the 3-voice AY sum.
// Earlier mixes (kept for revert):
// wire signed [17:0] mix = {dac_sound[15], dac_sound[15], dac_sound} <<< 3; // DAC-only
// wire signed [17:0] mix = {dac_sound[15], dac_sound[15], dac_sound}
//                        + ayA_dcrm + ayB_dcrm + ayC_dcrm;                  // raw P1 + AY (saturated)
// wire signed [17:0] mix = ayA_dcrm + ayB_dcrm + ayC_dcrm
//                        + {dac_dcrm[15], dac_dcrm[15], dac_dcrm};          // unity DAC (too quiet)
wire signed [17:0] dac_18 = {dac_dcrm[15], dac_dcrm[15], dac_dcrm};
wire signed [17:0] mix    = ayA_dcrm + ayB_dcrm + ayC_dcrm + dac_18;

// Saturate to 16-bit signed
wire signed [15:0] sound_raw = (mix > 18'sd32767)  ? 16'sd32767 :
                               (mix < -18'sd32768) ? -16'sd32768 :
                               mix[15:0];

// DIAG-REVERT-2026-05-25c: routing through sound_raw now uses the
// "raw P1 + AY" mix above. Hijack disabled to let AY mix in.
// Hijack reference (in case we need to revert again):
// assign sound = pause ? 16'sd0 : {~mcu_p1_out[7], mcu_p1_out[6:0], 8'd0};
assign sound = pause ? 16'sd0 : sound_raw;

// DIAG-REVERT-2026-05-25: LED_USER reports walker XOR match (8'h37).
assign debug_p1 = {mcu_p2_out[7], mcu_irq_latch_n, mcu_p1_out[5:1], rom_xor_match};

endmodule
