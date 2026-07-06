`timescale 1ns/1ps

module tb_accelerator_direct;

parameter num       = 4;
parameter size_bf16 = 16;
parameter DW        = num*size_bf16;

reg           CLK, RESET, EN;
wire [5:0]    STATE;
reg  [DW-1:0] input_data;
wire [DW-1:0] output_out;

localparam WADDR_INT = 16'd0;
localparam IADDR_INT = num;
localparam OADDR_INT = 2*num;

accelerator #(.num(num), .size_bf16(size_bf16)) dut (
    .CLK(CLK), .RESET(RESET), .EN(EN), .NMC_EN(EN),
    .IADDR(IADDR_INT[15:0]), .WADDR(WADDR_INT[15:0]), .OADDR(OADDR_INT[15:0]),
    .STATE(STATE),
    .input_data(input_data), .output_out(output_out)
);

localparam ST_INPUTSW=6'd1, ST_INPUTSA=6'd2, ST_OUTPUTSW=6'd7, ST_RETURN=6'd8;

// bf16: 1.0=0x3F80 2.0=0x4000 0.5=0x3F00 1.5=0x3FC0 -1.0=0xBF80
reg [DW-1:0] weight_data [0:num-1];
reg [DW-1:0] act_data    [0:num-1];

integer di;
integer dump_i;
initial begin
    for (di = 0; di < num; di = di + 1) begin
        weight_data[di] = {16'h3F80, 16'h4000, 16'h3F00, 16'h3FC0};
        act_data[di]    = {16'h3F80, 16'h3F80, 16'h4000, 16'hBF80};
    end
end

initial CLK = 0;
always #5 CLK = ~CLK;

reg [7:0] cnt;
reg [5:0] state_d;

always @(posedge CLK or negedge RESET) begin
    if (~RESET) begin
        state_d <= 6'd0;
        cnt     <= 8'd0;
    end else begin
        state_d <= STATE;
        if (STATE != state_d) cnt <= 8'd1;   // 这一拍已经用掉index0，下一拍从1开始
        else                  cnt <= cnt + 8'd1;
    end
end

wire [7:0] eff_cnt = (STATE != state_d) ? 8'd0 : cnt;

always @(*) begin
    case (STATE)
        ST_INPUTSW: input_data = weight_data[eff_cnt];
        ST_INPUTSA: input_data = act_data[eff_cnt];
        default:    input_data = {DW{1'b0}};
    endcase
end

always @(posedge CLK) begin
    if (RESET)
        $display("t=%0t STATE=%0d eff_cnt=%0d input_data=%h output_out=%h  | share_out=%h input_out=%h weight_out=%h",
                   $time, STATE, eff_cnt, input_data, output_out,
                   dut.share_out, dut.input_out, dut.weight_out);
end

// ---- 额外监测PE_array内部的out_sum总线，看乘加链路本身有没有产生过非0值 ----
always @(posedge CLK) begin
    if (RESET && (STATE==6'd5 || STATE==6'd6))  // CALCULATE或OUTPUT状态
        $display("    [PE_array] t=%0t STATE=%0d out_sum_final=%h active_left(input_out)=%h in_weight_above(weight_out)=%h",
                   $time, STATE, dut.PE_array.out_sum_final, dut.PE_array.active_left, dut.PE_array.in_weight_above);
end

// ---- 深入到第0行第0列PE内部，看weight有没有被真的加载进来、乘加寄存器有没有值 ----
always @(posedge CLK) begin
    if (RESET)
        $display("        [PE row0col0] t=%0t STATE=%0d weight_1=%h weight_2=%h SELECTOR=%b W_EN=%b mul_iA=%h mul_iB=%h add_iA=%h add_iB=%h out_sum=%h",
                   $time, STATE,
                   dut.PE_array.label[0].gen_first_row.PE_row_unit.label[0].gen_first_pe.PE_unit.weight_1,
                   dut.PE_array.label[0].gen_first_row.PE_row_unit.label[0].gen_first_pe.PE_unit.weight_2,
                   dut.PE_array.label[0].gen_first_row.PE_row_unit.label[0].gen_first_pe.PE_unit.SELECTOR,
                   dut.PE_array.label[0].gen_first_row.PE_row_unit.label[0].gen_first_pe.PE_unit.W_EN,
                   dut.PE_array.label[0].gen_first_row.PE_row_unit.label[0].gen_first_pe.PE_unit.bf16_mul.iA,
                   dut.PE_array.label[0].gen_first_row.PE_row_unit.label[0].gen_first_pe.PE_unit.bf16_mul.iB,
                   dut.PE_array.label[0].gen_first_row.PE_row_unit.label[0].gen_first_pe.PE_unit.bf16_add.iA,
                   dut.PE_array.label[0].gen_first_row.PE_row_unit.label[0].gen_first_pe.PE_unit.bf16_add.iB,
                   dut.PE_array.label[0].gen_first_row.PE_row_unit.label[0].gen_first_pe.PE_unit.out_sum);
end

initial begin
	$fsdbDumpfile("tb.fsdb");
	$fsdbDumpvars;
	$fsdbDumpMDA();
end

initial begin
    RESET = 0; EN = 0; input_data = 0;
    repeat(3) @(negedge CLK);
    RESET = 1;
    repeat(3) @(negedge CLK);
    EN = 1'b1;

    wait (STATE == ST_RETURN);
    repeat(3) @(negedge CLK);

    $display("\n=== output_buffer里全部条目（地址0..%0d），用来判断OUTPUTSW读的窗口对不对 ===", 2*num-2);
    for (dump_i = 0; dump_i <= 2*num-2; dump_i = dump_i + 1) begin
        $display("output_buffer.mem[%0d] = %h", dump_i, dut.output_buffer.mem[dump_i]);
    end

    $display("\n=== 结束，请往上翻log，重点看ST_OUTPUTSW(state=7)那几拍的output_out ===");
    $finish;
end

initial begin
    #20000;
    $display("[TIMEOUT] accelerator没有在预期时间内跑到RETURN状态");
    $finish;
end

endmodule
