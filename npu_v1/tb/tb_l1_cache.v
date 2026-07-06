`timescale 1ns/1ps

module tb_l1_cache;

parameter DW        = 64;
parameter ADDR_W    = 32;
parameter NUM_LINES = 64;
parameter MEM_LATENCY = 8;
parameter MEM_DEPTH   = 1024;

reg               CLK, RESET;
reg               req_valid;
wire              req_ready;
reg  [ADDR_W-1:0] req_addr;
wire              resp_valid;
wire [DW-1:0]     resp_data;

wire              mem_req_valid, mem_req_wen, mem_req_ready, mem_resp_valid;
wire [ADDR_W-1:0] mem_req_addr;
wire [DW-1:0]     mem_req_wdata, mem_resp_rdata;

wire [31:0] hit_count, miss_count, prefetch_issued_count, prefetch_useful_count;

integer pass_count = 0;
integer fail_count = 0;

l1_cache #(.DW(DW), .ADDR_W(ADDR_W), .NUM_LINES(NUM_LINES)) dut (
    .CLK(CLK), .RESET(RESET),
    .req_valid(req_valid), .req_ready(req_ready), .req_addr(req_addr),
    .resp_valid(resp_valid), .resp_data(resp_data),
    .mem_req_valid(mem_req_valid), .mem_req_ready(mem_req_ready),
    .mem_req_wen(mem_req_wen), .mem_req_addr(mem_req_addr), .mem_req_wdata(mem_req_wdata),
    .mem_resp_valid(mem_resp_valid), .mem_resp_rdata(mem_resp_rdata),
    .hit_count(hit_count), .miss_count(miss_count),
    .prefetch_issued_count(prefetch_issued_count), .prefetch_useful_count(prefetch_useful_count)
);

main_memory #(.num(4), .size_bf16(16), .ADDR_W(ADDR_W), .DEPTH(MEM_DEPTH), .LATENCY(MEM_LATENCY)) u_mem (
    .CLK(CLK), .RESET(RESET),
    .req_valid(mem_req_valid), .req_ready(mem_req_ready),
    .req_wen(mem_req_wen), .req_addr(mem_req_addr), .req_wdata(mem_req_wdata),
    .resp_valid(mem_resp_valid), .resp_rdata(mem_resp_rdata)
);

initial CLK = 0;
always #5 CLK = ~CLK;

// ----------------- record -----------------
initial begin
	$fsdbDumpfile("tb.fsdb");
	$fsdbDumpvars;
	$fsdbDumpMDA();
end

// ---- 预置主存内容----
initial begin
    u_mem.mem[0]   = 64'hAAAA_0000_0000_0000;
    u_mem.mem[1]   = 64'hAAAA_0000_0000_0001;
    u_mem.mem[2]   = 64'hAAAA_0000_0000_0002;
    u_mem.mem[3]   = 64'hAAAA_0000_0000_0003;
    u_mem.mem[4]   = 64'hAAAA_0000_0000_0004;
    u_mem.mem[100] = 64'hBBBB_0000_0000_0100;
    u_mem.mem[55]  = 64'hBBBB_0000_0000_0055;
    u_mem.mem[7]   = 64'hBBBB_0000_0000_0007;
end

// ---- 带背压处理的access task ----
task access(input [ADDR_W-1:0] addr, input [DW-1:0] expected);
begin
    @(negedge CLK);
    req_valid = 1'b1;
    req_addr  = addr;
    while (!req_ready) @(negedge CLK);   // 若cache正忙(比如在处理预取填充)，排队等
    @(negedge CLK);
    req_valid = 1'b0;
    while (!resp_valid) @(negedge CLK);
    if (resp_data !== expected) begin
        $display("[FAIL] addr=%0d time=%0t expect=%h got=%h", addr, $time, expected, resp_data);
        fail_count = fail_count + 1;
    end else begin
        $display("[PASS] addr=%0d data=%h", addr, resp_data);
        pass_count = pass_count + 1;
    end
    @(negedge CLK);
end
endtask

reg [31:0] hit_before, miss_before, pfu_before;

initial begin
    RESET = 0; req_valid = 0; req_addr = 0;
    repeat(3) @(negedge CLK);
    RESET = 1;
    repeat(2) @(negedge CLK);

    $display("\n=== STEP 1: sequential access 0,1,2,3 to train the stride table ===");
    access(0, 64'hAAAA_0000_0000_0000);
    access(1, 64'hAAAA_0000_0000_0001);
    access(2, 64'hAAAA_0000_0000_0002);
    access(3, 64'hAAAA_0000_0000_0003);

    $display("prefetch_issued_count after step1 = %0d (预期>0，说明预取器已经开始工作)", prefetch_issued_count);

    // 给预取填充留出足够时间完成（MEM_LATENCY拍+若干裕量）
    repeat(MEM_LATENCY + 5) @(negedge CLK);

    $display("\n=== STEP 2: access addr=4, expect a HIT thanks to prefetch ===");
    hit_before  = hit_count;
    miss_before = miss_count;
    pfu_before  = prefetch_useful_count;
    access(4, 64'hAAAA_0000_0000_0004);
    if (hit_count == hit_before + 1 && miss_count == miss_before) begin
        $display("[PASS] addr=4 was a cache HIT (hit_count %0d->%0d, miss_count unchanged)", hit_before, hit_count);
        pass_count = pass_count + 1;
    end else begin
        $display("[FAIL] addr=4 was NOT a hit as expected (hit_count %0d->%0d, miss_count %0d->%0d)",
                   hit_before, hit_count, miss_before, miss_count);
        fail_count = fail_count + 1;
    end
    if (prefetch_useful_count == pfu_before + 1) begin
        $display("[PASS] prefetch_useful_count incremented as expected");
        pass_count = pass_count + 1;
    end else begin
        $display("[FAIL] prefetch_useful_count did not increment (%0d->%0d)", pfu_before, prefetch_useful_count);
        fail_count = fail_count + 1;
    end

    $display("\n=== STEP 3: irregular access 100,55,7 should NOT get free prefetch hits ===");
    access(100, 64'hBBBB_0000_0000_0100);
    access(55,  64'hBBBB_0000_0000_0055);
    access(7,   64'hBBBB_0000_0000_0007);

    $display("\n=== TEST SUMMARY ===");
    $display("hit_count=%0d miss_count=%0d prefetch_issued=%0d prefetch_useful=%0d",
               hit_count, miss_count, prefetch_issued_count, prefetch_useful_count);
    $display("PASS=%0d FAIL=%0d", pass_count, fail_count);
    if (fail_count == 0) $display(">>> ALL PASS <<<");
    else                 $display(">>> CHECK FAILED, see [FAIL] lines above <<<");

    $finish;
end

endmodule
