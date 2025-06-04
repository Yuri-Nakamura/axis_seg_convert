// Language: Verilog 2001

`resetall
`timescale 1ns / 1ps
`default_nettype none

/*
 * Author：sunyq
 * AXI stream to Segmented Interface
 */
module axis2seg #(
    parameter DATA_WIDTH = 1024,
    parameter KEEP_WIDTH = DATA_WIDTH/8,
    parameter SEG_WIDTH = KEEP_WIDTH/8,
    parameter SKIP_CRC = 0
)
(
    input  wire         clk,
    input  wire         rst,

    // AXIS interface
    input  wire [DATA_WIDTH-1:0]  axis_tdata,
    input  wire                   axis_tvalid,
    output wire                   axis_tready,
    input  wire                   axis_tlast,
    input  wire                   axis_tuser,
    input  wire [KEEP_WIDTH-1:0]  axis_tkeep,

    // MAC segmented interface
    output wire [DATA_WIDTH-1:0]  tx_mac_data,
    output wire                   tx_mac_valid,
    input  wire                   tx_mac_ready,
    output reg  [SEG_WIDTH-1:0]   tx_mac_inframe,
    output reg  [3*SEG_WIDTH-1:0] tx_mac_eop_empty,
    output reg  [SEG_WIDTH-1:0]   tx_mac_error,
    output wire [SEG_WIDTH-1:0]   tx_mac_skip_crc //optional
);

wire keep_full;

assign tx_mac_data  = axis_tdata;
assign tx_mac_valid = axis_tvalid;
//assign axis_tready  = tx_mac_ready;
assign axis_tready = 1;
assign tx_mac_skip_crc = {SEG_WIDTH{SKIP_CRC}};
assign keep_full = axis_tkeep[KEEP_WIDTH-1];

//tx_mac_inframe
integer i, eop;
always@*
begin
    eop = 0;
    if(axis_tvalid && ~axis_tlast) //valid and not last frame
    begin
        for(i = 0; i <= SEG_WIDTH-1; i = i + 1)
        begin
            tx_mac_inframe[i] = 1;
        end
    end
    else
    if(axis_tvalid && axis_tlast) //valid and last frame
    begin
        for(i = SEG_WIDTH-1; i >= 0; i = i - 1)
        begin
            if(~|axis_tkeep[8*i+:8])
            tx_mac_inframe[i] = 0;
            else
            begin
                if(eop == 0)
                begin
                    eop = 1;
                    tx_mac_inframe[i] = 0;
                end
                else
                tx_mac_inframe[i] = 1;
            end
        end
    end
    else
    ;
end

//tx_mac_eop_empty
integer j;
always@*
begin
    if(axis_tvalid && ~axis_tlast) 
    begin
        tx_mac_eop_empty = 0;
    end
    else
    begin
        if(axis_tvalid && axis_tlast)
        begin
            for(j = 0; j <= SEG_WIDTH - 1; j = j + 1)
            begin
                tx_mac_eop_empty[3*j+:3] = count_empty_bytes(axis_tkeep[8*j+:8]);
            end
        end
        else
        tx_mac_eop_empty = 0;
    end
end

//tx_mac_error
integer k;
always@*
begin
    if(axis_tvalid && ~axis_tlast)
    begin
        tx_mac_error = 0;
    end
    else
    begin
        if(axis_tvalid && axis_tlast)
        begin
                //tx_mac_error[k] = axis_tuser count_empty_bytes(axis_tkeep[8*k+:8]) keep_full;
                tx_mac_error = EOF_position(axis_tkeep) & {SEG_WIDTH{axis_tuser}};
        end
        else
        tx_mac_error = 0;
    end
end

function [2:0] count_empty_bytes;
input [7:0] keep_in;
integer l;
begin
    count_empty_bytes = 3'd0;
    for(l = 0; l <= 7; l = l + 1)
    begin
        count_empty_bytes = count_empty_bytes + ~keep_in[l];
    end
end
endfunction

function [SEG_WIDTH-1:0] EOF_position;
input [KEEP_WIDTH-1:0] keep_in;
integer m;
begin
    for(m = 0; m < SEG_WIDTH - 1; m = m + 1)
    begin
        if(count_empty_bytes(keep_in[8*m+:8]) != 3'b000)
        EOF_position[m] = 1;
        else
        begin
            if (keep_in[8*m+:8] == 8'b0000_0000)
            begin
                EOF_position[m] = 0;
            end
            else if(keep_in[8*m+:8] == 8'b1111_1111)
            begin
                if(keep_in[8*m+8+:8] == 8'b0000_0000)
                EOF_position[m] = 1;
                else
                EOF_position[m] = 0;
            end
        end
    end
    if(keep_in[SEG_WIDTH-8+:8] != 0)
    EOF_position[SEG_WIDTH-1] = 1;
    else
    EOF_position[SEG_WIDTH-1] = 0;
end
endfunction

endmodule

`resetall
