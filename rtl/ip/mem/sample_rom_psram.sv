//============================================================================
// sample_rom_psram.sv
//
// Bridge between sound.sv's synchronous sample ROM interface and the
// Analogue Pocket's cram1 PSRAM chip.
//
// The original Irem M90 MiSTer core stores the 128 KB PCM sample ROM in
// on-chip BRAM (widthad=17, width=8, ~103 M10K blocks). Moving it to cram1
// PSRAM frees those blocks, allowing the core to fit the Cyclone V 5CEBA4.
//
// Write path (ROM loading):
//   During ROM load, bram_sample_cs is asserted. Byte writes arrive via
//   bram_addr[16:0] / bram_data / bram_wr. Odd bytes are buffered until
//   the even byte arrives so we can issue aligned 16-bit PSRAM writes.
//
// Read path (Z80 sample playback):
//   sound.sv presents sample_addr[16:0]. This module detects changes,
//   fetches the containing 16-bit word from PSRAM, and holds sample_data
//   stable until the next address change. The Z80 IO read window is ~280 ns;
//   a PSRAM fetch takes ~70 ns, so data is always ready in time.
//
// Clock: clk_sys (28.639 MHz)
//============================================================================

`default_nettype none

module sample_rom_psram (
    input  wire        clk,
    input  wire        reset,

    // ROM load interface (from bram loader)
    input  wire        bram_sample_cs,
    input  wire [16:0] bram_addr,
    input  wire  [7:0] bram_data,
    input  wire        bram_wr,

    // Playback read interface (to sound.sv)
    input  wire [16:0] sample_addr,
    output reg   [7:0] sample_data,

    // cram1 PSRAM pins
    output reg  [21:16] cram_a,
    inout  wire  [15:0] cram_dq,
    input  wire         cram_wait,
    output reg          cram_clk,
    output reg          cram_adv_n,
    output reg          cram_cre,
    output reg          cram_ce0_n,
    output reg          cram_ce1_n,
    output reg          cram_oe_n,
    output reg          cram_we_n,
    output reg          cram_ub_n,
    output reg          cram_lb_n
);

//----------------------------------------------------------------------------
// PSRAM controller instance
//----------------------------------------------------------------------------

wire        psram_busy;
wire        psram_read_avail;
wire [15:0] psram_data_out;

reg         psram_read_en  = 1'b0;
reg         psram_write_en = 1'b0;
reg  [21:0] psram_addr     = 22'h0;
reg  [15:0] psram_data_in  = 16'h0;
reg         psram_wh       = 1'b0;
reg         psram_wl       = 1'b0;

psram #(.CLOCK_SPEED(57.0)) psram_cram1 (
    .clk             (clk),
    .bank_sel        (1'b0),
    .addr            (psram_addr),
    .write_en        (psram_write_en),
    .data_in         (psram_data_in),
    .write_high_byte (psram_wh),
    .write_low_byte  (psram_wl),
    .read_en         (psram_read_en),
    .read_avail      (psram_read_avail),
    .data_out        (psram_data_out),
    .busy            (psram_busy),
    .cram_a          (cram_a),
    .cram_dq         (cram_dq),
    .cram_wait       (cram_wait),
    .cram_clk        (cram_clk),
    .cram_adv_n      (cram_adv_n),
    .cram_cre        (cram_cre),
    .cram_ce0_n      (cram_ce0_n),
    .cram_ce1_n      (cram_ce1_n),
    .cram_oe_n       (cram_oe_n),
    .cram_we_n       (cram_we_n),
    .cram_ub_n       (cram_ub_n),
    .cram_lb_n       (cram_lb_n)
);

//----------------------------------------------------------------------------
// Write path — even-byte buffer
// PSRAM is 16-bit wide; bram writes arrive as bytes.
// Buffer even (low) bytes until the odd (high) byte arrives, then write both.
//   bram_addr[0] = 0 → low byte  (cram_dq[7:0])
//   bram_addr[0] = 1 → high byte (cram_dq[15:8])
//----------------------------------------------------------------------------

reg [7:0] wr_buf       = 8'h0;
reg       wr_buf_valid = 1'b0;

//----------------------------------------------------------------------------
// Read path — address change tracking
//----------------------------------------------------------------------------

reg [16:0] sample_addr_r  = 17'h0;
reg        fetch_pending   = 1'b0;
reg        fetch_high_byte = 1'b0;

//----------------------------------------------------------------------------
// Unified FSM — arbitrates write and read operations
// Write requests take priority over reads (ROM load must complete promptly).
//----------------------------------------------------------------------------

localparam [3:0]
    S_IDLE     = 4'd0,
    S_WR_START = 4'd1,
    S_WR_WAIT  = 4'd2,
    S_RD_START = 4'd3,
    S_RD_WAIT  = 4'd4;

reg [3:0] state = S_IDLE;

always @(posedge clk) begin
    // Default: deassert strobes each cycle
    psram_write_en <= 1'b0;
    psram_read_en  <= 1'b0;

    if (reset) begin
        state          <= S_IDLE;
        sample_data    <= 8'hFF;
        fetch_pending  <= 1'b0;
        sample_addr_r  <= 17'h0;
        wr_buf_valid   <= 1'b0;

    end else begin

        // Detect address changes (suppressed during ROM load)
        if (!bram_sample_cs && (sample_addr != sample_addr_r)) begin
            fetch_pending   <= 1'b1;
            fetch_high_byte <= sample_addr[0];
            sample_addr_r   <= sample_addr;
        end

        // Accumulate write bytes into pairs
        if (bram_sample_cs && bram_wr && state == S_IDLE) begin
            if (bram_addr[0] == 1'b0) begin
                wr_buf       <= bram_data;
                wr_buf_valid <= 1'b1;
            end else begin
                psram_addr    <= {5'h0, bram_addr[16:1]};
                psram_data_in <= {bram_data, wr_buf_valid ? wr_buf : 8'hFF};
                psram_wh      <= 1'b1;
                psram_wl      <= 1'b1;
                psram_write_en <= 1'b1;
                wr_buf_valid  <= 1'b0;
                state         <= S_WR_START;
            end
        end

        case (state)

        S_IDLE: begin
            if (!bram_sample_cs && fetch_pending && !psram_busy) begin
                psram_addr    <= {5'h0, sample_addr_r[16:1]};
                psram_read_en <= 1'b1;
                fetch_pending <= 1'b0;
                state         <= S_RD_START;
            end
        end

        S_WR_START: begin
            if (psram_busy) begin
                state <= S_WR_WAIT;
            end else begin
                psram_write_en <= 1'b1;
            end
        end

        S_WR_WAIT: begin
            if (!psram_busy) begin
                psram_wh <= 1'b0;
                psram_wl <= 1'b0;
                state    <= S_IDLE;
            end
        end

        S_RD_START: begin
            if (psram_busy) begin
                state <= S_RD_WAIT;
            end else begin
                psram_read_en <= 1'b1;
            end
        end

        S_RD_WAIT: begin
            if (psram_read_avail) begin
                sample_data <= fetch_high_byte ? psram_data_out[15:8]
                                               : psram_data_out[7:0];
                state       <= S_IDLE;
            end
        end

        default: state <= S_IDLE;
        endcase
    end
end

endmodule
