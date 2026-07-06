module accelerator #(parameter num = 4, parameter size_bf16 = 16)
(
    // interface to system
    input wire CLK,                         // CLK = 200MHz
    input wire RESET,                       // RESET, Negedge is active
    input wire EN,                          // enable signal for the accelerator, high for active
    input wire NMC_EN,				// enable computing
    // parameters giving by testbench (in real implementation should be given by instructions)
    // input wire [9:0] NIN,                   // input channel number
    // input wire [9:0] NOUT,                  // output channel number
    // input wire [15:0] ISIZE,                // input size (8bit for height, 8bit for width, 0 for height=1...)
    // input wire [5:0] IPADDING,              // input padding (3bit for height, 3bit for width, 0 for padding=0...)
    // input wire [7:0] WSIZE,                 // conv kernel size (4bit for height, 4bit for width, 0 for height=1...)
    // input wire [3:0] WSTRIDE,               // conv stride (2bit for height, 2bit for width, 0 for stride=1...)
    // input wire [5:0] OSHIFT,                // right shift bit of the data. 0 for shift=0...
    input wire [15:0] IADDR,                // input address for shared SRAM
    input wire [15:0] WADDR,                // weight address for shared SRAM
    input wire [15:0] OADDR,                // output address for shared SRAM
    output wire [5:0] STATE,                 // output state for the tb to check the runtime...
    input wire [num*size_bf16-1:0] input_data,
    output wire [num*size_bf16-1:0]output_out
    );

// controller
wire [15:0] share_addr;
//wire [5:0] STATE;
wire W_EN;
wire SELECTOR;
wire share_wen;
wire share_ren;
wire share_cen;
wire weight_ren;
wire weight_cen;
wire weight_wen;
wire [15:0] weight_addr;
wire input_ren;
wire input_cen;
wire input_wen;
wire [15:0] input_addr;
wire output_ren;
wire output_cen;
wire output_wen;
wire [15:0] output_addr;
controller #(.num(num))controller(
        .CLK(CLK),
        .RESET(RESET),
        .EN(EN),
        .STATE(STATE),
        .W_EN(W_EN),
        .NMC_EN(NMC_EN),
        .SELECTOR(SELECTOR),
        .share_wen(share_wen),
        .share_ren(share_ren),
        .share_cen(share_cen),
        .share_addr(share_addr),
        .weight_wen(weight_wen),
        .weight_ren(weight_ren),
        .weight_cen(weight_cen),
        .weight_addr(weight_addr),
        .activate_wen(input_wen),
        .activate_ren(input_ren),
        .activate_cen(input_cen),
        .activate_addr(input_addr),
        .output_wen(output_wen),
        .output_ren(output_ren),
        .output_cen(output_cen),
        .output_addr(output_addr),
        .IADDR(IADDR),
        .WADDR(WADDR),
        .OADDR(OADDR)
        //OUT PUT ADDR
        //.input_data(input_data)
    );

// // SRAM shared buffer
wire [num*size_bf16-1:0] share_out;
SRAM #(.num(num),.size_bf16(size_bf16))SRAM(
    .Q(share_out),
    .CLK(CLK),
    .RESET(RESET),
    .CEN(share_cen),
    .WEN(share_wen),
    .A(share_addr),
    .D(input_data),
    .RETN(share_ren)
);
// input buffer
wire [num*size_bf16-1:0] input_out;
input_buffer #(.num(num),.size_bf16(size_bf16))input_buffer(
    .Q(input_out),
    .CLK(CLK),
    .RESET(RESET),
    .CEN(input_cen),
    .WEN(input_wen),
    .A(input_addr),
    .D(share_out),
    .RETN(input_ren)
);
// // weight buffer
wire [num*size_bf16-1:0] weight_out;
weight_buffer #(.num(num),.size_bf16(size_bf16))weight_buffer(
    .Q(weight_out),
    .CLK(CLK),
    .RESET(RESET),
    .CEN(weight_cen),
    .WEN(weight_wen),
    .A(weight_addr),
    .D(share_out),
    .RETN(weight_ren)
);
// PE array
wire [num*size_bf16-1:0]out_sum;
wire [num*size_bf16-1:0]out_weight_below;
PE_array #(.num1(num),.num2(num),.size_bf16(size_bf16))PE_array(
        .CLK(CLK),
        .RESET(RESET),
        .EN(EN),
        .SELECTOR(SELECTOR),
        .W_EN(W_EN),
        // .....
        .active_left(input_out),
        .out_sum_final(out_sum),
        .in_weight_above(weight_out),
        .out_weight_final(out_weight_below)
    );
// output buffer
output_buffer #(.num(num),.size_bf16(size_bf16)) output_buffer(
    .Q(output_out),
    .CLK(CLK),
    .RESET(RESET),
    .CEN(output_cen),
    .WEN(output_wen),
    .A(output_addr),
    .D(out_sum),
    .RETN(output_ren)
    //.RESET(RESET)
);

endmodule
