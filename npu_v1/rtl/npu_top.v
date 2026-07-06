module npu_top #(
    parameter N          = 2,      // worker核数量
    parameter num        = 4,      // 每个worker内部脉动阵列的边长
    parameter size_bf16  = 16,
    parameter ADDR_W     = 32,
    parameter DW          = num*size_bf16,
    parameter NUM_LINES   = 64,
    parameter MEM_LATENCY = 20,
    parameter MEM_DEPTH   = 65536
)(
    input  wire                    CLK,
    input  wire                    RESET,

    // ---------------- AXI4-Lite从设备端口 ----------------
    input  wire [ADDR_W-1:0]       s_axil_awaddr,
    input  wire                    s_axil_awvalid,
    output wire                    s_axil_awready,
    input  wire [31:0]             s_axil_wdata,
    input  wire [3:0]              s_axil_wstrb,
    input  wire                    s_axil_wvalid,
    output wire                    s_axil_wready,
    output wire [1:0]              s_axil_bresp,
    output wire                    s_axil_bvalid,
    input  wire                    s_axil_bready,
    input  wire [ADDR_W-1:0]       s_axil_araddr,
    input  wire                    s_axil_arvalid,
    output wire                    s_axil_arready,
    output wire [31:0]             s_axil_rdata,
    output wire [1:0]              s_axil_rresp,
    output wire                    s_axil_rvalid,
    input  wire                    s_axil_rready,

    output wire                    irq
);

// ---------------- dispatcher <-> workers ----------------
wire [N-1:0]        task_valid, task_ready, task_done;
wire [N*ADDR_W-1:0] task_waddr, task_iaddr, task_oaddr;
wire [N*32-1:0]      hit_count, miss_count, prefetch_issued_count, prefetch_useful_count;

npu_dispatcher #(.N(N), .ADDR_W(ADDR_W), .DATA_W(32)) u_dispatcher (
    .CLK(CLK), .RESET(RESET),
    .s_axil_awaddr(s_axil_awaddr), .s_axil_awvalid(s_axil_awvalid), .s_axil_awready(s_axil_awready),
    .s_axil_wdata(s_axil_wdata), .s_axil_wstrb(s_axil_wstrb), .s_axil_wvalid(s_axil_wvalid), .s_axil_wready(s_axil_wready),
    .s_axil_bresp(s_axil_bresp), .s_axil_bvalid(s_axil_bvalid), .s_axil_bready(s_axil_bready),
    .s_axil_araddr(s_axil_araddr), .s_axil_arvalid(s_axil_arvalid), .s_axil_arready(s_axil_arready),
    .s_axil_rdata(s_axil_rdata), .s_axil_rresp(s_axil_rresp), .s_axil_rvalid(s_axil_rvalid), .s_axil_rready(s_axil_rready),
    .irq(irq),
    .task_valid(task_valid), .task_ready(task_ready),
    .task_waddr(task_waddr), .task_iaddr(task_iaddr), .task_oaddr(task_oaddr),
    .task_done(task_done),
    .hit_count(hit_count), .miss_count(miss_count),
    .prefetch_issued_count(prefetch_issued_count), .prefetch_useful_count(prefetch_useful_count)
);

// ---------------- workers <-> arbiter ----------------
wire [N-1:0]        w_req_valid, w_req_ready, w_req_wen, w_resp_valid;
wire [N*ADDR_W-1:0]  w_req_addr;
wire [N*DW-1:0]      w_req_wdata, w_resp_rdata;

genvar gi;
generate
    for (gi = 0; gi < N; gi = gi + 1) begin : WORKERS
        worker_core #(.num(num), .size_bf16(size_bf16), .ADDR_W(ADDR_W), .DW(DW), .NUM_LINES(NUM_LINES)) u_worker (
            .CLK(CLK), .RESET(RESET),
            .task_valid(task_valid[gi]), .task_ready(task_ready[gi]),
            .task_waddr(task_waddr[gi*ADDR_W +: ADDR_W]),
            .task_iaddr(task_iaddr[gi*ADDR_W +: ADDR_W]),
            .task_oaddr(task_oaddr[gi*ADDR_W +: ADDR_W]),
            .task_done(task_done[gi]),
            .mem_req_valid(w_req_valid[gi]), .mem_req_ready(w_req_ready[gi]),
            .mem_req_wen(w_req_wen[gi]),
            .mem_req_addr(w_req_addr[gi*ADDR_W +: ADDR_W]),
            .mem_req_wdata(w_req_wdata[gi*DW +: DW]),
            .mem_resp_valid(w_resp_valid[gi]),
            .mem_resp_rdata(w_resp_rdata[gi*DW +: DW]),
            .hit_count(hit_count[gi*32 +: 32]),
            .miss_count(miss_count[gi*32 +: 32]),
            .prefetch_issued_count(prefetch_issued_count[gi*32 +: 32]),
            .prefetch_useful_count(prefetch_useful_count[gi*32 +: 32])
        );
    end
endgenerate

// ---------------- 仲裁器 ----------------
wire                m_req_valid, m_req_ready, m_req_wen, m_resp_valid;
wire [ADDR_W-1:0]   m_req_addr;
wire [DW-1:0]       m_req_wdata, m_resp_rdata;

mem_arbiter #(.N(N), .DW(DW), .ADDR_W(ADDR_W)) u_arbiter (
    .CLK(CLK), .RESET(RESET),
    .s_req_valid(w_req_valid), .s_req_ready(w_req_ready), .s_req_wen(w_req_wen),
    .s_req_addr(w_req_addr), .s_req_wdata(w_req_wdata),
    .s_resp_valid(w_resp_valid), .s_resp_rdata(w_resp_rdata),
    .m_req_valid(m_req_valid), .m_req_ready(m_req_ready), .m_req_wen(m_req_wen),
    .m_req_addr(m_req_addr), .m_req_wdata(m_req_wdata),
    .m_resp_valid(m_resp_valid), .m_resp_rdata(m_resp_rdata)
);

// ---------------- 仿真用背板主存----------------
main_memory #(.num(num), .size_bf16(size_bf16), .ADDR_W(ADDR_W), .DEPTH(MEM_DEPTH), .LATENCY(MEM_LATENCY)) u_main_mem (
    .CLK(CLK), .RESET(RESET),
    .req_valid(m_req_valid), .req_ready(m_req_ready),
    .req_wen(m_req_wen), .req_addr(m_req_addr), .req_wdata(m_req_wdata),
    .resp_valid(m_resp_valid), .resp_rdata(m_resp_rdata)
);

endmodule
