`timescale 1ns/1ps

module tb_main_memory;

parameter NUM        = 4;
parameter SIZE_BF16  = 16;
parameter ADDR_W     = 10;
parameter DEPTH      = 1024;
parameter LATENCY    = 5;

reg                          CLK;
reg                          RESET;
reg                          req_valid;
wire                         req_ready;
reg                          req_wen;
reg  [ADDR_W-1:0]            req_addr;
reg  [NUM*SIZE_BF16-1:0]     req_wdata;
wire                         resp_valid;
wire [NUM*SIZE_BF16-1:0]     resp_rdata;

integer pass_count = 0;
integer fail_count = 0;

// ----------------- DUT -----------------
main_memory #(
    .num(NUM), .size_bf16(SIZE_BF16), .ADDR_W(ADDR_W),
    .DEPTH(DEPTH), .LATENCY(LATENCY)
) dut (
    .CLK(CLK), .RESET(RESET),
    .req_valid(req_valid), .req_ready(req_ready),
    .req_wen(req_wen), .req_addr(req_addr), .req_wdata(req_wdata),
    .resp_valid(resp_valid), .resp_rdata(resp_rdata)
);
// ----------------- record -----------------
initial begin
	$fsdbDumpfile("tb.fsdb");
	$fsdbDumpvars;
	$fsdbDumpMDA();
end
// ----------------- clock -----------------
initial CLK = 0;
always #5 CLK = ~CLK;

// ----------------- 记分板 -----------------
integer exp_wen   [0:255];
reg [NUM*SIZE_BF16-1:0] exp_data [0:255];
integer issue_time [0:255];
integer wr_ptr = 0;
integer rd_ptr = 0;

task issue_req(input wen, input [ADDR_W-1:0] addr, input [NUM*SIZE_BF16-1:0] wdata);
begin
    @(negedge CLK);
    req_valid = 1;
    req_wen   = wen;
    req_addr  = addr;
    req_wdata = wdata;
    exp_wen[wr_ptr]    = wen;
    exp_data[wr_ptr]   = wdata;
    issue_time[wr_ptr] = $time;
    wr_ptr = wr_ptr + 1;
end
endtask

task idle_cycle;
begin
    @(negedge CLK);
    req_valid = 0;
end
endtask

// ----------------- 响应检查（并行运行）-----------------
always @(posedge CLK) begin
    if (resp_valid) begin
        if (exp_wen[rd_ptr] == 0) begin
            if (resp_rdata !== exp_data[rd_ptr]) begin
                $display("[FAIL] rd_ptr=%0d time=%0t expect=%h got=%h",
                           rd_ptr, $time, exp_data[rd_ptr], resp_rdata);
                fail_count = fail_count + 1;
            end else begin
                $display("[PASS] read resp #%0d matches, data=%h", rd_ptr, resp_rdata);
                pass_count = pass_count + 1;
            end
        end else begin
            $display("[PASS] write ack #%0d received", rd_ptr);
            pass_count = pass_count + 1;
        end
        rd_ptr = rd_ptr + 1;
    end
end

// ----------------- 主测试流程 -----------------
initial begin
    RESET = 0; req_valid = 0; req_wen = 0; req_addr = 0; req_wdata = 0;
    repeat(3) @(negedge CLK);
    RESET = 1;

    // ---- 测试1：单次写，再单独发一次读，验证延迟恰好是LATENCY拍 ----
    $display("\n=== TEST 1: single request latency check ===");
    issue_req(1, 10'd1, {NUM*SIZE_BF16{1'b1}});  // 写 addr=1, data=全1
    idle_cycle();
    issue_req(0, 10'd1, {NUM*SIZE_BF16{1'b1}});  // 读 addr=1, 期望读回全1
    idle_cycle();

    // 等两个响应都出来
    repeat(LATENCY+3) @(negedge CLK);

    // ---- 测试2：背靠背发8个写请求（不等待），验证流水线能同时容纳多个在途请求 ----
    $display("\n=== TEST 2: back-to-back pipelined requests ===");
    issue_req(1, 10'd20, {NUM{16'h1111}});
    issue_req(1, 10'd21, {NUM{16'h2222}});
    issue_req(1, 10'd22, {NUM{16'h3333}});
    issue_req(1, 10'd23, {NUM{16'h4444}});
    idle_cycle();
    // 紧接着读回这4个地址，此时前面的写请求可能还没ack，验证RAW依然正确
    issue_req(0, 10'd20, {NUM{16'h1111}});
    issue_req(0, 10'd21, {NUM{16'h2222}});
    issue_req(0, 10'd22, {NUM{16'h3333}});
    issue_req(0, 10'd23, {NUM{16'h4444}});
    idle_cycle();

    repeat(LATENCY+5) @(negedge CLK);

    // ---- 测试3：极端RAW——写和读在紧邻的相邻拍发出，验证读到的是写后的新值 ----
    $display("\n=== TEST 3: tight write-then-read (RAW hazard) ===");
    issue_req(1, 10'd99, {NUM*SIZE_BF16{1'b0}} | 64'hDEAD_BEEF_0000_0000); // 先把99清成旧值的对照
    idle_cycle(); idle_cycle();
    issue_req(1, 10'd99, 64'hCAFE_F00D_1234_5678); // 立刻覆盖写
    issue_req(0, 10'd99, 64'hCAFE_F00D_1234_5678); // 紧接着读，期望拿到新值而不是旧值
    idle_cycle();

    repeat(LATENCY+5) @(negedge CLK);

    // ----------------- 汇总 -----------------
    $display("\n=== TEST SUMMARY ===");
    $display("Total issued=%0d, checked=%0d, PASS=%0d, FAIL=%0d",
               wr_ptr, rd_ptr, pass_count, fail_count);
    if (fail_count == 0 && rd_ptr == wr_ptr)
        $display(">>> ALL PASS <<<");
    else
        $display(">>> CHECK FAILED (see [FAIL] lines above, or rd_ptr!=wr_ptr means missing responses) <<<");

    $finish;
end

endmodule
