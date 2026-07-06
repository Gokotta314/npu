`timescale 1ns/1ps

module tb_npu_dispatcher;

parameter N      = 2;
parameter ADDR_W = 32;
parameter DATA_W = 32;

reg CLK, RESET;
integer pass_count = 0;
integer fail_count = 0;

reg  [ADDR_W-1:0] axi_awaddr;
reg               axi_awvalid;
wire              axi_awready;
reg  [DATA_W-1:0] axi_wdata;
reg  [3:0]        axi_wstrb;
reg               axi_wvalid;
wire              axi_wready;
wire [1:0]        axi_bresp;
wire              axi_bvalid;
reg               axi_bready;
reg  [ADDR_W-1:0] axi_araddr;
reg               axi_arvalid;
wire              axi_arready;
wire [DATA_W-1:0] axi_rdata;
wire [1:0]        axi_rresp;
wire              axi_rvalid;
reg               axi_rready;
wire              irq;

wire [N-1:0]        task_valid;
reg  [N-1:0]         task_ready;
wire [N*ADDR_W-1:0]  task_waddr, task_iaddr, task_oaddr;
reg  [N-1:0]         task_done;
reg  [N*32-1:0]      hit_count, miss_count, prefetch_issued_count, prefetch_useful_count;

npu_dispatcher #(.N(N), .ADDR_W(ADDR_W), .DATA_W(DATA_W)) dut (
    .CLK(CLK), .RESET(RESET),
    .s_axil_awaddr(axi_awaddr), .s_axil_awvalid(axi_awvalid), .s_axil_awready(axi_awready),
    .s_axil_wdata(axi_wdata), .s_axil_wstrb(axi_wstrb), .s_axil_wvalid(axi_wvalid), .s_axil_wready(axi_wready),
    .s_axil_bresp(axi_bresp), .s_axil_bvalid(axi_bvalid), .s_axil_bready(axi_bready),
    .s_axil_araddr(axi_araddr), .s_axil_arvalid(axi_arvalid), .s_axil_arready(axi_arready),
    .s_axil_rdata(axi_rdata), .s_axil_rresp(axi_rresp), .s_axil_rvalid(axi_rvalid), .s_axil_rready(axi_rready),
    .irq(irq),
    .task_valid(task_valid), .task_ready(task_ready),
    .task_waddr(task_waddr), .task_iaddr(task_iaddr), .task_oaddr(task_oaddr),
    .task_done(task_done),
    .hit_count(hit_count), .miss_count(miss_count),
    .prefetch_issued_count(prefetch_issued_count), .prefetch_useful_count(prefetch_useful_count)
);

initial CLK = 0;
always #5 CLK = ~CLK;

// ----------------- record -----------------
initial begin
	$fsdbDumpfile("tb.fsdb");
	$fsdbDumpvars;
	$fsdbDumpMDA();
end

// ---------------- AXI4-Lite BFM ----------------
task axil_write(input [ADDR_W-1:0] addr, input [DATA_W-1:0] data);
begin
    @(negedge CLK);
    axi_awaddr  = addr;
    axi_awvalid = 1'b1;
    axi_wdata   = data;
    axi_wstrb   = 4'hF;
    axi_wvalid  = 1'b1;
    axi_bready  = 1'b1;
    while (!(axi_awready && axi_wready)) @(negedge CLK);
    axi_awvalid = 1'b0;
    axi_wvalid  = 1'b0;
    while (!axi_bvalid) @(negedge CLK);
    @(negedge CLK);
    axi_bready = 1'b0;
end
endtask

task axil_read(input [ADDR_W-1:0] addr, output [DATA_W-1:0] data);
begin
    @(negedge CLK);
    axi_araddr  = addr;
    axi_arvalid = 1'b1;
    axi_rready  = 1'b1;
    while (!axi_arready) @(negedge CLK);
    axi_arvalid = 1'b0;
    while (!axi_rvalid) @(negedge CLK);
    data = axi_rdata;
    @(negedge CLK);
    axi_rready = 1'b0;
end
endtask

task check(input [DATA_W-1:0] got, input [DATA_W-1:0] expected, input [255:0] name);
begin
    if (got !== expected) begin
        $display("[FAIL] %0s: got=%h expect=%h", name, got, expected);
        fail_count = fail_count + 1;
    end else begin
        $display("[PASS] %0s: %h", name, got);
        pass_count = pass_count + 1;
    end
end
endtask

reg [DATA_W-1:0] rd;

initial begin
    RESET = 0;
    axi_awaddr=0; axi_awvalid=0; axi_wdata=0; axi_wstrb=0; axi_wvalid=0; axi_bready=0;
    axi_araddr=0; axi_arvalid=0; axi_rready=0;
    task_ready = {N{1'b1}};
    task_done  = {N{1'b0}};
    hit_count = 0; miss_count = 0; prefetch_issued_count = 0; prefetch_useful_count = 0;
    repeat(3) @(negedge CLK);
    RESET = 1;
    repeat(2) @(negedge CLK);

    $display("\n=== STEP 1: 写WADDR/IADDR/OADDR(worker0)，再读回校验 ===");
    axil_write(32'h00, 32'h1000_0000); // worker0 WADDR
    axil_write(32'h04, 32'h2000_0000); // worker0 IADDR
    axil_write(32'h08, 32'h3000_0000); // worker0 OADDR
    axil_read(32'h00, rd); check(rd, 32'h1000_0000, "worker0 WADDR readback");
    axil_read(32'h04, rd); check(rd, 32'h2000_0000, "worker0 IADDR readback");
    axil_read(32'h08, rd); check(rd, 32'h3000_0000, "worker0 OADDR readback");

    $display("\n=== STEP 2: 写CTRL(0x0C)的START位，检查task_valid[0]是不是打出一拍脉冲 ===");
    fork
        begin
            axil_write(32'h0C, 32'h0000_0001); // START=1
        end
        begin
            // 并行监视task_valid[0]，看有没有在合理窗口内出现恰好1拍的脉冲
            integer seen, cyc;
            seen = 0;
            for (cyc = 0; cyc < 20; cyc = cyc + 1) begin
                @(posedge CLK);
                if (task_valid[0]) seen = seen + 1;
            end
            if (seen == 1) begin
                $display("[PASS] task_valid[0] pulsed exactly once");
                pass_count = pass_count + 1;
            end else begin
                $display("[FAIL] task_valid[0] pulsed %0d times (expect 1)", seen);
                fail_count = fail_count + 1;
            end
        end
    join

    $display("\n=== STEP 3: 读STATUS(0x10)，此时应该BUSY=1,DONE=0 ===");
    axil_read(32'h10, rd);
    check(rd, 32'h0000_0001, "STATUS busy=1,done=0 right after START");

    $display("\n=== STEP 4: 模拟worker0做完任务(task_done脉冲一拍)，再读STATUS应该DONE=1,BUSY=0 ===");
    @(negedge CLK);
    task_done[0] = 1'b1;
    @(negedge CLK);
    task_done[0] = 1'b0;
    repeat(2) @(negedge CLK);
    axil_read(32'h10, rd);
    check(rd, 32'h0000_0002, "STATUS busy=0,done=1 after task_done");

    $display("\n=== STEP 5: 检查irq在DONE=1期间应该是高电平 ===");
    if (irq === 1'b1) begin
        $display("[PASS] irq asserted while DONE=1");
        pass_count = pass_count + 1;
    end else begin
        $display("[FAIL] irq not asserted while DONE=1");
        fail_count = fail_count + 1;
    end

    $display("\n=== STEP 6: 写STATUS的bit1(W1C)清DONE，irq应该跟着掉下去 ===");
    axil_write(32'h10, 32'h0000_0002);
    axil_read(32'h10, rd);
    check(rd, 32'h0000_0000, "STATUS after W1C clear");
    if (irq === 1'b0) begin
        $display("[PASS] irq deasserted after DONE cleared");
        pass_count = pass_count + 1;
    end else begin
        $display("[FAIL] irq still asserted after DONE cleared");
        fail_count = fail_count + 1;
    end

    $display("\n=== STEP 7: 统计寄存器读回是否正确 ===");
    hit_count[0*32 +: 32]  = 32'd123;
    miss_count[0*32 +: 32] = 32'd45;
    prefetch_issued_count[0*32 +: 32] = 32'd67;
    prefetch_useful_count[0*32 +: 32] = 32'd8;
    @(negedge CLK);
    axil_read(32'h14, rd); check(rd, 32'd123, "worker0 HIT_COUNT");
    axil_read(32'h18, rd); check(rd, 32'd45,  "worker0 MISS_COUNT");
    axil_read(32'h1C, rd); check(rd, 32'd67,  "worker0 PF_ISSUED");
    axil_read(32'h20, rd); check(rd, 32'd8,   "worker0 PF_USEFUL");

    $display("\n=== STEP 8: worker1的寄存器窗口(基址0x40)是不是独立、不会串到worker0 ===");
    axil_write(32'h40, 32'hDEAD_0000); // worker1 WADDR
    axil_read(32'h00, rd); check(rd, 32'h1000_0000, "worker0 WADDR unaffected by worker1 write");
    axil_read(32'h40, rd); check(rd, 32'hDEAD_0000, "worker1 WADDR readback");

    $display("\n=== TEST SUMMARY ===");
    $display("PASS=%0d FAIL=%0d", pass_count, fail_count);
    if (fail_count == 0) $display(">>> ALL PASS <<<");
    else                 $display(">>> CHECK FAILED, see [FAIL] lines above <<<");

    $finish;
end

initial begin
    #50000;
    $display("[TIMEOUT] watchdog fired");
    $finish;
end

endmodule
