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

module ga25_sdram(
    input clk,
    input clk_ram,

    input [21:0] addr_a,
    output reg [31:0] data_a,
    input req_a,
    output reg rdy_a,

    input [21:0] addr_b,
    output reg [31:0] data_b,
    input req_b,
    output reg rdy_b,

    input [21:0] addr_c,
    output reg [63:0] data_c,
    input req_c,
    output reg rdy_c,

    output reg [24:0] sdr_addr,
    input [63:0] sdr_data,
    output reg sdr_req,
    input sdr_rdy,
    output reg sdr_64bit
);

reg [1:0] active = 0;

reg active_rq = 0;
reg active_ack = 0;
reg [63:0] active_data;

reg req_a_2 = 0;
reg req_b_2 = 0;
reg req_c_2 = 0;
reg [24:0] addr_a_2, addr_b_2, addr_c_2;

always @(posedge clk) begin
    sdr_req <= 0;
    rdy_a <= 0;
    rdy_b <= 0;
    rdy_c <= 0;

    if (req_a & ~req_a_2) begin
        req_a_2 <= 1;
        addr_a_2 <= REGION_GFX.base_addr[24:0] | addr_a;
    end

    if (req_b & ~req_b_2) begin
        req_b_2 <= 1;
        addr_b_2 <= REGION_GFX.base_addr[24:0] | addr_b;
    end

    if (req_c & ~req_c_2) begin
        req_c_2 <= 1;
        addr_c_2 <= REGION_GFX.base_addr[24:0] | addr_c;
    end

    if (active) begin
        if (active_ack_s2 == active_rq) begin
            active <= 0;
            if (active == 2'd1) begin
                data_a <= active_data[31:0];
                rdy_a <= 1;
            end

            if (active == 2'd2) begin
                data_b <= active_data[31:0];
                rdy_b <= 1;
            end

            if (active == 2'd3) begin
                data_c <= active_data;
                rdy_c <= 1;
            end
        end
    end else begin
        if (req_a_2) begin
            sdr_addr <= addr_a_2;
            sdr_req <= 1;
            sdr_64bit <= 0;
            active_rq <= ~active_rq;
            active <= 2'd1;
            req_a_2 <= 0;
        end else if (req_b_2) begin
            sdr_addr <= addr_b_2;
            sdr_req <= 1;
            sdr_64bit <= 0;
            active_rq <= ~active_rq;
            active <= 2'd2;
            req_b_2 <= 0;
        end else if (req_c_2) begin
            sdr_addr <= addr_c_2;
            sdr_req <= 1;
            sdr_64bit <= 1;
            active_rq <= ~active_rq;
            active <= 2'd3;
            req_c_2 <= 0;
        end
    end
end

// Synchronise active_ack into clk domain (2-stage sync).
// On MiSTer clk==clk_ram so this is harmless; on Pocket they differ
// (28.6MHz vs 57.3MHz) and without sync active_ack is metastable in clk.
reg active_ack_s1 = 0, active_ack_s2 = 0;
always @(posedge clk) begin
    active_ack_s1 <= active_ack;
    active_ack_s2 <= active_ack_s1;
end

// Sync active_rq (clk_sys) into clk_ram before capturing
reg active_rq_r1 = 0, active_rq_r2 = 0;
always @(posedge clk_ram) begin
    active_rq_r1 <= active_rq;
    active_rq_r2 <= active_rq_r1;
end

always @(posedge clk_ram) begin
    if (sdr_rdy) begin
        active_ack <= active_rq_r2;  // use synced version
        active_data <= sdr_data;
    end
end

endmodule