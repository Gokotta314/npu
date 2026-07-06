`timescale 1ns/1ps

module tb_npu_top;

parameter N          = 2;
parameter num        = 4;
parameter size_bf16  = 16;
parameter DW         = num*size_bf16;
parameter ADDR_W     = 32;
parameter MEM_LATENCY = 10;
parameter MEM_DEPTH   = 8192;

parameter W0_BASE = 32'd1000, I0_BASE = 32'd2000, O0_BASE = 32'd3000;
parameter W1_BASE = 32'd4000, I1_BASE = 32'd5000, O1_BASE = 32'd6000;

reg CLK, RESET;
integer pass_count = 0;
integer fail_count = 0;

reg  [ADDR_W-1:0] axi_awaddr;
reg               axi_awvalid;
wire              axi_awready;
reg  [31:0]       axi_wdata;
reg  [3:0]        axi_wstrb;
reg               axi_wvalid;
wire              axi_wready;
wire [1:0]        axi_bresp;
wire              axi_bvalid;
reg               axi_bready;
reg  [ADDR_W-1:0] axi_araddr;
reg               axi_arvalid;
wire              axi_arready;
wire [31:0]       axi_rdata;
wire [1:0]        axi_rresp;
wire              axi_rvalid;
reg               axi_rready;
wire              irq;

npu_top #(.N(N), .num(num), .size_bf16(size_bf16), .ADDR_W(ADDR_W),
          .MEM_LATENCY(MEM_LATENCY), .MEM_DEPTH(MEM_DEPTH)) dut (
    .CLK(CLK), .RESET(RESET),
    .s_axil_awaddr(axi_awaddr), .s_axil_awvalid(axi_awvalid), .s_axil_awready(axi_awready),
    .s_axil_wdata(axi_wdata), .s_axil_wstrb(axi_wstrb), .s_axil_wvalid(axi_wvalid), .s_axil_wready(axi_wready),
    .s_axil_bresp(axi_bresp), .s_axil_bvalid(axi_bvalid), .s_axil_bready(axi_bready),
    .s_axil_araddr(axi_araddr), .s_axil_arvalid(axi_arvalid), .s_axil_arready(axi_arready),
    .s_axil_rdata(axi_rdata), .s_axil_rresp(axi_rresp), .s_axil_rvalid(axi_rvalid), .s_axil_rready(axi_rready),
    .irq(irq)
);

initial CLK = 0;
always #5 CLK = ~CLK;

// ----------------- record -----------------
initial begin
	$fsdbDumpfile("tb.fsdb");
	$fsdbDumpvars;
	$fsdbDumpMDA();
end

// ---------------- AXI4-Lite BFM----------------
task axil_write(input [ADDR_W-1:0] addr, input [31:0] data);
begin
    @(negedge CLK);
    axi_awaddr = addr; axi_awvalid = 1'b1;
    axi_wdata  = data; axi_wstrb = 4'hF; axi_wvalid = 1'b1;
    axi_bready = 1'b1;
    while (!(axi_awready && axi_wready)) @(negedge CLK);
    axi_awvalid = 1'b0; axi_wvalid = 1'b0;
    while (!axi_bvalid) @(negedge CLK);
    @(negedge CLK);
    axi_bready = 1'b0;
end
endtask

task axil_read(input [ADDR_W-1:0] addr, output [31:0] data);
begin
    @(negedge CLK);
    axi_araddr = addr; axi_arvalid = 1'b1; axi_rready = 1'b1;
    while (!axi_arready) @(negedge CLK);
    axi_arvalid = 1'b0;
    while (!axi_rvalid) @(negedge CLK);
    data = axi_rdata;
    @(negedge CLK);
    axi_rready = 1'b0;
end
endtask

// ---------------- golden----------------
localparam WADDR_INT_G = 16'd0;
localparam IADDR_INT_G = num;
localparam OADDR_INT_G = 2*num;

reg  [DW-1:0] weight_data0 [0:num-1];
reg  [DW-1:0] act_data0    [0:num-1];
reg  [DW-1:0] weight_data1 [0:num-1];
reg  [DW-1:0] act_data1    [0:num-1];
reg  [DW-1:0] gold_result0 [0:num-1];
reg  [DW-1:0] gold_result1 [0:num-1];

reg           gold_en;
wire [5:0]    gold_state;
reg  [DW-1:0] gold_input_data;
wire [DW-1:0] gold_output_out;
reg  [DW-1:0] cur_weight [0:num-1];
reg  [DW-1:0] cur_act    [0:num-1];

accelerator #(.num(num), .size_bf16(size_bf16)) u_gold (
    .CLK(CLK), .RESET(RESET), .EN(gold_en), .NMC_EN(gold_en),
    .IADDR(IADDR_INT_G[15:0]), .WADDR(WADDR_INT_G[15:0]), .OADDR(OADDR_INT_G[15:0]),
    .STATE(gold_state),
    .input_data(gold_input_data), .output_out(gold_output_out)
);

localparam G_INPUTSW=6'd1, G_INPUTSA=6'd2, G_OUTPUTSW=6'd7, G_RETURN=6'd8;
reg [5:0] gold_state_d;
always @(posedge CLK or negedge RESET) begin
    if (~RESET) gold_state_d <= 6'd0; else gold_state_d <= gold_state;
end
wire gold_enter_w  = (gold_state==G_INPUTSW)  && (gold_state_d!=G_INPUTSW);
wire gold_enter_a  = (gold_state==G_INPUTSA)  && (gold_state_d!=G_INPUTSA);
wire gold_enter_ow = (gold_state==G_OUTPUTSW) && (gold_state_d!=G_OUTPUTSW);
wire gold_enter_ret= (gold_state==G_RETURN)   && (gold_state_d!=G_RETURN);

reg [7:0] gold_cnt;
always @(posedge CLK or negedge RESET) begin
    if (~RESET) gold_cnt <= 8'd0;
    else if (gold_enter_w || gold_enter_a || gold_enter_ow) gold_cnt <= 8'd1;
    else if (gold_state==G_INPUTSW || gold_state==G_INPUTSA || gold_state==G_OUTPUTSW) gold_cnt <= gold_cnt + 8'd1;
end
wire [7:0] gold_eff = (gold_enter_w||gold_enter_a||gold_enter_ow) ? 8'd0 : gold_cnt;

always @(*) begin
    case (gold_state)
        G_INPUTSW: gold_input_data = cur_weight[gold_eff];
        G_INPUTSA: gold_input_data = cur_act[gold_eff];
        default:   gold_input_data = {DW{1'b0}};
    endcase
end

// 结果抓取
reg [DW-1:0] gold_result_tmp [0:num-1];
integer gi;
always @(posedge CLK or negedge RESET) begin
    if (~RESET) begin
        for (gi=0; gi<num; gi=gi+1) gold_result_tmp[gi] <= {DW{1'b0}};
    end else if ((gold_state == G_OUTPUTSW) && (gold_eff != 8'd0)) begin
        gold_result_tmp[gold_eff - 8'd1] <= gold_output_out;
    end else if (gold_enter_ret) begin
        gold_result_tmp[num-1] <= gold_output_out;
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

task run_gold(input integer which); // 0=task0的数据, 1=task1的数据
    integer ci;
begin
    for (ci = 0; ci < num; ci = ci + 1) begin
        cur_weight[ci] = (which==0) ? weight_data0[ci] : weight_data1[ci];
        cur_act[ci]    = (which==0) ? act_data0[ci]    : act_data1[ci];
    end
    @(negedge CLK);
    gold_en = 1'b1;
    @(negedge CLK);
    while (!gold_done) @(negedge CLK);
    for (ci = 0; ci < num; ci = ci + 1) begin
        if (which==0) gold_result0[ci] = gold_result_tmp[ci];
        else          gold_result1[ci] = gold_result_tmp[ci];
    end
    gold_en = 1'b0;
    repeat(3) @(negedge CLK);   // 让accelerator内部彻底回到IDLE，避免和下一次run_gold抢时序
end
endtask

// ---------------- 测试数据 ----------------
integer di;
initial begin
    for (di = 0; di < num; di = di + 1) begin
        weight_data0[di] = {16'h1100+di[15:0], 16'h1101+di[15:0], 16'h1102+di[15:0], 16'h1103+di[15:0]};
        act_data0[di]    = {16'h2200+di[15:0], 16'h2201+di[15:0], 16'h2202+di[15:0], 16'h2203+di[15:0]};
        weight_data1[di] = {16'h3300+di[15:0], 16'h3301+di[15:0], 16'h3302+di[15:0], 16'h3303+di[15:0]};
        act_data1[di]    = {16'h4400+di[15:0], 16'h4401+di[15:0], 16'h4402+di[15:0], 16'h4403+di[15:0]};
    end
end

reg [31:0] rd;

initial begin
    RESET = 0;
    axi_awaddr=0; axi_awvalid=0; axi_wdata=0; axi_wstrb=0; axi_wvalid=0; axi_bready=0;
    axi_araddr=0; axi_arvalid=0; axi_rready=0;
    gold_en = 0;
    repeat(3) @(negedge CLK);
    RESET = 1;
    repeat(3) @(negedge CLK);
    #1;

    // 预置main_memory（跳过req通道，直接hierarchical poke）
    for (di = 0; di < num; di = di + 1) begin
        dut.u_main_mem.mem[W0_BASE+di] = weight_data0[di];
        dut.u_main_mem.mem[I0_BASE+di] = act_data0[di];
        dut.u_main_mem.mem[W1_BASE+di] = weight_data1[di];
        dut.u_main_mem.mem[I1_BASE+di] = act_data1[di];
    end

    $display("\n=== STEP 1: 通过AXI4-Lite同时给worker0和worker1配任务并START ===");
    axil_write(32'h00, W0_BASE);
    axil_write(32'h04, I0_BASE);
    axil_write(32'h08, O0_BASE);
    axil_write(32'h40, W1_BASE);
    axil_write(32'h44, I1_BASE);
    axil_write(32'h48, O1_BASE);
    axil_write(32'h0C, 32'h1); // worker0 START
    axil_write(32'h4C, 32'h1); // worker1 START

    $display("\n=== STEP 2: 轮询STATUS直到两个worker都DONE ===");
    begin : poll
        integer poll_cnt;
        reg done0, done1;
        done0 = 0; done1 = 0;
        poll_cnt = 0;
        while (!(done0 && done1) && poll_cnt < 2000) begin
            axil_read(32'h10, rd); done0 = rd[1];
            axil_read(32'h50, rd); done1 = rd[1];
            poll_cnt = poll_cnt + 1;
        end
        if (done0 && done1) begin
            $display("[PASS] both workers DONE after %0d polls", poll_cnt);
            pass_count = pass_count + 1;
        end else begin
            $display("[FAIL] workers did not finish within polling budget (done0=%0d done1=%0d)", done0, done1);
            fail_count = fail_count + 1;
        end
    end

    $display("\n=== STEP 3: 算golden结果，和main_memory里worker写回的结果对比 ===");
    run_gold(0);
    run_gold(1);
    for (di = 0; di < num; di = di + 1) begin
        if (dut.u_main_mem.mem[O0_BASE+di] !== gold_result0[di]) begin
            $display("[FAIL] worker0 result[%0d]=%h expect=%h", di, dut.u_main_mem.mem[O0_BASE+di], gold_result0[di]);
            fail_count = fail_count + 1;
        end else begin
            $display("[PASS] worker0 result[%0d] matches golden", di);
            pass_count = pass_count + 1;
        end
        if (dut.u_main_mem.mem[O1_BASE+di] !== gold_result1[di]) begin
            $display("[FAIL] worker1 result[%0d]=%h expect=%h", di, dut.u_main_mem.mem[O1_BASE+di], gold_result1[di]);
            fail_count = fail_count + 1;
        end else begin
            $display("[PASS] worker1 result[%0d] matches golden", di);
            pass_count = pass_count + 1;
        end
    end

    $display("\n=== STEP 4: 通过AXI4-Lite读回统计寄存器，看数字是否合理(非0，miss>=1) ===");
    axil_read(32'h14, rd); $display("worker0 hit_count=%0d",  rd);
    axil_read(32'h18, rd); $display("worker0 miss_count=%0d", rd);
    if (rd >= 1) begin
        $display("[PASS] worker0 miss_count>=1 (至少有一次真实的cold miss)");
        pass_count = pass_count + 1;
    end else begin
        $display("[FAIL] worker0 miss_count=0, 不合理(取数至少要miss一次)");
        fail_count = fail_count + 1;
    end
    axil_read(32'h1C, rd); $display("worker0 prefetch_issued=%0d", rd);
    axil_read(32'h20, rd); $display("worker0 prefetch_useful=%0d", rd);
    axil_read(32'h54, rd); $display("worker1 hit_count=%0d",  rd);
    axil_read(32'h58, rd); $display("worker1 miss_count=%0d", rd);

    $display("\n=== TEST SUMMARY ===");
    $display("PASS=%0d FAIL=%0d", pass_count, fail_count);
    if (fail_count == 0) $display(">>> ALL PASS <<<");
    else                 $display(">>> CHECK FAILED, see [FAIL] lines above <<<");

    $finish;
end

initial begin
    #200000;
    $display("[TIMEOUT] watchdog fired, likely stuck waiting on STATUS polling or task_done");
    $finish;
end

endmodule
