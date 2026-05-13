//============================================================================
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

module ga25_obj (
    input clk,
    input clk_ram,

    input ce, // 13.33Mhz

    input ce_pix, // 6.66Mhz

    input reset,

    output reg [7:0] color,

    input NL,
    input hpulse,
    input vpulse,

    input [47:0] obj_in,
    input [2:0] obj_sel,

    input [63:0] sdr_data,
    output reg [24:0] sdr_addr,
    output reg sdr_req,
    input sdr_rdy,
    output reg sdr_refresh,

    input dbg_solid_sprites
);

reg [3:0] linebuf_color;
reg [9:0] linebuf_x;
reg linebuf_write;
reg linebuf_flip;
reg scan_toggle = 0;
reg [9:0] scan_pos = 0;
wire [9:0] scan_pos_nl = scan_pos ^ {1'b0, {9{NL}}};
wire [7:0] scan_out;

double_linebuf line_buffer(
    .clk(clk),
    .ce_pix(ce_pix),
    
    .scan_pos(scan_pos_nl),
    .scan_toggle(scan_toggle),
    .scan_out(scan_out),

    .bitplanes(dbg_solid_sprites ? 64'hffff_ffff_ffff_ffff : sdr_data),
    .flip(linebuf_flip),
    .color(linebuf_color),
    .pos(linebuf_x),
    .we(linebuf_write),
    
    .idle()
);

wire [8:0] obj_y = obj_in[8:0];
wire [3:0] obj_color = obj_in[12:9];
wire [1:0] obj_height = obj_in[14:13];
wire obj_flipy = obj_in[15];

wire [15:0] obj_code = obj_in[31:16];

wire [9:0] obj_x = obj_in[40:32];
wire obj_flipx = obj_in[41];

// CDC: sdr_req (clk_sys) -> clk_ram: synchronise before sampling
reg sdr_req_r1 = 0, sdr_req_sync = 0;
always_ff @(posedge clk_ram) begin
    sdr_req_r1   <= sdr_req;
    sdr_req_sync <= sdr_req_r1;
end

// data_rdy written in clk_ram, read in clk_sys: synchronise back
reg data_rdy_raw;
always_ff @(posedge clk_ram) begin
    if (sdr_req_sync)
        data_rdy_raw <= 0;
    else if (sdr_rdy)
        data_rdy_raw <= 1;
end

// Synchronise data_rdy into clk_sys domain
reg data_rdy_r1 = 0, data_rdy = 0;
always_ff @(posedge clk) begin
    data_rdy_r1 <= data_rdy_raw;
    data_rdy    <= data_rdy_r1;
end

reg [8:0] V;
wire [8:0] VE = V ^ {9{NL}};

always_ff @(posedge clk) begin
    reg visible;
    reg [8:0] height_px;
    reg [3:0] width;
    reg [8:0] rel_y;
    reg [8:0] row_y;
    reg [15:0] code;

    sdr_req <= 0;
    linebuf_write <= 0;

    if (reset) begin
        V <= 9'd0;
    end else if (ce) begin
        sdr_refresh <= 0;

        if (ce_pix) begin
            color <= scan_out[7:0];
            scan_pos <= scan_pos + 10'd1;
            if (hpulse) begin
                V <= V + 9'd1;
                scan_pos <= 10'd44;
                scan_toggle <= ~scan_toggle;
                visible <= 0;
                sdr_refresh <= 1;
            end
        end

        if (vpulse) begin
            V <= 9'd126;
        end

        if (obj_sel[0] | hpulse) begin
            linebuf_write <= visible;
            visible <= 0;
        end

        if (obj_sel[1]) begin
            height_px = 9'd16 << obj_height;
            rel_y = VE + obj_y + ( 9'd16 << obj_height );
            row_y = obj_flipy ? (height_px - rel_y - 9'd1) : rel_y;

            if (rel_y < height_px) begin
                code = obj_code + row_y[8:4];
                sdr_addr <= REGION_GFX.base_addr[24:0] + { code[15:0], row_y[3:0], 3'b000 };
                sdr_req <= 1;
                visible <= 1;
            end else begin
                visible <= 0;
                sdr_refresh <= 1;
            end
        end

        if (obj_sel[2]) begin
            linebuf_flip <= obj_flipx;
            linebuf_color <= obj_color;
            linebuf_x <= obj_x;
        end
    end

end

endmodule