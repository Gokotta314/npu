`timescale 1ns/1ps

module tb_mem_arbiter;

parameter N      = 2;
parameter DW     = 64;
parameter ADDR_W = 32;
parameter MEM_LATENCY = 6;
parameter MEM_DEPTH   = 1024;

reg CLK, RESET;
integer pass_count = 0;
integer fail_count = 0;

reg  [N-1:0]        s_req_valid;
wire [N-1:0]        s_req_ready;
reg  [N-1:0]        s_req_wen;
reg  [N*ADDR_W-1:0] s_req_addr;
reg  [N*DW-1:0]     s_req_wdata;
wire [N-1:0]        s_resp_valid;
wire [N*DW-1:0]     s_resp_rdata;

wire                m_req_valid, m_req_ready, m_req_wen, m_resp_valid;
wire [ADDR_W-1:0]   m_req_addr;
wire [DW-1:0]       m_req_wdata, m_resp_rdata;

mem_arbiter #(.N(N), .DW(DW), .ADDR_W(ADDR_W)) dut (
    .CLK(CLK), .RESET(RESET),
    .s_req_valid(s_req_valid), .s_req_ready(s_req_ready), .s_req_wen(s_req_wen),
    .s_req_addr(s_req_addr), .s_req_wdata(s_req_wdata),
    .s_resp_valid(s_resp_valid), .s_resp_rdata(s_resp_rdata),
    .m_req_valid(m_req_valid), .m_req_ready(m_req_ready), .m_req_wen(m_req_wen),
    .m_req_addr(m_req_addr), .m_req_wdata(m_req_wdata),
    .m_resp_valid(m_resp_valid), .m_resp_rdata(m_resp_rdata)
);

main_memory #(.num(4), .size_bf16(16), .ADDR_W(ADDR_W), .DEPTH(MEM_DEPTH), .LATENCY(MEM_LATENCY)) u_mem (
    .CLK(CLK), .RESET(RESET),
    .req_valid(m_req_valid), .req_ready(m_req_ready),
    .req_wen(m_req_wen), .req_addr(m_req_addr), .req_wdata(m_req_wdata),
    .resp_valid(m_resp_valid), .resp_rdata(m_resp_rdata)
);

initial CLK = 0;
always #5 CLK = ~CLK;

// ----------------- record -----------------
initial begin
	$fsdbDumpfile("tb.fsdb");
	$fsdbDumpvars;
	$fsdbDumpMDA();
end

task automatic issue(input integer master, input wen, input [ADDR_W-1:0] addr, input [DW-1:0] wdata);
begin
    @(negedge CLK);
    s_req_valid[master]  = 1'b1;
    s_req_wen[master]    = wen;
    s_req_addr[master*ADDR_W +: ADDR_W]  = addr;
    s_req_wdata[master*DW +: DW]         = wdata;
    while (!s_req_ready[master]) @(negedge CLK);
    @(negedge CLK);
    s_req_valid[master] = 1'b0;
end
endtask

task automatic wait_resp(input integer master, input [DW-1:0] expected_if_read, input is_read);
begin
    while (!s_resp_valid[master]) @(negedge CLK);
    if (is_read) begin
        if (s_resp_rdata[master*DW +: DW] !== expected_if_read) begin
            $display("[FAIL] master%0d resp data=%h expect=%h", master, s_resp_rdata[master*DW +: DW], expected_if_read);
            fail_count = fail_count + 1;
        end else begin
            $display("[PASS] master%0d resp data=%h matches", master, s_resp_rdata[master*DW +: DW]);
            pass_count = pass_count + 1;
        end
    end else begin
        $display("[PASS] master%0d write ack received", master);
        pass_count = pass_count + 1;
    end
    @(negedge CLK);
end
endtask

initial begin
    RESET = 0; s_req_valid = 0; s_req_wen = 0; s_req_addr = 0; s_req_wdata = 0;
    repeat(3) @(negedge CLK);
    RESET = 1;
    repeat(2) @(negedge CLK);

    $display("\n=== STEP 1: 各自独立写后读，检查响应有没有串路由 ===");
    fork
        begin
            issue(0, 1, 32'd0, 64'hAAAA_AAAA_AAAA_AAAA);
            wait_resp(0, 0, 0);
            issue(0, 0, 32'd0, 0);
            wait_resp(0, 64'hAAAA_AAAA_AAAA_AAAA, 1);
        end
        begin
            issue(1, 1, 32'd100, 64'hBBBB_BBBB_BBBB_BBBB);
            wait_resp(1, 0, 0);
            issue(1, 0, 32'd100, 0);
            wait_resp(1, 64'hBBBB_BBBB_BBBB_BBBB, 1);
        end
    join

    $display("\n=== STEP 2: 两边同时持续发请求，观察授权是否轮流交替 ===");
    fork
        begin : m0_stream
            integer si;
            for (si = 0; si < 4; si = si + 1) begin
                issue(0, 1, 32'd1 + si, {DW{1'b0}} | si);
                wait_resp(0, 0, 0);
            end
        end
        begin : m1_stream
            integer si2;
            for (si2 = 0; si2 < 4; si2 = si2 + 1) begin
                issue(1, 1, 32'd101 + si2, {DW{1'b0}} | (si2+100));
                wait_resp(1, 0, 0);
            end
        end
    join

    $display("\n=== TEST SUMMARY ===");
    $display("PASS=%0d FAIL=%0d", pass_count, fail_count);
    if (fail_count == 0) $display(">>> ALL PASS <<<");
    else                 $display(">>> CHECK FAILED, see [FAIL] lines above <<<");
    $display("补充：STEP2跑完之后，建议你自己再拉一下m_req_addr的波形，肉眼确认0号段和100号段");
    $display("地址是不是交替出现——这个课本上叫round-robin fairness，光看PASS/FAIL数字看不出来。");

    $finish;
end

initial begin
    #50000;
    $display("[TIMEOUT] watchdog fired");
    $finish;
end

endmodule
