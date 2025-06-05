// Language: Verilog 2001

`resetall
`timescale 1ns / 1ps
`default_nettype none

/*
 * Author：sunyq
 * Segmented Interface to AXI stream
 */
module seg2axis #(
    parameter DATA_WIDTH = 1024,
    parameter KEEP_WIDTH = DATA_WIDTH/8,
    parameter SEG_WIDTH = KEEP_WIDTH/8,
    parameter FIFO_DEPTH = 16,  //axis frame num in FIFO
    parameter BUFFER_DEPTH = 256,
    parameter BUFFER_ADDR_WIDTH = $clog2(BUFFER_DEPTH)
)(
    input  wire                         clk,
    input  wire                         rst,

    input  wire                         rx_mac_valid, //mac RX interface
    input  wire [DATA_WIDTH-1:0]        rx_mac_data,
    input  wire [SEG_WIDTH-1:0]         rx_mac_inframe,
    input  wire [3*SEG_WIDTH-1:0]       rx_mac_eop_empty,
    input  wire [SEG_WIDTH-1:0]         rx_mac_fcs_error,
    input  wire [2*SEG_WIDTH-1:0]       rx_mac_error,
    input  wire [3*SEG_WIDTH-1:0]       rx_mac_status_data,
    output wire                         rx_mac_ready,

    output wire  [DATA_WIDTH-1:0]        axis_tdata,    //AXIS TX interface
    output wire                          axis_tvalid,
    input  wire                          axis_tready,
    output wire                          axis_tlast,
    output wire                          axis_tuser,
    output wire  [KEEP_WIDTH-1:0]        axis_tkeep
);
    localparam BUFFER_MASK = (1 << BUFFER_ADDR_WIDTH) - 1;

    reg [DATA_WIDTH-1:0] s_axis_tdata = 0;  //between buffer & FIFO
    reg [KEEP_WIDTH-1:0] s_axis_tkeep = 0;
    //wire [KEEP_WIDTH-1:0] in_axis_tkeep;
    reg s_axis_tlast = 0;
    reg s_axis_tuser = 0;
    reg [63:0] buffer_data [0:BUFFER_DEPTH-1]; //256 segments
    reg [7:0] buffer_keep [0:BUFFER_DEPTH-1];
    reg [BUFFER_DEPTH-1:0] buffer_last;
    reg [BUFFER_DEPTH-1:0] buffer_user;
    reg [BUFFER_ADDR_WIDTH-1:0] pktstr_ptr;    //start pointer of 
    reg [BUFFER_ADDR_WIDTH-1:0] pktend_ptr;    //identify 16 EOFs
    reg [BUFFER_ADDR_WIDTH-1:0] valid_seg_in_buffer = 0;
    //reg [7:0] e;

    reg last_cycle_last_seg_inframe;  //seg 15 of last frame is full

    reg s_axis_tvalid; //FIFO input valid

    reg [$clog2(SEG_WIDTH):0] first_eof_seg;

    wire s_axis_tready; //FIFO input ready
    //wire axis_tready = 0;// do not input tready now
    
    integer a, b, c, d, e;

    assign rx_mac_ready = (pktstr_ptr - pktend_ptr > 2*SEG_WIDTH || pktstr_ptr == pktend_ptr) ? 1 : 0;//to do
    //assign in_axis_tkeep = s_axis_tkeep;
    //assign s_axis_tvalid = (frag_active && frag_pkt_len > 0);
    //assign s_axis_tvalid = (packet_deposited && frag_pkt_len > 0);
    //assign rx_mac_ready = ~rst ;//& ((pktstr_ptr - pktend_ptr >= 8'd16) || (pktstr_ptr == pktend_ptr));

    always@(posedge clk or posedge rst)
    begin
        if(rst)
        begin   //initialize
            for (a = 0; a < BUFFER_DEPTH; a = a + 1)
            begin
                buffer_data[a] <= 64'd0;
                buffer_keep[a] <= 8'd0;
            end
            buffer_last <= 0;
            buffer_user <= 0;
            pktend_ptr <= 0;
        end
        else
        begin
            if(rx_mac_valid)
            begin
                e = 0;
                for (b = 0; b < SEG_WIDTH; b = b + 1)
                begin
                    //send valid segment and EOF into buffer
                    if(rx_mac_inframe[b] || (b>0 && rx_mac_inframe[b-1]) || (b==0 && last_cycle_last_seg_inframe))
                    begin
                        buffer_data[(pktend_ptr+e) & BUFFER_MASK] <= rx_mac_data[64*b+:64];
                        buffer_keep[(pktend_ptr+e) & BUFFER_MASK] <= rx_mac_inframe[b] ? 8'hFF : (8'hFF >> rx_mac_eop_empty[3*b+:3]);
                        buffer_last[(pktend_ptr+e) & BUFFER_MASK] <= !rx_mac_inframe[b];
                        buffer_user[(pktend_ptr+e) & BUFFER_MASK] <= |rx_mac_error[2*b+:2] || rx_mac_fcs_error[b];
                        e = e + 1;
                    end
                    else
                    ;
                end
                last_cycle_last_seg_inframe <= rx_mac_inframe[SEG_WIDTH-1];
                pktend_ptr <= (pktend_ptr+e) & BUFFER_MASK;
            end
        end
    end

    always@*
    begin
        first_eof_seg = 0;
        valid_seg_in_buffer = pktend_ptr - pktstr_ptr;
        for(d = 0; d < SEG_WIDTH; d = d + 1)
        begin
            if(valid_seg_in_buffer <= SEG_WIDTH && d < valid_seg_in_buffer)
            begin
                if(buffer_last[(pktstr_ptr+valid_seg_in_buffer-1-d) & BUFFER_MASK])
                first_eof_seg = valid_seg_in_buffer-d;
            end
            else if(valid_seg_in_buffer > SEG_WIDTH)
            begin
                if(buffer_last[(pktstr_ptr+SEG_WIDTH-1-d) & BUFFER_MASK])
                first_eof_seg = SEG_WIDTH-d;
            end
            else ;
        end
    end


    //packet from buffer to FIFO
    always@(posedge clk or posedge rst)
    begin
        if(rst)
        begin
            pktstr_ptr <= 0;
            s_axis_tdata <= 0;
            s_axis_tkeep <= 0;
            s_axis_tlast <= 0;
            s_axis_tuser <= 0;
            s_axis_tvalid <= 0;
        end
        else
        begin
            if(pktend_ptr - pktstr_ptr < SEG_WIDTH && first_eof_seg == 0)//almost empty and no EOF
            s_axis_tvalid <= 0;//no dot extract buffer
            else if(first_eof_seg == 0)//not almost empty & all middle segments
            begin
                s_axis_tvalid <= 1;
                for(c = 0; c <= SEG_WIDTH-1; c = c + 1)
                begin
                    s_axis_tdata[c*64+:64] <= buffer_data[(pktstr_ptr+c) & BUFFER_MASK] & {{8{buffer_keep[pktstr_ptr][7]}},
                                                                            {8{buffer_keep[pktstr_ptr][6]}},
                                                                            {8{buffer_keep[pktstr_ptr][5]}},
                                                                            {8{buffer_keep[pktstr_ptr][4]}},
                                                                            {8{buffer_keep[pktstr_ptr][3]}},
                                                                            {8{buffer_keep[pktstr_ptr][2]}},
                                                                            {8{buffer_keep[pktstr_ptr][1]}},
                                                                            {8{buffer_keep[pktstr_ptr][0]}}};
                    s_axis_tkeep[c*8+:8] <= buffer_keep[(pktstr_ptr+c) & BUFFER_MASK];
                end
                s_axis_tlast <= 0;
                s_axis_tuser <= 0;
                pktstr_ptr <= pktstr_ptr + SEG_WIDTH;
            end
            else
            begin
                if(first_eof_seg !=0)//SEG_WIDTH segments include a EOF
                begin
                    s_axis_tvalid <= 1;
                    for(c = 0; c <= SEG_WIDTH-1; c = c + 1)
                    begin
                        if(c < first_eof_seg)
                        begin
                        s_axis_tdata[c*64+:64] <= buffer_data[(pktstr_ptr+c) & BUFFER_MASK] & {{8{buffer_keep[pktstr_ptr][7]}},
                                                                                {8{buffer_keep[pktstr_ptr][6]}},
                                                                                {8{buffer_keep[pktstr_ptr][5]}},
                                                                                {8{buffer_keep[pktstr_ptr][4]}},
                                                                                {8{buffer_keep[pktstr_ptr][3]}},
                                                                                {8{buffer_keep[pktstr_ptr][2]}},
                                                                                {8{buffer_keep[pktstr_ptr][1]}},
                                                                                {8{buffer_keep[pktstr_ptr][0]}}};
                        s_axis_tkeep[c*8+:8] <= buffer_keep[(pktstr_ptr+c) & BUFFER_MASK];
                        end
                        else
                        begin
                            s_axis_tdata[c*64+:64] <= 0;
                            s_axis_tkeep[c*8+:8] <= 0;
                        end
                    end
                    s_axis_tlast <= buffer_last[(pktstr_ptr+first_eof_seg-1) & BUFFER_MASK];
                    s_axis_tuser <= buffer_user[(pktstr_ptr+first_eof_seg-1) & BUFFER_MASK];
                    pktstr_ptr <= pktstr_ptr + first_eof_seg;
            end
            end
        end
    end

    axis_fifo #(
        .DEPTH(FIFO_DEPTH*KEEP_WIDTH),
        .DATA_WIDTH(DATA_WIDTH),
        .KEEP_ENABLE(1),
        .KEEP_WIDTH(KEEP_WIDTH),
        .LAST_ENABLE(1),
        .ID_ENABLE(0),
        .ID_WIDTH(),
        .DEST_ENABLE(0),
        .DEST_WIDTH(),
        .USER_ENABLE(1),
        .USER_WIDTH(1),
        .RAM_PIPELINE(),
        .OUTPUT_FIFO_ENABLE(0),
        .FRAME_FIFO(0),
        .USER_BAD_FRAME_VALUE(),
        .USER_BAD_FRAME_MASK(1'b0),
        .DROP_OVERSIZE_FRAME(),
        .DROP_BAD_FRAME(),
        .DROP_WHEN_FULL()
    ) axis_fifo_inst (
        .clk(clk),
        .rst(rst),
        .s_axis_tdata(s_axis_tdata),
        .s_axis_tkeep(s_axis_tkeep),
        .s_axis_tvalid(s_axis_tvalid),
        .s_axis_tready(s_axis_tready),
        .s_axis_tlast(s_axis_tlast),
        .s_axis_tid(),
        .s_axis_tdest(),
        .s_axis_tuser(s_axis_tuser),

        .m_axis_tdata(axis_tdata),
        .m_axis_tkeep(axis_tkeep),
        .m_axis_tvalid(axis_tvalid),
        .m_axis_tready(axis_tready),
        .m_axis_tlast(axis_tlast),
        .m_axis_tid(),
        .m_axis_tdest(),
        .m_axis_tuser(axis_tuser),

        .status_overflow(),
        .status_bad_frame(),
        .status_good_frame()
    );


endmodule

`resetall
