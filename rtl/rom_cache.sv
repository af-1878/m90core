import board_pkg::*;

module rom_cache(
    input clk,
    input ce,
    input reset,

    input clk_ram,
    
    output      [24:0]  sdr_addr,
    input [63:0]        sdr_data,
    output reg          sdr_req,
    input               sdr_rdy,

    input               n_bcyst,
    input               read,
    input [18:0]        rom_word_addr,
    output [15:0]       rom_data,
    output reg          rom_ready
);

localparam CACHE_WIDTH = 8;

wire [18-CACHE_WIDTH:0] tag = { version, rom_word_addr[18:CACHE_WIDTH+2] };
wire [CACHE_WIDTH-1:0] index = rom_word_addr[CACHE_WIDTH+1:2];

reg [1:0] version;
reg [63:0] cache_data[2**CACHE_WIDTH];
reg [18-CACHE_WIDTH:0] cache_tag[2**CACHE_WIDTH];

reg [63:0] cache_line;
reg [18-CACHE_WIDTH:0] cached_tag;

always_comb begin
    case(rom_word_addr[1:0])
    2'b00: rom_data = cache_line[15:0];
    2'b01: rom_data = cache_line[31:16];
    2'b10: rom_data = cache_line[47:32];
    2'b11: rom_data = cache_line[63:48];
    endcase
end

// ----------------------------------------------------------------------
// FSM (clk_sys domain)
// ----------------------------------------------------------------------
enum { IDLE, CACHE_CHECK, SDR_WAIT } state = IDLE;
reg read_req, read_ack;
reg prev_reset;

// FSM-owned target address. Registered in clk_sys at the moment a miss is
// detected, before read_req is toggled, so it is stable for the entire
// outstanding request (clk_sys side cannot change it until SDR_WAIT
// completes, because the FSM is blocked).
reg [24:0] sdr_addr_sys;

// FSM-owned target index. Same property as sdr_addr_sys: held stable across
// the request because the FSM stalls in SDR_WAIT.
reg [CACHE_WIDTH-1:0] index_sys;

always_ff @(posedge clk) begin
    
    cache_line <= cache_data[index];
    cached_tag <= cache_tag[index];
    
    prev_reset <= reset;
    
    if (reset) begin
        rom_ready <= 1;
        state <= IDLE;
        if (~prev_reset) version <= version + 2'd1;
    end else if (ce) begin
        if (read && state == IDLE) begin
            state <= CACHE_CHECK;
        end else if (state == CACHE_CHECK) begin
            if (cached_tag == tag) begin
                state <= IDLE;
                rom_ready <= 1;
            end else begin
                // Latch the target address AND the target cache index
                // before toggling read_req. Both must be sampled here in
                // clk_sys; they are then held stable until the response
                // arrives, which gives the clk_ram domain a stable view.
                sdr_addr_sys <= { REGION_CPU_ROM.base_addr[24:20], rom_word_addr[18:2], 3'b000 };
                index_sys    <= index;
                read_req     <= ~read_req;
                rom_ready    <= 0;
                state        <= SDR_WAIT;
            end
        end else if (state == SDR_WAIT) begin
            if (read_req == read_ack_s2) begin
                cache_tag[index_sys] <= tag; // use the latched index, not live `index`
                rom_ready <= 1;
                state <= IDLE;
            end
        end
    end
end

// ----------------------------------------------------------------------
// CDC: clk_sys -> clk_ram
// ----------------------------------------------------------------------
// Synchronise read_req (clk_sys) into clk_ram. By the time read_req_r2
// reflects the toggle, sdr_addr_sys and index_sys have been stable in
// clk_sys for at least 2 clk_ram cycles, so they are safe to sample in
// clk_ram on this edge.
reg read_req_r1 = 0, read_req_r2 = 0;
always_ff @(posedge clk_ram) begin
    read_req_r1 <= read_req;
    read_req_r2 <= read_req_r1;
end

// CDC: clk_ram -> clk_sys for the ack
reg read_ack_s1 = 0, read_ack_s2 = 0;
always_ff @(posedge clk) begin
    read_ack_s1 <= read_ack;
    read_ack_s2 <= read_ack_s1;
end

// ----------------------------------------------------------------------
// PSRAM request side (clk_ram domain)
// ----------------------------------------------------------------------
// Capture sdr_addr_sys and index_sys into clk_ram on the edge of read_req_r2.
// At this point the source signals have been stable for >=2 clk_ram cycles
// (because the FSM stalled in SDR_WAIT after registering them and toggling
// read_req), so a single-flop capture is safe.
reg [24:0]              sdr_addr_ram;
reg [CACHE_WIDTH-1:0]   index_ram;
reg                     read_req_r2_prev = 0;

// Drive the external sdr_addr output from the clk_ram-stable latched copy.
// The arbiter samples this on clk_ram, so it must be a clk_ram signal.
assign sdr_addr = sdr_addr_ram;

reg read_req_prev = 0;
always_ff @(posedge clk_ram) begin
    sdr_req          <= 0;
    read_req_prev    <= read_req_r2;
    read_req_r2_prev <= read_req_r2;

    // On the rising/falling edge of read_req_r2, capture the request context
    // from clk_sys into clk_ram. This is the single CDC sample point for
    // the address and index — everything downstream uses the _ram copies.
    if (read_req_r2 != read_req_r2_prev) begin
        sdr_addr_ram <= sdr_addr_sys;
        index_ram    <= index_sys;
    end

    if (sdr_rdy) begin
        cache_data[index_ram] <= sdr_data;  // use latched index, NOT live `index`
        read_ack <= read_req_r2;
    end

    if (read_req_r2 != read_req_prev) begin
        sdr_req <= 1;
    end
end

endmodule
