module npu_dispatcher #(
    parameter N       = 2,
    parameter ADDR_W  = 32,
    parameter DATA_W  = 32
)(
    input  wire                    CLK,
    input  wire                    RESET,

    // ---------------- AXI4-Lite 从设备端口 ----------------
    input  wire [ADDR_W-1:0]       s_axil_awaddr,
    input  wire                    s_axil_awvalid,
    output reg                     s_axil_awready,
    input  wire [DATA_W-1:0]       s_axil_wdata,
    input  wire [DATA_W/8-1:0]     s_axil_wstrb,
    input  wire                    s_axil_wvalid,
    output reg                     s_axil_wready,
    output reg  [1:0]              s_axil_bresp,
    output reg                     s_axil_bvalid,
    input  wire                    s_axil_bready,
    input  wire [ADDR_W-1:0]       s_axil_araddr,
    input  wire                    s_axil_arvalid,
    output reg                     s_axil_arready,
    output reg  [DATA_W-1:0]       s_axil_rdata,
    output reg  [1:0]              s_axil_rresp,
    output reg                     s_axil_rvalid,
    input  wire                    s_axil_rready,

    output wire                    irq,          // 电平中断：任意worker DONE位置1就拉高

    // ---------------- N个worker的本地任务接口 ----------------
    output wire [N-1:0]            task_valid,
    input  wire [N-1:0]            task_ready,
    output wire [N*ADDR_W-1:0]     task_waddr,
    output wire [N*ADDR_W-1:0]     task_iaddr,
    output wire [N*ADDR_W-1:0]     task_oaddr,
    input  wire [N-1:0]            task_done,
    input  wire [N*32-1:0]         hit_count,
    input  wire [N*32-1:0]         miss_count,
    input  wire [N*32-1:0]         prefetch_issued_count,
    input  wire [N*32-1:0]         prefetch_useful_count
);

localparam IDXW = (N<=1) ? 1 : $clog2(N);

reg [ADDR_W-1:0] waddr_reg [0:N-1];
reg [ADDR_W-1:0] iaddr_reg [0:N-1];
reg [ADDR_W-1:0] oaddr_reg [0:N-1];
reg              busy_reg  [0:N-1];
reg              done_reg  [0:N-1];
reg              start_pulse [0:N-1];

genvar gi;
generate
    for (gi = 0; gi < N; gi = gi + 1) begin : TASK_OUT
        assign task_valid[gi]                       = start_pulse[gi];
        assign task_waddr[gi*ADDR_W +: ADDR_W]       = waddr_reg[gi];
        assign task_iaddr[gi*ADDR_W +: ADDR_W]       = iaddr_reg[gi];
        assign task_oaddr[gi*ADDR_W +: ADDR_W]       = oaddr_reg[gi];
    end
endgenerate

wire [N-1:0] done_flat;
generate
    for (gi = 0; gi < N; gi = gi + 1) begin : DONE_FLAT
        assign done_flat[gi] = done_reg[gi];
    end
endgenerate
assign irq = |done_flat;

integer bi;
always @(posedge CLK or negedge RESET) begin
    if (~RESET) begin
        for (bi = 0; bi < N; bi = bi + 1) begin
            waddr_reg[bi] <= {ADDR_W{1'b0}};
            iaddr_reg[bi] <= {ADDR_W{1'b0}};
            oaddr_reg[bi] <= {ADDR_W{1'b0}};
            busy_reg[bi]  <= 1'b0;
            done_reg[bi]  <= 1'b0;
            start_pulse[bi] <= 1'b0;
        end
        s_axil_awready <= 1'b0;
        s_axil_wready  <= 1'b0;
        s_axil_bvalid  <= 1'b0;
        s_axil_bresp   <= 2'd0;
        s_axil_arready <= 1'b0;
        s_axil_rvalid  <= 1'b0;
        s_axil_rdata   <= {DATA_W{1'b0}};
        s_axil_rresp   <= 2'd0;
    end else begin
        // ---- 每拍先清一次性信号 ----
        for (bi = 0; bi < N; bi = bi + 1) start_pulse[bi] <= 1'b0;

        // ---- busy/done 状态更新：任务发出时置busy，task_done脉冲时清busy、置done ----
        for (bi = 0; bi < N; bi = bi + 1) begin
            if (start_pulse[bi]) busy_reg[bi] <= 1'b1;
            if (task_done[bi]) begin
                busy_reg[bi] <= 1'b0;
                done_reg[bi] <= 1'b1;
            end
        end

        // ---- 写通道 ----
        s_axil_awready <= 1'b0;
        s_axil_wready  <= 1'b0;
        if (s_axil_awvalid && s_axil_wvalid && !s_axil_bvalid) begin
            s_axil_awready <= 1'b1;
            s_axil_wready  <= 1'b1;
            s_axil_bvalid  <= 1'b1;
            s_axil_bresp   <= 2'd0; // OKAY

            case (s_axil_awaddr[5:0])
                6'h00: waddr_reg[s_axil_awaddr[ADDR_W-1:6]] <= s_axil_wdata;
                6'h04: iaddr_reg[s_axil_awaddr[ADDR_W-1:6]] <= s_axil_wdata;
                6'h08: oaddr_reg[s_axil_awaddr[ADDR_W-1:6]] <= s_axil_wdata;
                6'h0C: begin
                    if (s_axil_wdata[0] && task_ready[s_axil_awaddr[ADDR_W-1:6]])
                        start_pulse[s_axil_awaddr[ADDR_W-1:6]] <= 1'b1;
                end
                6'h10: begin
                    if (s_axil_wdata[1]) done_reg[s_axil_awaddr[ADDR_W-1:6]] <= 1'b0; // W1C
                end
                default: ; // 只读寄存器地址写入忽略
            endcase
        end
        if (s_axil_bvalid && s_axil_bready) s_axil_bvalid <= 1'b0;

        // ---- 读通道 ----
        s_axil_arready <= 1'b0;
        if (s_axil_arvalid && !s_axil_rvalid) begin
            s_axil_arready <= 1'b1;
            s_axil_rvalid  <= 1'b1;
            s_axil_rresp   <= 2'd0;
            case (s_axil_araddr[5:0])
                6'h00: s_axil_rdata <= waddr_reg[s_axil_araddr[ADDR_W-1:6]];
                6'h04: s_axil_rdata <= iaddr_reg[s_axil_araddr[ADDR_W-1:6]];
                6'h08: s_axil_rdata <= oaddr_reg[s_axil_araddr[ADDR_W-1:6]];
                6'h0C: s_axil_rdata <= {DATA_W{1'b0}};
                6'h10: s_axil_rdata <= {30'd0, done_reg[s_axil_araddr[ADDR_W-1:6]], busy_reg[s_axil_araddr[ADDR_W-1:6]]};
                6'h14: s_axil_rdata <= hit_count[s_axil_araddr[ADDR_W-1:6]*32 +: 32];
                6'h18: s_axil_rdata <= miss_count[s_axil_araddr[ADDR_W-1:6]*32 +: 32];
                6'h1C: s_axil_rdata <= prefetch_issued_count[s_axil_araddr[ADDR_W-1:6]*32 +: 32];
                6'h20: s_axil_rdata <= prefetch_useful_count[s_axil_araddr[ADDR_W-1:6]*32 +: 32];
                default: s_axil_rdata <= {DATA_W{1'b0}};
            endcase
        end
        if (s_axil_rvalid && s_axil_rready) s_axil_rvalid <= 1'b0;
    end
end

endmodule
