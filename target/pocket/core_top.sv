//============================================================================
// Irem M90/M99 Arcade Core for Analogue Pocket
//
// Port of the MiSTer FPGA core by Martin Donlon (wickerwaka)
// Analogue Pocket port by flynny, 2024-2026
//
// This module is the top-level bridge between the Analogue Pocket APF
// framework (apf_top.v) and the Irem M90 game hardware RTL (m90.sv).
//
// Key hardware:
//   NEC V35 @ 14.318 MHz  - Main CPU
//   Z80    @ 3.579 MHz   - Sound CPU
//   YM2151 OPM           - FM sound
//   GA25 custom          - Graphics (BG tiles + sprites)
//   PSRAM cram0          - GFX ROM / CPU ROM (via PSRAM arbiter)
//   PSRAM cram1          - PCM sample ROM (via sample_rom_psram bridge)
//============================================================================

`default_nettype none

import board_pkg::*;

module core_top (

    //------------------------------------------------------------------------
    // Clocks
    //------------------------------------------------------------------------
    input   wire            clk_74a,
    input   wire            clk_74b,

    //------------------------------------------------------------------------
    // Cartridge (unused - arcade core)
    //------------------------------------------------------------------------
    inout   wire    [7:0]   cart_tran_bank2,
    output  wire            cart_tran_bank2_dir,
    inout   wire    [7:0]   cart_tran_bank3,
    output  wire            cart_tran_bank3_dir,
    inout   wire    [7:0]   cart_tran_bank1,
    output  wire            cart_tran_bank1_dir,
    inout   wire    [7:4]   cart_tran_bank0,
    output  wire            cart_tran_bank0_dir,
    inout   wire            cart_tran_pin30,
    output  wire            cart_tran_pin30_dir,
    output  wire            cart_pin30_pwroff_reset,
    inout   wire            cart_tran_pin31,
    output  wire            cart_tran_pin31_dir,

    //------------------------------------------------------------------------
    // IR (unused)
    //------------------------------------------------------------------------
    input   wire            port_ir_rx,
    output  wire            port_ir_tx,
    output  wire            port_ir_rx_disable,

    //------------------------------------------------------------------------
    // Link port (unused)
    //------------------------------------------------------------------------
    inout   wire            port_tran_si,
    output  wire            port_tran_si_dir,
    inout   wire            port_tran_so,
    output  wire            port_tran_so_dir,
    inout   wire            port_tran_sck,
    output  wire            port_tran_sck_dir,
    inout   wire            port_tran_sd,
    output  wire            port_tran_sd_dir,

    //------------------------------------------------------------------------
    // PSRAM cram0 - GFX ROM and CPU ROM
    //------------------------------------------------------------------------
    output  wire    [21:16] cram0_a,
    inout   wire    [15:0]  cram0_dq,
    input   wire            cram0_wait,
    output  wire            cram0_clk,
    output  wire            cram0_adv_n,
    output  wire            cram0_cre,
    output  wire            cram0_ce0_n,
    output  wire            cram0_ce1_n,
    output  wire            cram0_oe_n,
    output  wire            cram0_we_n,
    output  wire            cram0_ub_n,
    output  wire            cram0_lb_n,

    //------------------------------------------------------------------------
    // PSRAM cram1 - PCM sample ROM (driven by sample_rom_psram)
    //------------------------------------------------------------------------
    output  wire    [21:16] cram1_a,
    inout   wire    [15:0]  cram1_dq,
    input   wire            cram1_wait,
    output  wire            cram1_clk,
    output  wire            cram1_adv_n,
    output  wire            cram1_cre,
    output  wire            cram1_ce0_n,
    output  wire            cram1_ce1_n,
    output  wire            cram1_oe_n,
    output  wire            cram1_we_n,
    output  wire            cram1_ub_n,
    output  wire            cram1_lb_n,

    //------------------------------------------------------------------------
    // DRAM (unused)
    //------------------------------------------------------------------------
    output  wire    [12:0]  dram_a,
    output  wire    [1:0]   dram_ba,
    inout   wire    [15:0]  dram_dq,
    output  wire    [1:0]   dram_dqm,
    output  wire            dram_clk,
    output  wire            dram_cke,
    output  wire            dram_ras_n,
    output  wire            dram_cas_n,
    output  wire            dram_we_n,

    //------------------------------------------------------------------------
    // SRAM (unused)
    //------------------------------------------------------------------------
    output  wire    [16:0]  sram_a,
    inout   wire    [15:0]  sram_dq,
    output  wire            sram_oe_n,
    output  wire            sram_we_n,
    output  wire            sram_ub_n,
    output  wire            sram_lb_n,

    //------------------------------------------------------------------------
    // Miscellaneous
    //------------------------------------------------------------------------
    input   wire            vblank,
    output  wire            dbg_tx,
    input   wire            dbg_rx,
    output  wire            user1,
    input   wire            user2,
    inout   wire            aux_sda,
    output  wire            aux_scl,
    output  wire            vpll_feed,

    //------------------------------------------------------------------------
    // Video output
    //------------------------------------------------------------------------
    output  wire    [23:0]  video_rgb,
    output  wire            video_rgb_clock,
    output  wire            video_rgb_clock_90,
    output  wire            video_de,
    output  wire            video_skip,
    output  wire            video_vs,
    output  wire            video_hs,

    //------------------------------------------------------------------------
    // Audio output
    //------------------------------------------------------------------------
    output  wire            audio_mclk,
    input   wire            audio_adc,
    output  wire            audio_dac,
    output  wire            audio_lrck,

    //------------------------------------------------------------------------
    // APF bridge
    //------------------------------------------------------------------------
    output  wire            bridge_endian_little,
    input   wire    [31:0]  bridge_addr,
    input   wire            bridge_rd,
    output  reg     [31:0]  bridge_rd_data,
    input   wire            bridge_wr,
    input   wire    [31:0]  bridge_wr_data,

    //------------------------------------------------------------------------
    // Controllers (4 players)
    //------------------------------------------------------------------------
    input   wire    [31:0]  cont1_key,
    input   wire    [31:0]  cont2_key,
    input   wire    [31:0]  cont3_key,
    input   wire    [31:0]  cont4_key,
    input   wire    [31:0]  cont1_joy,
    input   wire    [31:0]  cont2_joy,
    input   wire    [31:0]  cont3_joy,
    input   wire    [31:0]  cont4_joy,
    input   wire    [15:0]  cont1_trig,
    input   wire    [15:0]  cont2_trig,
    input   wire    [15:0]  cont3_trig,
    input   wire    [15:0]  cont4_trig

);

//============================================================================
// Tie-offs
//============================================================================

// Cartridge slot unused (arcade core)
assign cart_tran_bank3         = 8'hzz;
assign cart_tran_bank3_dir     = 1'b0;
assign cart_tran_bank2         = 8'hzz;
assign cart_tran_bank2_dir     = 1'b0;
assign cart_tran_bank1         = 8'hzz;
assign cart_tran_bank1_dir     = 1'b0;
assign cart_tran_bank0         = 4'hf;
assign cart_tran_bank0_dir     = 1'b1;
assign cart_tran_pin30         = 1'b0;
assign cart_tran_pin30_dir     = 1'bz;
assign cart_pin30_pwroff_reset = 1'b0;
assign cart_tran_pin31         = 1'bz;
assign cart_tran_pin31_dir     = 1'b0;

// IR unused
assign port_ir_tx              = 1'b0;
assign port_ir_rx_disable      = 1'b1;

// Link port unused
assign port_tran_so            = 1'bz;
assign port_tran_so_dir        = 1'b0;
assign port_tran_si            = 1'bz;
assign port_tran_si_dir        = 1'b0;
assign port_tran_sck           = 1'bz;
assign port_tran_sck_dir       = 1'b0;
assign port_tran_sd            = 1'bz;
assign port_tran_sd_dir        = 1'b0;

// cram1 driven by sample_rom_psram instantiation below
// DRAM unused
assign dram_a                  = 13'h0;
assign dram_ba                 = 2'h0;
assign dram_dq                 = {16{1'bZ}};
assign dram_dqm                = 2'h0;
assign dram_clk                = 1'b0;
assign dram_cke                = 1'b0;
assign dram_ras_n              = 1'b1;
assign dram_cas_n              = 1'b1;
assign dram_we_n               = 1'b1;

// SRAM unused
assign sram_a                  = 17'h0;
assign sram_dq                 = {16{1'bZ}};
assign sram_oe_n               = 1'b1;
assign sram_we_n               = 1'b1;
assign sram_ub_n               = 1'b1;
assign sram_lb_n               = 1'b1;

// Misc
assign dbg_tx                  = 1'bZ;
assign user1                   = 1'bZ;
assign aux_scl                 = 1'bZ;
assign vpll_feed               = 1'bZ;
assign video_skip              = 1'b0;
assign bridge_endian_little    = 1'b0;

//============================================================================
// PLL - 74.25 MHz input
//   outclk_0: 57.278571 MHz  (clk_ram  - PSRAM controller)
//   outclk_1: 28.639285 MHz  (clk_sys  - game logic)
//   outclk_2: 28.639285 MHz  (clk_sys2 - video DDR, 90° phase shift)
//============================================================================

wire clk_sys;
wire clk_ram;
wire clk_sys2;
wire pll_core_locked;
wire pll_core_locked_s;

synch_3 s01 (pll_core_locked, pll_core_locked_s, clk_74a);

core_0002 pll_inst (
    .refclk   (clk_74a),
    .rst      (1'b0),
    .outclk_0 (clk_ram),
    .outclk_1 (clk_sys),
    .outclk_2 (clk_sys2),
    .locked   (pll_core_locked)
);

// Video clock: clk_sys used directly - all video regs are in clk_sys domain.

//============================================================================
// APF bridge read mux
// 0xF8xxxxxx: core_bridge_cmd registers
// All other addresses return 0
//============================================================================

always @(*) begin
    casex (bridge_addr)
    default:        bridge_rd_data = 32'h0;
    32'hF8xxxxxx:   bridge_rd_data = cmd_bridge_rd_data;
    endcase
end

//============================================================================
// APF command handler (core_bridge_cmd)
//============================================================================

wire            reset_n;
wire    [31:0]  cmd_bridge_rd_data;

// Core status signals
wire status_boot_done  = pll_core_locked_s;
wire status_setup_done = pll_core_locked_s & ~game_started; // rising edge triggers 0x0140 Ready to Run
wire status_running    = reset_n;           // assert when APF releases reset

// Dataslot - read (unused, always ACK)
wire            dataslot_requestread;
wire    [15:0]  dataslot_requestread_id;
wire            dataslot_requestread_ack = 1'b1;
wire            dataslot_requestread_ok  = 1'b1;

// Dataslot - write (ROM loading)
wire            dataslot_requestwrite;
wire    [15:0]  dataslot_requestwrite_id;
wire    [31:0]  dataslot_requestwrite_size;
wire            dataslot_requestwrite_ack = 1'b1;
wire            dataslot_requestwrite_ok  = 1'b1;

wire            dataslot_update;
wire    [15:0]  dataslot_update_id;
wire    [31:0]  dataslot_update_size;

wire            dataslot_allcomplete;

// RTC
wire    [31:0]  rtc_epoch_seconds;
wire    [31:0]  rtc_date_bcd;
wire    [31:0]  rtc_time_bcd;
wire            rtc_valid;

// Savestate (unsupported)
wire            savestate_supported   = 1'b0;
wire    [31:0]  savestate_addr        = 32'h0;
wire    [31:0]  savestate_size        = 32'h0;
wire    [31:0]  savestate_maxloadsize = 32'h0;

wire            savestate_start;
wire            savestate_start_ack   = 1'b0;
wire            savestate_start_busy  = 1'b0;
wire            savestate_start_ok    = 1'b0;
wire            savestate_start_err   = 1'b0;

wire            savestate_load;
wire            savestate_load_ack    = 1'b0;
wire            savestate_load_busy   = 1'b0;
wire            savestate_load_ok     = 1'b0;
wire            savestate_load_err    = 1'b0;

// OS notifications
wire            osnotify_inmenu;

// Target-initiated dataslot operations (unused)
reg             target_dataslot_read     = 1'b0;
reg             target_dataslot_write    = 1'b0;
reg             target_dataslot_getfile  = 1'b0;
reg             target_dataslot_openfile = 1'b0;

wire            target_dataslot_ack;
wire            target_dataslot_done;
wire    [2:0]   target_dataslot_err;

reg     [15:0]  target_dataslot_id         = 16'h0;
reg     [31:0]  target_dataslot_slotoffset = 32'h0;
reg     [31:0]  target_dataslot_bridgeaddr = 32'h0;
reg     [31:0]  target_dataslot_length     = 32'h0;

wire    [31:0]  target_buffer_param_struct;
wire    [31:0]  target_buffer_resp_struct;

wire    [9:0]   datatable_addr;
wire            datatable_wren;
wire    [31:0]  datatable_data;
wire    [31:0]  datatable_q;

core_bridge_cmd icb (
    .clk                        ( clk_74a ),
    .reset_n                    ( reset_n ),

    .bridge_endian_little       ( bridge_endian_little ),
    .bridge_addr                ( bridge_addr ),
    .bridge_rd                  ( bridge_rd ),
    .bridge_rd_data             ( cmd_bridge_rd_data ),
    .bridge_wr                  ( bridge_wr ),
    .bridge_wr_data             ( bridge_wr_data ),

    .status_boot_done           ( status_boot_done ),
    .status_setup_done          ( status_setup_done ),
    .status_running             ( status_running ),

    .dataslot_requestread       ( dataslot_requestread ),
    .dataslot_requestread_id    ( dataslot_requestread_id ),
    .dataslot_requestread_ack   ( dataslot_requestread_ack ),
    .dataslot_requestread_ok    ( dataslot_requestread_ok ),

    .dataslot_requestwrite      ( dataslot_requestwrite ),
    .dataslot_requestwrite_id   ( dataslot_requestwrite_id ),
    .dataslot_requestwrite_size ( dataslot_requestwrite_size ),
    .dataslot_requestwrite_ack  ( dataslot_requestwrite_ack ),
    .dataslot_requestwrite_ok   ( dataslot_requestwrite_ok ),

    .dataslot_update            ( dataslot_update ),
    .dataslot_update_id         ( dataslot_update_id ),
    .dataslot_update_size       ( dataslot_update_size ),

    .dataslot_allcomplete       ( dataslot_allcomplete ),

    .rtc_epoch_seconds          ( rtc_epoch_seconds ),
    .rtc_date_bcd               ( rtc_date_bcd ),
    .rtc_time_bcd               ( rtc_time_bcd ),
    .rtc_valid                  ( rtc_valid ),

    .savestate_supported        ( savestate_supported ),
    .savestate_addr             ( savestate_addr ),
    .savestate_size             ( savestate_size ),
    .savestate_maxloadsize      ( savestate_maxloadsize ),

    .savestate_start            ( savestate_start ),
    .savestate_start_ack        ( savestate_start_ack ),
    .savestate_start_busy       ( savestate_start_busy ),
    .savestate_start_ok         ( savestate_start_ok ),
    .savestate_start_err        ( savestate_start_err ),

    .savestate_load             ( savestate_load ),
    .savestate_load_ack         ( savestate_load_ack ),
    .savestate_load_busy        ( savestate_load_busy ),
    .savestate_load_ok          ( savestate_load_ok ),
    .savestate_load_err         ( savestate_load_err ),

    .osnotify_inmenu            ( osnotify_inmenu ),
    .osnotify_docked            (                 ),
    .osnotify_grayscale         (                 ),

    .target_dataslot_read       ( target_dataslot_read ),
    .target_dataslot_write      ( target_dataslot_write ),
    .target_dataslot_getfile    ( target_dataslot_getfile ),
    .target_dataslot_openfile   ( target_dataslot_openfile ),

    .target_dataslot_ack        ( target_dataslot_ack ),
    .target_dataslot_done       ( target_dataslot_done ),
    .target_dataslot_err        ( target_dataslot_err ),

    .target_dataslot_id         ( target_dataslot_id ),
    .target_dataslot_slotoffset ( target_dataslot_slotoffset ),
    .target_dataslot_bridgeaddr ( target_dataslot_bridgeaddr ),
    .target_dataslot_length     ( target_dataslot_length ),

    .target_buffer_param_struct ( target_buffer_param_struct ),
    .target_buffer_resp_struct  ( target_buffer_resp_struct ),

    .datatable_addr             ( datatable_addr ),
    .datatable_wren             ( datatable_wren ),
    .datatable_data             ( datatable_data ),
    .datatable_q                ( datatable_q )
);

//============================================================================
// ROM loading
//
// The APF bridge streams ROM data as 32-bit bridge writes to address 0x0xxxxxxx.
// bridge_wr is a single-cycle pulse at 74.25 MHz — too narrow to sample
// directly on clk_sys (28.639 MHz). A toggle synchroniser safely crosses
// the pulse into clk_sys domain. Bridge address and data are latched in
// clk_74a before the toggle fires.
//
// The byte sequencer runs on clk_sys, matching the clock domain of
// rom_loader (rom.sv), so ioctl_wr is never missed.
//
// ROM image format (packed sequential, parsed by rom.sv):
//   byte 0:         board_cfg byte
//   region header:  [region_idx][size_hi][size_mid][size_lo]
//   region data:    <size> bytes
//   ... repeat for each region (CPU ROM, GFX, Z80, samples, key)
//============================================================================

reg        rom_loading   = 1'b0;
reg        rom_loaded    = 1'b0;
reg [26:0] ioctl_addr_r  = 27'h0;
reg  [7:0] ioctl_dout_r  = 8'h0;
reg        ioctl_wr_r    = 1'b0;
reg [31:0] rom_word      = 32'h0;
reg [2:0]  rom_phase     = 3'h0;

// DIP switches written by bridge (clk_74a domain, infrequent updates)
reg [7:0] dip_sw0 = 8'h00;
reg [7:0] dip_sw1 = 8'h00;
reg [7:0] dip_sw2 = 8'h00;

always @(posedge clk_74a) begin
    if (bridge_wr) begin
        case (bridge_addr)
            32'h00000010: dip_sw0 <= bridge_wr_data[7:0];
            32'h00000014: dip_sw1 <= bridge_wr_data[7:0];
            32'h00000018: dip_sw2 <= bridge_wr_data[7:0];
            default: begin end
        endcase
    end
end

// Toggle synchroniser: bridge_wr (clk_74a, 13.5 ns pulse) -> clk_sys
reg bridge_wr_toggle = 1'b0;
reg bridge_wr_t1 = 1'b0, bridge_wr_t2 = 1'b0, bridge_wr_t3 = 1'b0;

always @(posedge clk_74a) begin
    if (bridge_wr) bridge_wr_toggle <= ~bridge_wr_toggle;
end

always @(posedge clk_sys) begin
    bridge_wr_t1 <= bridge_wr_toggle;
    bridge_wr_t2 <= bridge_wr_t1;
    bridge_wr_t3 <= bridge_wr_t2;
end

wire bridge_wr_s = bridge_wr_t2 ^ bridge_wr_t3;

// Latch bridge addr/data in clk_74a
reg [31:0] bridge_addr_lat    = 32'h0;
reg [31:0] bridge_wr_data_lat = 32'h0;

always @(posedge clk_74a) begin
    if (bridge_wr) begin
        bridge_addr_lat    <= bridge_addr;
        bridge_wr_data_lat <= bridge_wr_data;
    end
end

// Synchronise dataslot control signals from clk_74a into clk_sys
// Toggle CDC for brief pulses
reg dataslot_requestwrite_tog = 1'b0;
reg dataslot_allcomplete_tog  = 1'b0;
always @(posedge clk_74a) begin
    if (dataslot_requestwrite) dataslot_requestwrite_tog <= ~dataslot_requestwrite_tog;
    if (dataslot_allcomplete)  dataslot_allcomplete_tog  <= ~dataslot_allcomplete_tog;
end
reg [2:0] rw_sync = 3'h0;
reg [2:0] ac_sync = 3'h0;
always @(posedge clk_sys) begin
    rw_sync <= {rw_sync[1:0], dataslot_requestwrite_tog};
    ac_sync <= {ac_sync[1:0], dataslot_allcomplete_tog};
end
wire dataslot_requestwrite_s = rw_sync[2] ^ rw_sync[1];
wire dataslot_allcomplete_s  = ac_sync[2] ^ ac_sync[1];

// ROM byte sequencer (clk_sys domain)
always @(posedge clk_sys) begin
    ioctl_wr_r <= 1'b0;
    if (!ioctl_wait_w) begin
    case (rom_phase)
        3'd1: begin ioctl_dout_r <= rom_word[31:24]; ioctl_wr_r <= 1'b1;                                             rom_phase <= 3'd2; end
        3'd2: begin ioctl_dout_r <= rom_word[23:16]; ioctl_wr_r <= 1'b1; ioctl_addr_r <= ioctl_addr_r + 1'b1; rom_phase <= 3'd3; end
        3'd3: begin ioctl_dout_r <= rom_word[15:8];  ioctl_wr_r <= 1'b1; ioctl_addr_r <= ioctl_addr_r + 1'b1; rom_phase <= 3'd4; end
        3'd4: begin ioctl_dout_r <= rom_word[7:0];   ioctl_wr_r <= 1'b1; ioctl_addr_r <= ioctl_addr_r + 1'b1; rom_phase <= 3'd0; end
        default: rom_phase <= 3'd0;
    endcase
    end
    if (dataslot_requestwrite_s && !rom_loaded) begin
        rom_loading  <= 1'b1;
        ioctl_addr_r <= 27'h0;
    end
    if (dataslot_allcomplete_s) begin
        rom_loading <= 1'b0;
        rom_loaded  <= 1'b1;
    end
    if (bridge_wr_s && rom_loading && bridge_addr_lat[31:28] == 4'h0) begin
        rom_word  <= bridge_wr_data_lat;
        rom_phase <= 3'd1;
    end
end

//============================================================================
// Reset
// game_reset holds the M90 core in reset until:
//   - ROM has fully loaded  (rom_loaded)
//   - APF has released reset (reset_n)
//   - A brief stabilisation countdown completes (~0.6s at clk_sys)
//============================================================================

reg [23:0] rst_cnt      = 24'hFFFFFF;
reg        game_reset   = 1'b1;
reg        game_started = 1'b0;  // latches when game_reset first goes low

// game_reset state machine:
//   - Holds reset while ROM loading or not yet loaded
//   - Counts down rst_cnt once ROM loaded and APF releases reset_n
//   - Once game_started latches, only a ROM reload can re-assert game_reset
//   - reset_n toggling from APF after boot does NOT re-assert game_reset
always @(posedge clk_sys or negedge pll_core_locked) begin
    if (~pll_core_locked) begin
        rst_cnt      <= 24'hFFFFFF;
        game_reset   <= 1'b1;
        game_started <= 1'b0;
    end else begin
        if (rom_loading || !rom_loaded) begin
            // ROM not ready: hold in reset, clear started flag
            rst_cnt      <= 24'hFFFFFF;
            game_reset   <= 1'b1;
            game_started <= 1'b0;
        end else if (game_started) begin
            // Game already running: stay released regardless of reset_n
            game_reset <= 1'b0;
        end else if (!reset_n) begin
            // APF still holding reset: reload counter, stay in reset
            rst_cnt    <= 24'hFFFFFF;
            game_reset <= 1'b1;
        end else if (rst_cnt != 24'h0) begin
            // Counting down stabilisation period
            rst_cnt    <= rst_cnt - 1'b1;
            game_reset <= 1'b1;
        end else begin
            // Countdown complete: release reset and latch started
            game_reset   <= 1'b0;
            game_started <= 1'b1;
        end
    end
end

//============================================================================
// PSRAM arbiter (cram0)
//
// Three clients share cram0 in priority order:
//   1. ROM loader  (during ROM load)
//   2. GA25 BG DMA (during gameplay, 64-bit burst reads)
//   3. V35 CPU     (during gameplay, 16-bit reads)
//============================================================================

wire [21:0] psram_addr;
wire        psram_write_en;
wire [15:0] psram_data_in;
wire        psram_write_high_byte;
wire        psram_write_low_byte;
wire        psram_read_en;
wire        psram_read_avail;
wire [15:0] psram_data_out;
wire        psram_busy;

psram #(.CLOCK_SPEED(57.0)) psram_inst (
    .clk             (clk_ram),
    .bank_sel        (1'b0),
    .addr            (psram_addr),
    .write_en        (psram_write_en),
    .data_in         (psram_data_in),
    .write_high_byte (psram_write_high_byte),
    .write_low_byte  (psram_write_low_byte),
    .read_en         (psram_read_en),
    .read_avail      (psram_read_avail),
    .data_out        (psram_data_out),
    .busy            (psram_busy),
    .cram_a          (cram0_a),
    .cram_dq         (cram0_dq),
    .cram_wait       (cram0_wait),
    .cram_clk        (cram0_clk),
    .cram_adv_n      (cram0_adv_n),
    .cram_cre        (cram0_cre),
    .cram_ce0_n      (cram0_ce0_n),
    .cram_ce1_n      (cram0_ce1_n),
    .cram_oe_n       (cram0_oe_n),
    .cram_we_n       (cram0_we_n),
    .cram_ub_n       (cram0_ub_n),
    .cram_lb_n       (cram0_lb_n)
);

// ROM write channel
wire [24:0] rl_sdr_addr;
wire [15:0] rl_sdr_data;
wire  [1:0] rl_sdr_be;
wire        rl_sdr_req;
reg         rl_sdr_rdy = 1'b0;
wire        ioctl_wait_w;

// GA25 BG DMA channel (64-bit burst)
wire [24:0] sdr_bg_addr;
// GA25 BG channel - data written in clk_ram by arbiter, captured by ga25_sdram in clk_ram
// ga25_sdram has its own active_rq/ack handshake CDC - no extra sync needed
reg  [63:0] sdr_bg_dout = 64'h0;
wire        sdr_bg_req;
reg         sdr_bg_rdy  = 1'b0;
wire        sdr_bg_64bit;

// V35 CPU channel (16-bit)
wire [24:0] sdr_cpu_addr;
// V35 CPU channel - data written in clk_ram by arbiter, read by rom_cache in clk_ram
// rom_cache captures sdr_data on sdr_rdy (both clk_ram) - no CDC needed here
reg  [63:0] sdr_cpu_dout = 64'h0;
wire        sdr_cpu_req;
reg         sdr_cpu_rdy  = 1'b0;

// Latched request signals - hold until arbiter can service them
reg         rl_sdr_req_lat   = 1'b0;
reg         sdr_bg_req_lat   = 1'b0;
reg         sdr_cpu_req_lat  = 1'b0;

reg  [4:0]  arb_state  = 5'h0;
reg  [21:0] arb_addr_r = 22'h0;
reg  [15:0] arb_din_r  = 16'h0;
reg         arb_we_r   = 1'b0;
reg         arb_re_r   = 1'b0;
reg         arb_wh_r   = 1'b0;
reg         arb_wl_r   = 1'b0;
reg  [15:0] arb_buf0   = 16'h0;
reg  [15:0] arb_buf1   = 16'h0;
reg  [15:0] arb_buf2   = 16'h0;

assign psram_addr            = arb_addr_r;
assign psram_write_en        = arb_we_r;
assign psram_data_in         = arb_din_r;
assign psram_write_high_byte = arb_wh_r;
assign psram_write_low_byte  = arb_wl_r;
assign psram_read_en         = arb_re_r;

always @(posedge clk_ram) begin
    rl_sdr_rdy  <= 1'b0;
    sdr_bg_rdy  <= 1'b0;
    sdr_cpu_rdy <= 1'b0;
    // Latch incoming request pulses so they're never missed
    if (rl_sdr_req)  rl_sdr_req_lat  <= 1'b1;
    if (sdr_bg_req)  sdr_bg_req_lat  <= 1'b1;
    if (sdr_cpu_req) sdr_cpu_req_lat <= 1'b1;
    arb_we_r    <= 1'b0;
    arb_re_r    <= 1'b0;

    case (arb_state)
    // Idle: service ROM writes first, then BG reads, then CPU reads
    5'd0: begin
        if (rom_loading && (rl_sdr_req || rl_sdr_req_lat)) begin
            arb_addr_r      <= rl_sdr_addr[22:1];
            arb_din_r       <= rl_sdr_data;
            arb_wh_r        <= rl_sdr_be[1];
            arb_wl_r        <= rl_sdr_be[0];
            arb_we_r        <= 1'b1;
            rl_sdr_req_lat  <= 1'b0;
            arb_state       <= 5'd1;
        end else if (!rom_loading && (sdr_bg_req || sdr_bg_req_lat)) begin
            arb_addr_r      <= sdr_bg_addr[22:1];
            arb_re_r        <= 1'b1;
            sdr_bg_req_lat  <= 1'b0;
            arb_state       <= 5'd3;
        end else if (!rom_loading && (sdr_cpu_req || sdr_cpu_req_lat)) begin
            arb_addr_r      <= {sdr_cpu_addr[22:3], 2'b00};
            arb_re_r        <= 1'b1;
            sdr_cpu_req_lat <= 1'b0;
            arb_state       <= 5'd9;
        end
    end

    // ROM write:
    // S1: keep write_en until psram goes busy (accepted)
    // S2: wait for !busy (write complete)
    5'd1: begin
        if (psram_busy) begin
            arb_state <= 5'd2;
        end else begin
            arb_we_r  <= 1'b1;
        end
    end
    5'd2: begin
        if (!psram_busy) begin
            rl_sdr_rdy <= 1'b1;
            arb_state  <= 5'd0;
        end
    end

    // BG read: 4-word burst
    // Odd states: keep read_en until busy (accepted)
    // Even states: wait for read_avail, capture data, trigger next read
    5'd3: begin
        if (psram_busy) begin
            arb_state <= 5'd4;
        end else begin
            arb_re_r  <= 1'b1;
        end
    end
    5'd4: begin
        if (psram_read_avail) begin
            arb_buf0 <= psram_data_out;
            if (!sdr_bg_64bit) begin
                sdr_bg_dout <= {48'h0, psram_data_out};
                sdr_bg_rdy  <= 1'b1;
                arb_state   <= 5'd0;
            end else begin
                arb_addr_r  <= arb_addr_r + 1'b1;
                arb_re_r    <= 1'b1;
                arb_state   <= 5'd5;
            end
        end
    end
    5'd5: begin
        if (psram_busy) begin
            arb_state <= 5'd6;
        end else begin
            arb_re_r  <= 1'b1;
        end
    end
    5'd6: begin
        if (psram_read_avail) begin
            arb_buf1   <= psram_data_out;
            arb_addr_r <= arb_addr_r + 1'b1;
            arb_re_r   <= 1'b1;
            arb_state  <= 5'd7;
        end
    end
    5'd7: begin
        if (psram_busy) begin
            arb_state <= 5'd8;
        end else begin
            arb_re_r  <= 1'b1;
        end
    end
    5'd8: begin
        if (psram_read_avail) begin
            arb_buf2   <= psram_data_out;
            arb_addr_r <= arb_addr_r + 1'b1;
            arb_re_r   <= 1'b1;
            arb_state  <= 5'd12;
        end
    end
    5'd12: begin
        if (psram_busy) begin
            arb_state <= 5'd15;
        end else begin
            arb_re_r  <= 1'b1;
        end
    end
    5'd15: begin
        if (psram_read_avail) begin
            sdr_bg_dout <= {psram_data_out, arb_buf2, arb_buf1, arb_buf0};
            sdr_bg_rdy  <= 1'b1;
            arb_state   <= 5'd0;
        end
    end

    // CPU read: 4-word burst (64-bit cache line for rom_cache)
    5'd9: begin
        if (psram_busy) begin
            arb_state <= 5'd10;
        end else begin
            arb_re_r  <= 1'b1;
        end
    end
    5'd10: begin
        if (psram_read_avail) begin
            arb_buf0   <= psram_data_out;
            arb_addr_r <= arb_addr_r + 1'b1;
            arb_re_r   <= 1'b1;
            arb_state  <= 5'd11;
        end
    end
    5'd11: begin
        if (psram_busy) begin
            arb_state <= 5'd13;
        end else begin
            arb_re_r  <= 1'b1;
        end
    end
    5'd13: begin
        if (psram_read_avail) begin
            arb_buf1   <= psram_data_out;
            arb_addr_r <= arb_addr_r + 1'b1;
            arb_re_r   <= 1'b1;
            arb_state  <= 5'd14;
        end
    end
    5'd14: begin
        if (psram_busy) begin
            arb_state <= 5'd16;
        end else begin
            arb_re_r  <= 1'b1;
        end
    end
    5'd16: begin
        if (psram_read_avail) begin
            arb_buf2   <= psram_data_out;
            arb_addr_r <= arb_addr_r + 1'b1;
            arb_re_r   <= 1'b1;
            arb_state  <= 5'd17;
        end
    end
    5'd17: begin
        if (psram_busy) begin
            arb_state <= 5'd18;
        end else begin
            arb_re_r  <= 1'b1;
        end
    end
    5'd18: begin
        if (psram_read_avail) begin
            sdr_cpu_dout <= {psram_data_out, arb_buf2, arb_buf1, arb_buf0};
            sdr_cpu_rdy      <= 1'b1;
            arb_state        <= 5'd0;
        end
    end

    default: arb_state <= 5'd0;
    endcase
end

//============================================================================
// Sample ROM PSRAM bridge (cram1)
//
// The 128 KB PCM sample ROM is stored in cram1 PSRAM rather than on-chip
// BRAM, freeing ~103 M10K blocks required for the core to fit the device.
// Writes come from the BRAM loader during ROM loading; reads serve sound.sv.
//============================================================================

wire [16:0] sample_rom_addr;
wire  [7:0] sample_rom_data;

sample_rom_psram sample_rom_psram_inst (
    .clk            (clk_sys),
    .reset          (game_reset),
    .bram_sample_cs (bram_cs[2]),
    .bram_addr      (bram_addr[16:0]),
    .bram_data      (bram_data),
    .bram_wr        (bram_wr),
    .sample_addr    (sample_rom_addr),
    .sample_data    (sample_rom_data),
    .cram_a         (cram1_a),
    .cram_dq        (cram1_dq),
    .cram_wait      (cram1_wait),
    .cram_clk       (cram1_clk),
    .cram_adv_n     (cram1_adv_n),
    .cram_cre       (cram1_cre),
    .cram_ce0_n     (cram1_ce0_n),
    .cram_ce1_n     (cram1_ce1_n),
    .cram_oe_n      (cram1_oe_n),
    .cram_we_n      (cram1_we_n),
    .cram_ub_n      (cram1_ub_n),
    .cram_lb_n      (cram1_lb_n)
);

//============================================================================
// BRAM and ROM loader
//============================================================================

wire [19:0] bram_addr;
wire  [7:0] bram_data;
wire  [4:0] bram_cs;
wire        bram_wr;
board_cfg_t board_cfg;

rom_loader rom_loader_inst (
    .sys_clk    (clk_sys),
    .ram_clk    (clk_ram),
    .ioctl_wr   (ioctl_wr_r),
    .ioctl_data (ioctl_dout_r),
    .ioctl_wait (ioctl_wait_w),
    .sdr_addr   (rl_sdr_addr),
    .sdr_data   (rl_sdr_data),
    .sdr_be     (rl_sdr_be),
    .sdr_req    (rl_sdr_req),
    .sdr_rdy    (rl_sdr_rdy),
    .bram_addr  (bram_addr),
    .bram_data  (bram_data),
    .bram_cs    (bram_cs),
    .bram_wr    (bram_wr),
    .board_cfg  (board_cfg)
);

//============================================================================
// Controllers
//
// APF cont_key bit layout (official spec):
//   [0]  dpad_up      [8]  trig_l1
//   [1]  dpad_down    [9]  trig_r1
//   [2]  dpad_left    [10] trig_l2
//   [3]  dpad_right   [11] trig_r2
//   [4]  face_a       [12] trig_l3
//   [5]  face_b       [13] trig_r3
//   [6]  face_x       [14] face_select
//   [7]  face_y       [15] face_start
//
// M90 p*_input[9:0] (see m90.sv switches_p*):
//   [7] btn2  [6] btn1  [5] R2  [4] L2
//   [3] right [2] left  [1] down [0] up
//
// Synchronise into clk_sys with 3-stage shift registers to avoid
// metastability (cont_key is clocked by clk_74a in io_pad_controller).
//============================================================================

reg [31:0] cont1_key_s1, cont1_key_s2, cont1_key_s;
reg [31:0] cont2_key_s1, cont2_key_s2, cont2_key_s;
reg [31:0] cont3_key_s1, cont3_key_s2, cont3_key_s;
reg [31:0] cont4_key_s1, cont4_key_s2, cont4_key_s;

always @(posedge clk_sys) begin
    {cont1_key_s, cont1_key_s2, cont1_key_s1} <= {cont1_key_s2, cont1_key_s1, cont1_key};
    {cont2_key_s, cont2_key_s2, cont2_key_s1} <= {cont2_key_s2, cont2_key_s1, cont2_key};
    {cont3_key_s, cont3_key_s2, cont3_key_s1} <= {cont3_key_s2, cont3_key_s1, cont3_key};
    {cont4_key_s, cont4_key_s2, cont4_key_s1} <= {cont4_key_s2, cont4_key_s1, cont4_key};
end

wire [9:0] p1_input = {2'b00, cont1_key_s[6], cont1_key_s[7], cont1_key_s[5], cont1_key_s[4],
                               cont1_key_s[0], cont1_key_s[1], cont1_key_s[2], cont1_key_s[3]};
wire [9:0] p2_input = {2'b00, cont2_key_s[6], cont2_key_s[7], cont2_key_s[5], cont2_key_s[4],
                               cont2_key_s[0], cont2_key_s[1], cont2_key_s[2], cont2_key_s[3]};
wire [9:0] p3_input = {2'b00, cont3_key_s[6], cont3_key_s[7], cont3_key_s[5], cont3_key_s[4],
                               cont3_key_s[0], cont3_key_s[1], cont3_key_s[2], cont3_key_s[3]};
wire [9:0] p4_input = {2'b00, cont4_key_s[6], cont4_key_s[7], cont4_key_s[5], cont4_key_s[4],
                               cont4_key_s[0], cont4_key_s[1], cont4_key_s[2], cont4_key_s[3]};

wire [3:0] m_coin  = {cont4_key_s[14], cont3_key_s[14], cont2_key_s[14], cont1_key_s[14]};
wire [3:0] m_start = {cont4_key_s[15], cont3_key_s[15], cont2_key_s[15], cont1_key_s[15]};

//============================================================================
// M90 game core
//============================================================================

wire [7:0]  core_r, core_g, core_b;
wire        core_hb, core_vb, core_hs, core_vs;
wire        palram_wr_seen;       // sticky: CPU has written to palette
wire        palram_nonzero_seen;  // sticky: CPU has written NON-ZERO to palette
wire [10:0] palram_last_wr_addr;
wire [15:0] palram_last_wr_data;
// External palette write disabled - CPU writes palette directly
wire        ext_palram_wren = 1'b0;
wire [10:0] ext_palram_addr = 11'h0;
wire [15:0] ext_palram_data = 16'h0;
wire        core_ce_pix;
wire [15:0] audio_l_out, audio_r_out;

// CPU activity diagnostic outputs from m90
wire [15:0] dbg_mrd_count;
wire [19:0] dbg_last_rom_addr;
wire [15:0] dbg_mwr_count;
wire [15:0] dbg_palram_wr_count;
wire [15:0] dbg_vram_wr_count;
wire [15:0] dbg_io_wr_count;
wire        dbg_vram_nonzero_seen;
wire [14:0] dbg_vram_last_addr;
wire [15:0] dbg_vram_last_data;
wire [15:0] dbg_last_iowr_addr;
wire [15:0] dbg_last_iowr_data;

m90 m90_inst (
    .clk_sys        (clk_sys),
    .clk_ram        (clk_ram),
    .ce_pix         (core_ce_pix),
    .reset_n        (~game_reset),
    .HBlank         (core_hb),
    .VBlank         (core_vb),
    .HSync          (core_hs),
    .VSync          (core_vs),
    .R              (core_r),
    .G              (core_g),
    .B              (core_b),
    .AUDIO_L        (audio_l_out),
    .AUDIO_R        (audio_r_out),
    .board_cfg      (board_cfg),
    .z80_reset_n    (1'b1),
    .coin           (m_coin),
    .start_buttons  (m_start),
    .p1_input       (p1_input),
    .p2_input       (p2_input),
    .p3_input       (p3_input),
    .p4_input       (p4_input),
    .dip_sw         ({dip_sw2, dip_sw1, dip_sw0}),
    .sdr_bg_addr    (sdr_bg_addr),
    .sdr_bg_dout    (sdr_bg_dout),
    .sdr_bg_req     (sdr_bg_req),
    .sdr_bg_rdy     (sdr_bg_rdy),
    .sdr_bg_64bit   (sdr_bg_64bit),
    .sdr_cpu_dout   (sdr_cpu_dout),
    .sdr_cpu_addr   (sdr_cpu_addr),
    .sdr_cpu_req    (sdr_cpu_req),
    .sdr_cpu_rdy    (sdr_cpu_rdy),
    .clk_bram       (clk_sys),
    .bram_addr      (bram_addr),
    .bram_data      (bram_data),
    .bram_cs        (bram_cs),
    .bram_wr        (bram_wr),
    .ioctl_download (1'b0),
    .ioctl_index    (16'h0),
    .ioctl_wr       (1'b0),
    .ioctl_addr     (27'h0),
    .ioctl_dout     (8'h0),
    .ioctl_upload   (1'b0),
    .ioctl_upload_index (),
    .ioctl_din      (),
    .ioctl_rd       (1'b0),
    .ioctl_upload_req (),
    .pause_rq       (1'b0),
    .cpu_paused     (),
    .cpu_turbo      (1'b0),
    .hs_address     (20'h0),
    .hs_din         (8'h0),
    .hs_dout        (),
    .hs_write       (1'b0),
    .hs_read        (1'b0),
    .dbg_en_layers  (2'b11),
    .palram_wr_seen      (palram_wr_seen),
    .palram_nonzero_seen (palram_nonzero_seen),
    .palram_last_wr_addr (palram_last_wr_addr),
    .palram_last_wr_data (palram_last_wr_data),
    .ext_palram_wren (ext_palram_wren),
    .ext_palram_addr (ext_palram_addr),
    .ext_palram_data (ext_palram_data),
    .dbg_mrd_count       (dbg_mrd_count),
    .dbg_last_rom_addr   (dbg_last_rom_addr),
    .dbg_mwr_count       (dbg_mwr_count),
    .dbg_palram_wr_count (dbg_palram_wr_count),
    .dbg_vram_wr_count   (dbg_vram_wr_count),
    .dbg_io_wr_count     (dbg_io_wr_count),
    .dbg_vram_nonzero_seen (dbg_vram_nonzero_seen),
    .dbg_vram_last_addr  (dbg_vram_last_addr),
    .dbg_vram_last_data  (dbg_vram_last_data),
    .dbg_last_iowr_addr  (dbg_last_iowr_addr),
    .dbg_last_iowr_data  (dbg_last_iowr_data),
    .dbg_solid_sprites (1'b0),
    .sample_rom_addr (sample_rom_addr),
    .sample_rom_data (sample_rom_data)
);

//============================================================================
// Video output
//
// APF requirements:
//   - video_rgb_clock:    pixel clock
//   - video_rgb_clock_90: pixel clock with 90° phase shift (for DDR output)
//   - video_hs/vs:        single-cycle rising-edge pulses (not wide signals)
//   - video_rgb:          must be 0x000000 when video_de is deasserted
//============================================================================

// Use 6.666MHz video PLL clock as pixel clock
// This matches the M90 actual pixel rate so the scaler counts pixels correctly
assign video_rgb_clock    = clk_sys;
assign video_rgb_clock_90 = clk_sys2;

reg [23:0] video_rgb_r;
reg        video_de_r;
reg        video_hs_r, video_vs_r;
reg        core_hs_prev, core_vs_prev;

// APF scaler requirement: video_hs and video_vs must be single-cycle pulses
// on the RISING EDGE of the core sync signals, not wide level signals.
// Wide sync (e.g. 40px hsync) causes the scaler to never lock.
always @(posedge clk_sys) begin
    if (core_ce_pix) begin
        video_de_r    <= ~(core_hb | core_vb);
        video_rgb_r   <= (core_hb | core_vb) ? 24'h0 : {core_r, core_g, core_b};
        // Single-cycle pulse on rising edge
        video_hs_r    <= core_hs & ~core_hs_prev;
        video_vs_r    <= core_vs & ~core_vs_prev;
        core_hs_prev  <= core_hs;
        core_vs_prev  <= core_vs;
    end
end

//============================================================================
// Diagnostic overlay
//
// This overlay draws a banner of 8 vertical bars in the top 16 scanlines.
// Each bar reports a sticky CPU-activity indicator. Bars are 32 pixels wide
// and arranged left-to-right at start of active video. Below the banner,
// real video is shown.
//
// Bar colours (left to right):
//   1. MRD count: black=0, white=fired (CPU is fetching from ROM)
//   2. MWR count: black=0, white=fired (CPU is writing memory)
//   3. IOWR count: black=0, white=fired (CPU is writing IO)
//   4. PALRAM write count: black=0, white=fired (CPU writes to palette)
//   5. VRAM write count: black=0, white=fired (CPU writes to GA25)
//   6. PALRAM non-zero: black=no, white=yes (CPU wrote non-zero palette)
//   7. VBlanks: black=<60, white=>=60 (GA25 vblank timing alive)
//   8. CPU stall sticky: black=ok, RED=stalled
//
// Full-screen fallback colour codes (BEFORE game_reset releases):
//   WHITE   = PLL not locked
//   BLUE    = APF reset_n not released
//   GREEN   = ROM not loaded
//   RED     = game_reset counting down
//============================================================================

// CPU stall: sdr_cpu_req pending > 65536 clk_ram cycles
reg [15:0] cpu_stall_cnt    = 16'h0;
reg        cpu_stall_sticky = 1'b0;
always @(posedge clk_ram) begin
    if (sdr_cpu_rdy) begin
        cpu_stall_cnt <= 16'h0;
    end else if (sdr_cpu_req || sdr_cpu_req_lat) begin
        if (cpu_stall_cnt == 16'hFFFF) cpu_stall_sticky <= 1'b1;
        else cpu_stall_cnt <= cpu_stall_cnt + 1'b1;
    end else begin
        cpu_stall_cnt <= 16'h0;
    end
end

// VBlank counter (GA25 timing alive indicator) - clk_sys domain
reg        core_vb_prev    = 1'b0;
reg [7:0]  vblank_count    = 8'h0;
reg        vblank_seen_60  = 1'b0;
always @(posedge clk_sys) begin
    core_vb_prev <= core_vb;
    if (~game_reset) begin
        if (core_vb & ~core_vb_prev) begin
            if (vblank_count < 8'hFF) vblank_count <= vblank_count + 8'h1;
            if (vblank_count >= 8'd59) vblank_seen_60 <= 1'b1;
        end
    end else begin
        vblank_count   <= 8'h0;
        vblank_seen_60 <= 1'b0;
    end
end

// X/Y position counters - reset at hblank/vblank edges, increment per ce_pix
// during active region. Used to overlay diagnostic banner in top-left.
// IMPORTANT: core_hb_prev and core_vb_prev MUST be sampled only on
// core_ce_pix, otherwise they catch up to core_hb/core_vb between pixel
// ticks and the edge detect never fires (banner never appears).
reg        core_hb_pix_prev = 1'b0;
reg        core_vb_pix_prev = 1'b0;
reg [9:0]  scan_x = 10'h0;
reg [9:0]  scan_y = 10'h3FF;  // start out-of-banner until first vblank seen

always @(posedge clk_sys) begin
    if (core_ce_pix) begin
        core_hb_pix_prev <= core_hb;
        core_vb_pix_prev <= core_vb;

        // Falling edge of VBlank = start of frame (top of active video)
        if (core_vb_pix_prev & ~core_vb) begin
            scan_y <= 10'h0;
            scan_x <= 10'h0;
        end
        // Falling edge of HBlank = start of active line
        else if (core_hb_pix_prev & ~core_hb) begin
            scan_x <= 10'h0;
            if (~core_vb && scan_y < 10'h3FF) scan_y <= scan_y + 10'd1;
        end
        // Within active line: increment x
        else if (~core_hb && ~core_vb) begin
            if (scan_x < 10'h3FF) scan_x <= scan_x + 10'd1;
        end
    end
end

// Pre-boot full-screen colour codes
wire [23:0] dbg_colour =
    !pll_core_locked_s ? 24'hFFFFFF :
    !reset_n           ? 24'h0000FF :
    !rom_loaded        ? 24'h00FF00 :
                         24'hFF0000;

// Banner layout: TWO rows of 8 bars each.
// Row 1 (lines 1..18): activity counters - dark grey/yellow/green by magnitude
//   1=MRD, 2=MWR, 3=IOWR, 4=PALRAM, 5=VRAM, 6=PAL_NONZERO, 7=VBLANKS, 8=STALL
// Row 2 (lines 21..38): critical sticky flags + last-data nibble indicators
//   1=VRAM_NONZERO, 2=last_iowr[15], 3=last_iowr[7], 4=last_iowr[3],
//   5=last_vram[15], 6=last_vram[7], 7=last_vram[3], 8=last_rom[19]
// Each bar 32px wide x 18 lines tall, magenta border around banner.

wire in_banner   = (scan_y < 10'd40) && (scan_x < 10'd258);
wire banner_border =
       (scan_y == 10'd0)   || (scan_y == 10'd39)
    || (scan_x == 10'd0)   || (scan_x == 10'd257);
wire row_separator = (scan_y == 10'd19) || (scan_y == 10'd20);
wire in_row1 = (scan_y >= 10'd1)  && (scan_y <= 10'd18);
wire in_row2 = (scan_y >= 10'd21) && (scan_y <= 10'd38);

wire [2:0] bar_idx = scan_x[7:5];  // 0..7

// Counter-magnitude levels:
//   level 0 (dark grey) = counter == 0
//   level 1 (yellow)    = 0 < counter < 64
//   level 2 (green)     = counter >= 64 (sustained activity)
// vblank/stall/non-zero use 2-level (dark/green or dark/red).
function [1:0] mag_level;
    input [15:0] count;
    begin
        if      (count == 16'h0)              mag_level = 2'd0;
        else if (count < 16'd64)              mag_level = 2'd1;
        else                                  mag_level = 2'd2;
    end
endfunction

wire [1:0] row1_level =
    (bar_idx == 3'd0) ? mag_level(dbg_mrd_count)       :
    (bar_idx == 3'd1) ? mag_level(dbg_mwr_count)       :
    (bar_idx == 3'd2) ? mag_level(dbg_io_wr_count)     :
    (bar_idx == 3'd3) ? mag_level(dbg_palram_wr_count) :
    (bar_idx == 3'd4) ? mag_level(dbg_vram_wr_count)   :
    (bar_idx == 3'd5) ? (palram_nonzero_seen ? 2'd2 : 2'd0) :
    (bar_idx == 3'd6) ? (vblank_seen_60      ? 2'd2 : 2'd0) :
                        (cpu_stall_sticky    ? 2'd3 : 2'd0); // 2'd3 = red

wire [23:0] row1_pixel =
      row1_level == 2'd0 ? 24'h101010   // dark grey (never fired)
    : row1_level == 2'd1 ? 24'hFFFF00   // yellow (some activity, low count)
    : row1_level == 2'd2 ? 24'h00FF00   // bright green (lots of activity)
    :                      24'hFF0000;  // red (stall sticky)

// Row 2: 8 single-bit indicators showing data bits / sticky flags
wire row2_on =
    (bar_idx == 3'd0) ? dbg_vram_nonzero_seen    :
    (bar_idx == 3'd1) ? dbg_last_iowr_addr[15]   :
    (bar_idx == 3'd2) ? dbg_last_iowr_addr[7]    :
    (bar_idx == 3'd3) ? dbg_last_iowr_data[7]    :
    (bar_idx == 3'd4) ? dbg_vram_last_data[15]   :
    (bar_idx == 3'd5) ? dbg_vram_last_data[7]    :
    (bar_idx == 3'd6) ? dbg_vram_last_data[3]    :
                        dbg_last_rom_addr[19]    ;

wire [23:0] row2_pixel =
      (bar_idx == 3'd0) ? (row2_on ? 24'h00FF00 : 24'h101010) // green = VRAM non-zero seen!
    : row2_on            ? 24'h00FFFF   // cyan = bit is set
    :                      24'h101010;  // dark grey = bit is clear

// Thin black separators every 32 pixels within rows
wire bar_separator = (scan_x[4:0] == 5'd0) && (scan_x > 10'd0);

wire [23:0] banner_pixel =
       banner_border  ? 24'hFF00FF             // MAGENTA border
    :  row_separator  ? 24'hFF00FF             // MAGENTA divider between rows
    :  bar_separator  ? 24'h000000             // black between bars
    :  in_row1        ? row1_pixel
    :  in_row2        ? row2_pixel
    :                   24'h202020;            // grey fill

// Final overlay: banner takes priority in top 40 lines, real video below
wire [23:0] game_rgb_final = in_banner ? banner_pixel : video_rgb_r;

// During game_reset: show dbg_colour (PLL/reset/ROM stage).
// After game_reset:  show banner overlay on top of real video.
wire [23:0] video_rgb_out = game_reset ? dbg_colour : game_rgb_final;
assign video_rgb = video_de_r ? video_rgb_out : 24'h0;
assign video_de  = video_de_r;
assign video_hs  = video_hs_r;
assign video_vs  = video_vs_r;

//============================================================================
// Audio output (I2S)
//============================================================================

sound_i2s #(
    .CHANNEL_WIDTH (16),
    .SIGNED_INPUT  (1)
) sound_i2s_inst (
    .clk_74a    (clk_74a),
    .clk_audio  (clk_sys),
    .audio_l    (audio_l_out),
    .audio_r    (audio_r_out),
    .audio_mclk (audio_mclk),
    .audio_lrck (audio_lrck),
    .audio_dac  (audio_dac)
);

endmodule
