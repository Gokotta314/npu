module l1_cache #(
    parameter DW        = 64,
    parameter ADDR_W    = 32,
    parameter NUM_LINES = 64                    // 必须是2的幂
)(
    input  wire                  CLK,
    input  wire                  RESET,

    // ---------------- 需求端口（worker_core取数用）----------------
    input  wire                  req_valid,
    output wire                  req_ready,
    input  wire [ADDR_W-1:0]     req_addr,
    output reg                   resp_valid,
    output reg  [DW-1:0]         resp_data,

    // ---------------- 简化AXI4-Lite风格主设备端口（只读）----------------
    output reg                   mem_req_valid,
    input  wire                  mem_req_ready,
    output wire                  mem_req_wen,     // 恒为0：这个端口只发读请求
    output reg  [ADDR_W-1:0]     mem_req_addr,
    output wire [DW-1:0]         mem_req_wdata,   // 未使用，恒为0
    input  wire                  mem_resp_valid,
    input  wire [DW-1:0]         mem_resp_rdata,

    // ---------------- 统计计数器 ----------------
    output reg  [31:0]           hit_count,
    output reg  [31:0]           miss_count,
    output reg  [31:0]           prefetch_issued_count,
    output reg  [31:0]           prefetch_useful_count
);

localparam IDX_W  = $clog2(NUM_LINES);
localparam TAG_W  = ADDR_W - IDX_W;

localparam S_IDLE = 2'd0;
localparam S_WAIT = 2'd1;

reg [1:0] state;

// cache 存储阵列
reg               valid_arr [0:NUM_LINES-1];
reg [TAG_W-1:0]   tag_arr   [0:NUM_LINES-1];
reg [DW-1:0]      data_arr  [0:NUM_LINES-1];
reg               pf_filled [0:NUM_LINES-1];   // 用来统计"预取有没有用上"

wire [IDX_W-1:0] req_idx = req_addr[IDX_W-1:0];
wire [TAG_W-1:0] req_tag = req_addr[ADDR_W-1:IDX_W];
wire             req_hit = valid_arr[req_idx] && (tag_arr[req_idx] == req_tag);

// ---------------- stride 预取器 ----------------
reg                  pf_access_valid;
reg  [ADDR_W-1:0]    pf_access_addr;
wire                 pf_req_valid_w;
wire [ADDR_W-1:0]    pf_req_addr_w;
reg                  pf_req_accept;

stride_prefetcher #(.ADDR_W(ADDR_W)) u_prefetcher (
    .CLK(CLK), .RESET(RESET),
    .access_valid(pf_access_valid),
    .access_addr (pf_access_addr),
    .pf_req_valid(pf_req_valid_w),
    .pf_req_addr (pf_req_addr_w),
    .pf_req_accept(pf_req_accept)
);

wire [IDX_W-1:0] pf_idx = pf_req_addr_w[IDX_W-1:0];
wire [TAG_W-1:0] pf_tag = pf_req_addr_w[ADDR_W-1:IDX_W];
wire             pf_already_resident = valid_arr[pf_idx] && (tag_arr[pf_idx] == pf_tag);

assign req_ready    = (state == S_IDLE);
assign mem_req_wen  = 1'b0;
assign mem_req_wdata = {DW{1'b0}};

reg              pending_is_pf;
reg [IDX_W-1:0]  pending_idx;
reg [TAG_W-1:0]  pending_tag;

integer li;
always @(posedge CLK or negedge RESET) begin
    if (~RESET) begin
        state          <= S_IDLE;
        resp_valid     <= 1'b0;
        resp_data      <= {DW{1'b0}};
        mem_req_valid  <= 1'b0;
        mem_req_addr   <= {ADDR_W{1'b0}};
        hit_count      <= 32'd0;
        miss_count     <= 32'd0;
        prefetch_issued_count <= 32'd0;
        prefetch_useful_count <= 32'd0;
        pf_access_valid <= 1'b0;
        pf_req_accept   <= 1'b0;
        for (li = 0; li < NUM_LINES; li = li + 1) begin
            valid_arr[li] <= 1'b0;
            pf_filled[li] <= 1'b0;
        end
    end else begin
        resp_valid      <= 1'b0;
        pf_access_valid <= 1'b0;
        pf_req_accept   <= 1'b0;

        case (state)
        S_IDLE: begin
            if (req_valid) begin
                pf_access_valid <= 1'b1;
                pf_access_addr  <= req_addr;

                if (req_hit) begin
                    resp_valid <= 1'b1;
                    resp_data  <= data_arr[req_idx];
                    hit_count  <= hit_count + 32'd1;
                    if (pf_filled[req_idx]) begin
                        prefetch_useful_count <= prefetch_useful_count + 32'd1;
                        pf_filled[req_idx] <= 1'b0;
                    end
                end else begin
                    miss_count    <= miss_count + 32'd1;
                    mem_req_valid <= 1'b1;
                    mem_req_addr  <= req_addr;
                    pending_idx   <= req_idx;
                    pending_tag   <= req_tag;
                    pending_is_pf <= 1'b0;
                    state         <= S_WAIT;
                end
            end else if (pf_req_valid_w && !pf_already_resident) begin
                pf_req_accept <= 1'b1;
                mem_req_valid <= 1'b1;
                mem_req_addr  <= pf_req_addr_w;
                pending_idx   <= pf_idx;
                pending_tag   <= pf_tag;
                pending_is_pf <= 1'b1;
                prefetch_issued_count <= prefetch_issued_count + 32'd1;
                state <= S_WAIT;
            end else if (pf_req_valid_w && pf_already_resident) begin
                pf_req_accept <= 1'b1;
            end
        end

        S_WAIT: begin
            if (mem_req_valid && mem_req_ready)
                mem_req_valid <= 1'b0;

            if (mem_resp_valid) begin
                valid_arr[pending_idx] <= 1'b1;
                tag_arr[pending_idx]   <= pending_tag;
                data_arr[pending_idx]  <= mem_resp_rdata;
                if (!pending_is_pf) begin
                    resp_valid <= 1'b1;
                    resp_data  <= mem_resp_rdata;
                    pf_filled[pending_idx] <= 1'b0;
                end else begin
                    pf_filled[pending_idx] <= 1'b1;
                end
                state <= S_IDLE;
            end
        end
        endcase
    end
end

endmodule
