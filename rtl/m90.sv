//============================================================================
//  Irem M90 for MiSTer FPGA - Main module
//
//  Copyright (C) 2023 Martin Donlon
//
//  This program is free software; you can redistribute it and/or modify it
//  under the terms of the GNU General Public License as published by the Free
//  Software Foundation; either version 2 of the License, or (at your option)
//  any later version.
//
//  This program is distributed in the hope that it will be useful, but WITHOUT
//  ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or
//  FITNESS FOR A PARTICULAR PURPOSE.  See the GNU General Public License for
//  more details.
//
//  You should have received a copy of the GNU General Public License along
//  with this program; if not, write to the Free Software Foundation, Inc.,
//  51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA.
//============================================================================

import board_pkg::*;

module m90 (
    input clk_sys,
    input clk_ram,

    input reset_n,
    output ce_pix,

    input board_cfg_t board_cfg,
    
    input z80_reset_n,

    output [7:0] R,
    output [7:0] G,
    output [7:0] B,

    output HSync,
    output VSync,
    output HBlank,
    output VBlank,

    output [15:0] AUDIO_L,
    output [15:0] AUDIO_R,

    input [3:0] coin,
    input [3:0] start_buttons,
    
    input [9:0] p1_input,
    input [9:0] p2_input,
    input [9:0] p3_input,
    input [9:0] p4_input,

    input [23:0] dip_sw,

    input pause_rq,
    output cpu_paused,

    input cpu_turbo,

    output [24:0] sdr_bg_addr,
    input [63:0] sdr_bg_dout,
    output sdr_bg_req,
    input sdr_bg_rdy,
    output sdr_bg_64bit,

    output reg [24:0] sdr_cpu_addr,
    input [63:0] sdr_cpu_dout,
    output reg sdr_cpu_req,
    input sdr_cpu_rdy,

    input clk_bram,
    input bram_wr,
    input [7:0] bram_data,
    input [19:0] bram_addr,
    input [4:0] bram_cs,

    input ioctl_download,
    input [15:0] ioctl_index,
	input ioctl_wr,
	input [26:0] ioctl_addr,
	input [7:0] ioctl_dout,
	
    input ioctl_upload,
    output [7:0] ioctl_upload_index,
	output [7:0] ioctl_din,
	input ioctl_rd,
    output ioctl_upload_req,

    input [19:0]     hs_address,
    input [7:0]      hs_din,
    output [7:0]      hs_dout,
    input hs_write,
    input hs_read,

    input [1:0] dbg_en_layers,
    input dbg_solid_sprites,

    // Sample ROM PSRAM interface (passed through to core_top)
    output [16:0] sample_rom_addr,
    input   [7:0] sample_rom_data,

    // Diagnostic: palette write monitor + external palette write port
    output reg  palram_wr_seen,          // sticky: CPU has written to palette at least once
    output reg  palram_nonzero_seen = 1'b0, // sticky: CPU has written non-zero to palette
    output reg [10:0] palram_last_wr_addr = 11'h0, // last non-zero write address
    output reg [15:0] palram_last_wr_data = 16'h0, // last non-zero write data
    input        ext_palram_wren,     // external palette write enable
    input [10:0] ext_palram_addr,     // external palette address (word)
    input [15:0] ext_palram_data,     // external palette data

    // Extra CPU-activity diagnostics
    output reg [15:0] dbg_mrd_count = 16'h0,        // saturating count of MRD pulses to ROM
    output reg [19:0] dbg_last_rom_addr = 20'h0,    // most recent ROM fetch addr
    output reg [15:0] dbg_mwr_count = 16'h0,        // saturating count of any MWR pulse
    output reg [15:0] dbg_palram_wr_count = 16'h0,  // saturating count of MWR to palram
    output reg [15:0] dbg_vram_wr_count = 16'h0,    // saturating count of MWR to GA25
    output reg [15:0] dbg_io_wr_count = 16'h0,      // saturating count of IOWR (e.g. interrupt setup)
    // Stricter "is the game actually running" indicators:
    output reg        dbg_vram_nonzero_seen = 1'b0, // CPU has written a non-zero value to VRAM
    output reg [14:0] dbg_vram_last_addr = 15'h0,   // last non-zero VRAM write addr
    output reg [15:0] dbg_vram_last_data = 16'h0,   // last non-zero VRAM write data
    output reg [15:0] dbg_last_iowr_addr = 16'h0,   // last IO write port
    output reg [15:0] dbg_last_iowr_data = 16'h0    // last IO write data
);

assign ioctl_upload_index = 8'd1;

// Register palette output on ce_pix - matches M92 Pocket port approach.
// singleport_unreg_ram gives combinatorial output; registering on ce_pix
// ensures stable colour for the full pixel duration (no mid-pixel glitches).
reg [15:0] rgb_color_r = 16'h0;
always @(posedge clk_sys) begin
    if (ce_pix) rgb_color_r <= palram_dout;
end
wire [15:0] rgb_color = rgb_color_r;
assign R = { rgb_color[4:0], rgb_color[4:2] };
assign G = { rgb_color[9:5], rgb_color[9:7] };
assign B = { rgb_color[14:10], rgb_color[14:12] };

reg paused = 0;
assign cpu_paused = paused;

always @(posedge clk_sys) begin
    if (pause_rq & ~paused) begin
        if (vsync) begin
            paused <= 1;
        end
    end else if (~pause_rq & paused) begin
        paused <= ~vsync;
    end
end


wire ce_6m;
wire ce_13m;
jtframe_frac_cen #(2) pixel_cen
(
    .clk(clk_sys),
    .cen_in(1),
    .n(10'd1),
    .m(10'd3),
    .cen({ce_6m, ce_13m})
);

wire ce_8m, ce_16m;
jtframe_frac_cen #(2) cpu_cen
(
    .clk(clk_sys),
    .cen_in(1),
    .n(10'd2),
    .m(10'd5),
    .cen({ce_8m, ce_16m})
);
wire clock = clk_sys;


wire dma_busy;

wire [15:0] cpu_mem_out;
wire [19:0] cpu_mem_addr;

wire [15:0] cpu_mem_in;

/* Global signals from schematics */
wire cpu_n_mreq, cpu_n_mstb, cpu_n_intak;
wire cpu_n_ube, cpu_r_w, cpu_n_iostb;

wire IOWR = ~cpu_n_iostb & ~cpu_r_w; // IO Write
wire IORD = ~cpu_n_iostb & cpu_r_w; // IO Read
wire MWR = ~cpu_n_mreq & ~cpu_n_mstb & ~cpu_r_w; // Mem Write
wire MRD = ~cpu_n_mreq & cpu_n_iostb & cpu_r_w; // Mem Read

wire INTACK = ~cpu_n_intak;

wire [19:0] cpu_word_addr = { cpu_mem_addr[19:1], 1'b0 };
wire [15:0] cpu_rom_data;
wire [15:0] cpu_ram_dout;
wire [19:0] cpu_rom_addr;

wire cpu_rom_memrq;
wire cpu_ram_memrq;
wire ga25_memrq;
wire palram_memrq;

wire [7:0] snd_latch_dout;
wire snd_latch_rdy;

reg [15:0] deferred_ce;
wire ga25_busy;
wire cpu_rom_ready;


always @(posedge clk_sys) begin
    if (!reset_n) begin
        deferred_ce <= 16'd0;
    end else begin
        if (ce_16m) begin
            if (~cpu_rom_ready) begin
                deferred_ce <= deferred_ce + 16'd1;
            end else if (|deferred_ce) begin 
                deferred_ce <= deferred_ce - 16'd1;
            end
        end
    end
end

wire ce_cpu = ~paused & cpu_rom_ready & (ce_16m | cpu_turbo | |deferred_ce);

wire hs_access = hs_read | hs_write;
assign hs_dout = hs_address[0] ? cpu_ram_dout[15:8] : cpu_ram_dout[7:0];

singleport_ram #(.widthad(15), .width(8), .name("CPU0")) cpu_ram_0(
    .clock(clk_sys),
    .address(hs_access ? hs_address[15:1] : cpu_mem_addr[15:1]),
    .q(cpu_ram_dout[7:0]),
    .wren(hs_access ? (hs_write & ~hs_address[0]) : (cpu_ram_memrq & MWR & ~cpu_mem_addr[0])),
    .data(hs_access ? hs_din : cpu_mem_out[7:0])
);

singleport_ram #(.widthad(15), .width(8), .name("CPU1")) cpu_ram_1(
    .clock(clk_sys),
    .address(hs_access ? hs_address[15:1] : cpu_mem_addr[15:1]),
    .q(cpu_ram_dout[15:8]),
    .wren(hs_access ? (hs_write & hs_address[0]) : (cpu_ram_memrq & MWR & ~cpu_n_ube)),
    .data(hs_access ? hs_din : cpu_mem_out[15:8])
);

rom_cache rom_cache(
    .clk(clk_sys),
    .ce(1),
    .reset(~reset_n),

    .clk_ram(clk_ram),
    
    .sdr_addr(sdr_cpu_addr),
    .sdr_data(sdr_cpu_dout),
    .sdr_req(sdr_cpu_req),
    .sdr_rdy(sdr_cpu_rdy),

    .read(MRD & cpu_rom_memrq),
    .rom_word_addr(cpu_rom_addr[19:1]),
    .rom_data(cpu_rom_data),
    .rom_ready(cpu_rom_ready)
);

wire rom0_ce, rom1_ce, ram_cs2;

reg [3:0] bank_select = 4'd0;


// TODO - needs to be adjusted
wire [7:0] switches_p1 = { p1_input[4], p1_input[5], p1_input[6], p1_input[7],      p1_input[3], p1_input[2], p1_input[1], p1_input[0] };
wire [7:0] switches_p2 = { p2_input[4], p2_input[5], p2_input[6], p2_input[7],      p2_input[3], p2_input[2], p2_input[1], p2_input[0] };
wire [7:0] switches_p3 = { p3_input[4], p3_input[5], coin[2],     start_buttons[2], p3_input[3], p3_input[2], p3_input[1], p3_input[0] };
wire [7:0] switches_p4 = { p4_input[4], p4_input[5], coin[3],     start_buttons[3], p4_input[3], p4_input[2], p4_input[1], p4_input[0] };

wire [15:0] switches_p1_p2 = { ~switches_p2, ~switches_p1 };
wire [15:0] switches_p3_p4 = { ~switches_p4, ~switches_p3 };

wire [15:0] flags = { 8'h00, 1'b0, 1'b1, 1'b1 /*TEST*/, 1'b1 /*R*/, ~coin[1:0], ~start_buttons[1:0] };

wire NL = dip_sw[8];

reg sound_reset = 0;

// TODO BANK, CBLK, NL
always @(posedge clk_sys) begin
    if (~reset_n) begin
        bank_select <= 4'd0;
    end else begin
        if (IOWR && cpu_word_addr == 8'h04) bank_select <= cpu_mem_out[3:0];
    end
end

wire [15:0] ga25_dout;

// mux io and memory reads
always_comb begin
    if (INTACK) begin
        cpu_mem_in = { 8'd0, int_vector };
    end else if (MRD) begin
        if (ga25_memrq) cpu_mem_in = ga25_dout;
        else if (palram_memrq & ~cpu_n_mreq) cpu_mem_in = palram_dout;
        else if (cpu_rom_memrq) cpu_mem_in = cpu_rom_data;
        else cpu_mem_in = cpu_ram_dout;
    end else if (IORD) begin
        case ({cpu_word_addr[7:0]})
        8'h00: cpu_mem_in = switches_p1_p2;
        8'h02: cpu_mem_in = flags;
        8'h04: cpu_mem_in = ~dip_sw[15:0];
        8'h06: cpu_mem_in = switches_p3_p4;
        default: cpu_mem_in = 16'hffff;
        endcase
    end else begin
        cpu_mem_in = 16'hffff;
    end
end

wire int_req;
wire [7:0] int_vector;

V35 v35(
    .clk(clk_sys),
    .ce(ce_cpu),

    // Pins
    .n_reset(reset_n),
    .ready(~ga25_busy),
    .n_poll(1),

    .n_ube(cpu_n_ube),
    .r_w(cpu_r_w),
    .n_iostb(cpu_n_iostb),
    .n_mstb(cpu_n_mstb),
    .n_mreq(cpu_n_mreq),

    .n_intak(cpu_n_intak),
    .intreq(0),
    .nmi(0),

    .n_intp0(vblank),
    .n_intp1(1),
    .n_intp2(1),

    .addr(cpu_mem_addr),
    .dout(cpu_mem_out),
    .din(cpu_mem_in),

    .turbo(cpu_turbo),

    .secure(board_cfg.secure),
    .secure_wr(bram_wr & bram_cs[0]),
    .secure_addr(bram_addr[7:0]),
    .secure_byte(bram_data[7:0])
);

address_translator address_translator(
    .A(cpu_mem_addr),
    .board_cfg(board_cfg),
    .cpu_rom_memrq(cpu_rom_memrq),
    .cpu_ram_memrq(cpu_ram_memrq),
    .rom_addr(cpu_rom_addr),

    .ga25_memrq,
    .palram_memrq,

    .bank_select
);

wire vblank, hblank, vsync, hsync;

assign HSync = hsync;
assign HBlank = hblank;
assign VSync = vsync;
assign VBlank = vblank;

wire [10:0] ga25_color;

// Palette RAM: direct CPU write (no delay needed - timing analysis confirms
// MWR and cpu_mem_out are both stable at the capture edge).
// palram_wr_seen: sticky diagnostic flag, latches when CPU writes palette.
always @(posedge clk_sys) begin
    if (MWR & palram_memrq) palram_wr_seen <= 1'b1;
    if (MWR & palram_memrq & (cpu_mem_out != 16'h0)) begin
        palram_nonzero_seen <= 1'b1;
        palram_last_wr_addr <= cpu_mem_addr[11:1];
        palram_last_wr_data <= cpu_mem_out;
    end
end

// CPU activity diagnostics (saturating counters in clk_sys domain).
// These run regardless of reset state - they show whether the CPU has
// actually started executing instructions, and what regions it accesses.
// Cleared on reset; counters saturate at 0xFFFF.
reg mrd_prev = 1'b0, mwr_prev = 1'b0, iowr_prev = 1'b0;
always @(posedge clk_sys) begin
    mrd_prev  <= MRD;
    mwr_prev  <= MWR;
    iowr_prev <= IOWR;

    if (~reset_n) begin
        dbg_mrd_count        <= 16'h0;
        dbg_mwr_count        <= 16'h0;
        dbg_palram_wr_count  <= 16'h0;
        dbg_vram_wr_count    <= 16'h0;
        dbg_io_wr_count      <= 16'h0;
        dbg_last_rom_addr    <= 20'h0;
        dbg_vram_nonzero_seen <= 1'b0;
        dbg_vram_last_addr   <= 15'h0;
        dbg_vram_last_data   <= 16'h0;
        dbg_last_iowr_addr   <= 16'h0;
        dbg_last_iowr_data   <= 16'h0;
    end else begin
        // Rising edge of MRD on a ROM access = a CPU instruction fetch / ROM read
        if (MRD & ~mrd_prev & cpu_rom_memrq) begin
            if (dbg_mrd_count != 16'hFFFF) dbg_mrd_count <= dbg_mrd_count + 16'd1;
            dbg_last_rom_addr <= cpu_rom_addr;
        end
        // Rising edge of MWR = a CPU memory write of any kind
        if (MWR & ~mwr_prev) begin
            if (dbg_mwr_count != 16'hFFFF) dbg_mwr_count <= dbg_mwr_count + 16'd1;
            if (palram_memrq) begin
                if (dbg_palram_wr_count != 16'hFFFF) dbg_palram_wr_count <= dbg_palram_wr_count + 16'd1;
            end
            if (ga25_memrq) begin
                if (dbg_vram_wr_count != 16'hFFFF) dbg_vram_wr_count <= dbg_vram_wr_count + 16'd1;
                if (cpu_mem_out != 16'h0) begin
                    dbg_vram_nonzero_seen <= 1'b1;
                    dbg_vram_last_addr <= cpu_mem_addr[15:1];
                    dbg_vram_last_data <= cpu_mem_out;
                end
            end
        end
        // Rising edge of IOWR = any IO write
        if (IOWR & ~iowr_prev) begin
            if (dbg_io_wr_count != 16'hFFFF) dbg_io_wr_count <= dbg_io_wr_count + 16'd1;
            dbg_last_iowr_addr <= cpu_mem_addr;
            dbg_last_iowr_data <= cpu_mem_out;
        end
    end
end

// Palette RAM: original BRAM (singleport_ram).
// Force entry 1 = white via a small reg override for diagnostic.
wire [15:0] palram_q;
singleport_unreg_ram #(.widthad(11), .width(16), .name("PALRAM")) palram(
    .clock(clk_sys),
    .address((palram_memrq & ~cpu_n_mreq) ? cpu_mem_addr[11:1] : ga25_color),
    .q(palram_q),
    .wren(MWR & palram_memrq),
    .data(cpu_mem_out)
);
// Force palette[1] = white to test if ga25_color ever reaches 1
wire [15:0] palram_dout = palram_q;



GA25 ga25(
    .clk(clk_sys),
    .clk_ram(clk_ram),

    .ce(ce_13m),
    .ce_pix(ce_pix),

    .reset(~reset_n),

    .paused(paused),

    .mem_cs(ga25_memrq),
    .mem_wr(MWR),
    .mem_rd(MRD),
    .io_wr(IOWR),

    .busy(ga25_busy),

    .addr(cpu_mem_addr),
    .cpu_din(cpu_mem_out),
    .cpu_dout(ga25_dout),
    

    .NL(NL),

    .sdr_data(sdr_bg_dout),
    .sdr_addr(sdr_bg_addr),
    .sdr_req(sdr_bg_req),
    .sdr_rdy(sdr_bg_rdy),
    .sdr_64bit(sdr_bg_64bit),

    .vblank(vblank),
    .hblank(hblank),
    .vsync(vsync),
    .hsync(hsync),

    .color_out(ga25_color),

    .dbg_en_layers(dbg_en_layers),
    .dbg_solid_sprites(dbg_solid_sprites)
);

wire [15:0] sound_sample;
sound sound(
    .clk(clk_sys),
    .reset(~reset_n),

    .paused(paused),

    .m99(board_cfg.m99),

    .latch_wr(IOWR & cpu_word_addr[7:0] == 8'h00),
    .latch_din(cpu_mem_out[7:0]),
    
    .bram_addr(bram_addr),
    .bram_data(bram_data),
    .bram_wr(bram_wr),
    .bram_z80_cs(bram_cs[1]),
    .bram_sample_cs(bram_cs[2]),

    .sample_rom_addr(sample_rom_addr),
    .sample_rom_data(sample_rom_data),

    .sound_out(sound_sample)
);

assign AUDIO_L = sound_sample;
assign AUDIO_R = sound_sample;

endmodule
