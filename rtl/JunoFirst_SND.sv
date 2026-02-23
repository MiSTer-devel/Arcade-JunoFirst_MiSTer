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

	// Controls/DIP interface (muxed here, read by CPU board)
	input         [15:0] dip_sw,
	input          [1:0] coin,
	input          [1:0] start_buttons,
	input          [3:0] p1_joystick, p2_joystick,
	input                p1_fire,
	input                p2_fire,
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

	// Underclock selection
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

wire [7:0] controls_dip1 = ({cpubrd_A6, cpubrd_A5} == 2'b00) ? {3'b111, start_buttons, btn_service, coin} :
                           ({cpubrd_A6, cpubrd_A5} == 2'b01) ? {3'b111, p1_fire, p1_joystick[1:0], p1_joystick[3:2]} :
                           ({cpubrd_A6, cpubrd_A5} == 2'b10) ? {3'b111, p2_fire, p2_joystick[1:0], p2_joystick[3:2]} :
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

// Z80 + AY-8910: ~1.789772 MHz
wire [9:0] sound_cen_n = underclock ? 10'd31 : 10'd30;
wire [9:0] sound_cen_m = underclock ? 10'd843 : 10'd824;
wire cen_1m79;
jtframe_frac_cen #(10) sound_cen
(
	.clk(clk_49m),
	.n(sound_cen_n),
	.m(sound_cen_m),
	.cen({9'bZZZZZZZZZ, cen_1m79})
);

// i8039: ~8 MHz from 49.152 MHz
// 49.152 / 6 = 8.192 MHz (close to 8 MHz, standard MiSTer approximation)
reg [2:0] mcu_div = 3'd0;
wire cen_8m = (mcu_div == 3'd0);
always_ff @(posedge clk_49m) begin
	mcu_div <= (mcu_div == 3'd5) ? 3'd0 : mcu_div + 3'd1;
end

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
	.CEN(cen_1m79),
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
	else if(cs_slatch2_w)
		soundlatch2 <= snd_Dout;
end

//------------------------------------------------------- i8039 IRQ ----------------------------------------------------------//

// Z80 writes to 0x6000 -> asserts i8039 INT
// i8039 clears its own IRQ via P2 bit 7 (inverted)
reg mcu_int_n = 1;
always_ff @(posedge clk_49m) begin
	if(!reset)
		mcu_int_n <= 1;
	else begin
		if(cs_mcu_irq)
			mcu_int_n <= 0;
		else if(!mcu_p2_out[7])   // i8039 clears IRQ by writing P2 bit 7 low
			mcu_int_n <= 1;
	end
end

//------------------------------------------------------- i8039 MCU ---------------------------------------------------------//

wire [7:0] mcu_db_o;
wire [7:0] mcu_p1_out;
wire [7:0] mcu_p2_out;
wire mcu_rd_n;

// t48_core provides direct pmem_addr_o (12-bit) — no ALE latching needed!
wire [11:0] mcu_prog_addr;

// MCU ROM (4KB) - jfs2_p4.bin
wire [7:0] mcurom_D;
eprom_4k mcu_rom
(
	.ADDR(mcu_prog_addr),
	.CLK(clk_49m),
	.DATA(mcurom_D),
	.ADDR_DL(ioctl_addr),
	.CLK_DL(clk_49m),
	.DATA_IN(ioctl_data),
	.CS_DL(mcurom_cs_i),
	.WR(mcurom_wr)
);

// MCU internal RAM (128 bytes for 8039)
wire [7:0] mcu_dmem_addr;
wire mcu_dmem_we;
wire [7:0] mcu_dmem_din;
wire [7:0] mcu_dmem_dout;

spram #(8, 7) mcu_ram   // 8-bit wide, 7-bit address = 128 bytes
(
	.clk(clk_49m),
	.we(mcu_dmem_we),
	.addr(mcu_dmem_addr[6:0]),
	.data(mcu_dmem_dout),
	.q(mcu_dmem_din)
);

// MCU external data bus: MOVX reads return soundlatch2
wire [7:0] mcu_db_in = soundlatch2;

t48_core #(
	.xtal_div_3_g(1),
	.register_mnemonic_g(1),
	.include_port1_g(1),
	.include_port2_g(1),
	.include_bus_g(1),
	.include_timer_g(1),
	.sample_t1_state_g(4)
) i8039_mcu (
	// Crystal / clock
	.xtal_i(clk_49m),
	.xtal_en_i(cen_8m),
	.reset_i(~reset),              // Active HIGH reset
	// Test pins
	.t0_i(1'b1),
	.t0_o(),
	.t0_dir_o(),
	.t1_i(1'b1),
	// Interrupt
	.int_n_i(mcu_int_n),
	// External access = always external ROM for 8039
	.ea_i(1'b1),
	// Bus control
	.rd_n_o(mcu_rd_n),
	.psen_n_o(),
	.wr_n_o(),
	.ale_o(),
	// External data bus (for MOVX instructions)
	.db_i(mcu_db_in),
	.db_o(mcu_db_o),
	.db_dir_o(),
	// Port 1: DAC output
	.p1_i(8'hFF),
	.p1_o(mcu_p1_out),
	.p1_low_imp_o(),
	// Port 2: status + IRQ control
	.p2_i(8'hFF),
	.p2_o(mcu_p2_out),
	.p2l_low_imp_o(),
	.p2h_low_imp_o(),
	// PROG pin
	.prog_n_o(),
	// System clock domain
	.clk_i(clk_49m),
	.en_clk_i(cen_8m),
	.xtal3_o(),
	// Internal RAM (128 bytes)
	.dmem_addr_o(mcu_dmem_addr),
	.dmem_we_o(mcu_dmem_we),
	.dmem_data_i(mcu_dmem_din),
	.dmem_data_o(mcu_dmem_dout),
	// Program ROM (4KB direct interface)
	.pmem_addr_o(mcu_prog_addr),
	.pmem_data_i(mcurom_D)
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
	.sel(1),
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

// Mix AY (3 channels at 0.30 each from MAME) + DAC (0.25 from MAME)
wire signed [17:0] mix = ayA_dcrm + ayB_dcrm + ayC_dcrm + dac_sound;

// Saturate to 16-bit signed
assign sound = (mix > 18'sd32767)  ? 16'sd32767 :
               (mix < -18'sd32768) ? -16'sd32768 :
               mix[15:0];

endmodule
