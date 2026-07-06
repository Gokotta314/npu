`timescale 1ns/1ps

module tb_worker_core;

parameter num       = 4;
parameter size_bf16 = 16;
parameter DW        = num*size_bf16;
parameter ADDR_W    = 32;
parameter MEM_LATENCY = 8;
parameter MEM_DEPTH   = 4096;

parameter WMEM_BASE = 32'd1000;
parameter IMEM_BASE = 32'd2000;
parameter OMEM_BASE = 32'd3000;

reg CLK, RESET;

integer pass_count = 0;
integer fail_count = 0;

// ---------------- DUT: worker_core ----------------
reg               task_valid;
wire              task_ready;
reg  [ADDR_W-1:0] task_waddr, task_iaddr, task_oaddr;
wire              task_done;

wire              mem_req_valid, mem_req_wen, mem_req_ready, mem_resp_valid;
wire [ADDR_W-1:0] mem_req_addr;
wire [DW-1:0]     mem_req_wdata, mem_resp_rdata;

wire [31:0] hit_count, miss_count, prefetch_issued_count, prefetch_useful_count;

worker_core #(.num(num), .size_bf16(size_bf16), .ADDR_W(ADDR_W), .DW(DW)) dut (
    .CLK(CLK), .RESET(RESET),
    .task_valid(task_valid), .task_ready(task_ready),
    .task_waddr(task_waddr), .task_iaddr(task_iaddr), .task_oaddr(task_oaddr),
    .task_done(task_done),
    .mem_req_valid(mem_req_valid), .mem_req_ready(mem_req_ready), .mem_req_wen(mem_req_wen),
    .mem_req_addr(mem_req_addr), .mem_req_wdata(mem_req_wdata),
    .mem_resp_valid(mem_resp_valid), .mem_resp_rdata(mem_resp_rdata),
    .hit_count(hit_count), .miss_count(miss_count),
    .prefetch_issued_count(prefetch_issued_count), .prefetch_useful_count(prefetch_useful_count)
);

main_memory #(.num(num), .size_bf16(size_bf16), .ADDR_W(ADDR_W), .DEPTH(MEM_DEPTH), .LATENCY(MEM_LATENCY)) u_mem (
    .CLK(CLK), .RESET(RESET),
    .req_valid(mem_req_valid), .req_ready(mem_req_ready),
    .req_wen(mem_req_wen), .req_addr(mem_req_addr), .req_wdata(mem_req_wdata),
    .resp_valid(mem_resp_valid), .resp_rdata(mem_resp_rdata)
);

// ---------------- golden ----------------
localparam WADDR_INT_G = 16'd0;
localparam IADDR_INT_G = num;
localparam OADDR_INT_G = 2*num;

reg  [DW-1:0] weight_data [0:num-1];
reg  [DW-1:0] act_data    [0:num-1];
reg  [DW-1:0] gold_result [0:num-1];

reg           gold_en;
wire [5:0]    gold_state;
reg  [DW-1:0] gold_input_data;
wire [DW-1:0] gold_output_out;

accelerator #(.num(num), .size_bf16(size_bf16)) u_gold (
    .CLK(CLK), .RESET(RESET), .EN(gold_en), .NMC_EN(gold_en),
    .IADDR(IADDR_INT_G[15:0]), .WADDR(WADDR_INT_G[15:0]), .OADDR(OADDR_INT_G[15:0]),
    .STATE(gold_state),
    .input_data(gold_input_data), .output_out(gold_output_out)
);

localparam G_INPUTSW=6'd1, G_INPUTSA=6'd2, G_OUTPUTSW=6'd7, G_RETURN=6'd8;

reg [5:0] gold_state_d;
always @(posedge CLK or negedge RESET) begin
    if (~RESET) gold_state_d <= 6'd0;
    else        gold_state_d <= gold_state;
end

wire gold_enter_w  = (gold_state==G_INPUTSW)  && (gold_state_d!=G_INPUTSW);
wire gold_enter_a  = (gold_state==G_INPUTSA)  && (gold_state_d!=G_INPUTSA);
wire gold_enter_ow = (gold_state==G_OUTPUTSW) && (gold_state_d!=G_OUTPUTSW);
wire gold_enter_ret= (gold_state==G_RETURN)   && (gold_state_d!=G_RETURN);

reg [7:0] gold_cnt;
always @(posedge CLK or negedge RESET) begin
    if (~RESET) gold_cnt <= 8'd0;
    else if (gold_enter_w || gold_enter_a || gold_enter_ow) gold_cnt <= 8'd1;
    else if (gold_state==G_INPUTSW || gold_state==G_INPUTSA || gold_state==G_OUTPUTSW)
        gold_cnt <= gold_cnt + 8'd1;
end
wire [7:0] gold_eff = (gold_enter_w || gold_enter_a || gold_enter_ow) ? 8'd0 : gold_cnt;

always @(*) begin
    case (gold_state)
        G_INPUTSW: gold_input_data = weight_data[gold_eff];
        G_INPUTSA: gold_input_data = act_data[gold_eff];
        default:   gold_input_data = {DW{1'b0}};
    endcase
end

integer gi;
always @(posedge CLK or negedge RESET) begin
    if (~RESET) begin
        for (gi = 0; gi < num; gi = gi + 1) gold_result[gi] <= {DW{1'b0}};
    end else if ((gold_state == G_OUTPUTSW) && (gold_eff != 8'd0)) begin
        gold_result[gold_eff - 8'd1] <= gold_output_out;
    end else if (gold_enter_ret) begin
        gold_result[num-1] <= gold_output_out;
    end
end

reg gold_done;
always @(posedge CLK or negedge RESET) begin
    if (~RESET) gold_done <= 1'b0;
    else begin
        gold_done <= 1'b0;
        if (gold_enter_ret) gold_done <= 1'b1;
    end
end

// ----------------- record -----------------
initial begin
	$fsdbDumpfile("tb.fsdb");
	$fsdbDumpvars;
	$fsdbDumpMDA();
end

// ---------------- clock ----------------
initial CLK = 0;
always #5 CLK = ~CLK;

// ---------------- 测试数据 ----------------
// bf16编码: 1.0=0x3F80  2.0=0x4000  0.5=0x3F00  1.5=0x3FC0  -1.0=0xBF80  3.0=0x4040
integer di;
initial begin
    for (di = 0; di < num; di = di + 1) begin
        weight_data[di] = {16'h3F80, 16'h4000, 16'h3F00, 16'h3FC0}; // 每个lane固定给1.0/2.0/0.5/1.5
        act_data[di]    = {16'h3F80, 16'h3F80, 16'h4000, 16'hBF80}; // 1.0/1.0/2.0/-1.0
    end
end

initial begin
    // 把同一批数据预置进main_memory，供worker_core通过cache去取
    #1; // 等上面initial块把weight_data/act_data填好
    for (di = 0; di < num; di = di + 1) begin
        u_mem.mem[WMEM_BASE + di] = weight_data[di];
        u_mem.mem[IMEM_BASE + di] = act_data[di];
    end
end

initial begin
    RESET = 0; task_valid = 0; task_waddr = 0; task_iaddr = 0; task_oaddr = 0;
    gold_en = 0;
    repeat(3) @(negedge CLK);
    RESET = 1;
    repeat(3) @(negedge CLK);

    // ---- 同时触发 worker_core 的任务 和 golden 的直连计算 ----
    @(negedge CLK);
    task_waddr = WMEM_BASE;
    task_iaddr = IMEM_BASE;
    task_oaddr = OMEM_BASE;
    task_valid = 1'b1;
    gold_en    = 1'b1;
    @(negedge CLK);
    task_valid = 1'b0;

    // ---- 等两边都跑完 ----
    fork
        begin : wait_worker
            while (!task_done) @(negedge CLK);
        end
        begin : wait_gold
            while (!gold_done) @(negedge CLK);
        end
    join

    $display("\n=== worker_core task_done and golden both completed, comparing results ===");
    for (di = 0; di < num; di = di + 1) begin
        if (u_mem.mem[OMEM_BASE + di] !== gold_result[di]) begin
            $display("[FAIL] result[%0d]: worker wrote %h, golden = %h", di, u_mem.mem[OMEM_BASE+di], gold_result[di]);
            fail_count = fail_count + 1;
        end else begin
            $display("[PASS] result[%0d] = %h (matches golden)", di, gold_result[di]);
            pass_count = pass_count + 1;
        end
    end

    $display("\n=== 存储子系统统计 ===");
    $display("hit_count=%0d miss_count=%0d prefetch_issued=%0d prefetch_useful=%0d",
               hit_count, miss_count, prefetch_issued_count, prefetch_useful_count);
    $display("（这里预期miss_count大约等于本次任务实际发起的独立填充次数，具体数值取决于");
    $display(" fetch阶段访问的num个连续地址里，stride prefetcher能提前预取到多少个）");

    $display("\n=== TEST SUMMARY ===");
    $display("PASS=%0d FAIL=%0d", pass_count, fail_count);
    if (fail_count == 0) begin
        $display(">>> ALL PASS <<<");
    end else begin
        $display(">>> CHECK FAILED, see [FAIL] lines above ");
    end

    $finish;
end

// 简单的看门狗，防止testbench卡死跑不完
initial begin
    #100000;
    $display("[TIMEOUT] simulation did not finish within watchdog window, worker_core或golden可能卡在某个状态没有前进");
    $finish;
end

endmodule
