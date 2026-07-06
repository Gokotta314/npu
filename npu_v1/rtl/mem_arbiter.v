module mem_arbiter #(
    parameter N      = 2,
    parameter DW     = 64,
    parameter ADDR_W = 32
)(
    input  wire                CLK,
    input  wire                RESET,

    // ---- N个worker侧从端口----
    input  wire [N-1:0]        s_req_valid,
    output wire [N-1:0]        s_req_ready,
    input  wire [N-1:0]        s_req_wen,
    input  wire [N*ADDR_W-1:0] s_req_addr,
    input  wire [N*DW-1:0]     s_req_wdata,
    output wire [N-1:0]        s_resp_valid,
    output wire [N*DW-1:0]     s_resp_rdata,

    // ---- 共享内存侧主端口----
    output reg                 m_req_valid,
    input  wire                m_req_ready,
    output reg                 m_req_wen,
    output reg  [ADDR_W-1:0]   m_req_addr,
    output reg  [DW-1:0]       m_req_wdata,
    input  wire                m_resp_valid,
    input  wire [DW-1:0]       m_resp_rdata
);

localparam IDXW = (N <= 1) ? 1 : $clog2(N);

reg              busy;
reg [IDXW-1:0]   owner;
reg [IDXW-1:0]   rr_ptr;

// ---------------- 组合逻辑：从rr_ptr开始轮询，找第一个在请求的worker ----------------
integer k;
reg [31:0] idx_try;
reg [31:0] grant_idx_int;
reg        grant_valid;
always @(*) begin
    grant_valid   = 1'b0;
    grant_idx_int = 32'd0;
    for (k = 0; k < N; k = k + 1) begin
        idx_try = (rr_ptr + k) % N;
        if (!grant_valid && s_req_valid[idx_try]) begin
            grant_idx_int = idx_try;
            grant_valid   = 1'b1;
        end
    end
end
wire [IDXW-1:0] grant_idx = grant_idx_int[IDXW-1:0];

assign s_req_ready = (!busy && grant_valid) ? ({{(N-1){1'b0}}, 1'b1} << grant_idx) : {N{1'b0}};

genvar gi;
generate
    for (gi = 0; gi < N; gi = gi + 1) begin : RESP_ROUTE
        assign s_resp_valid[gi]              = busy && (owner == gi[IDXW-1:0]) && m_resp_valid;
        assign s_resp_rdata[gi*DW +: DW]      = m_resp_rdata;
    end
endgenerate

always @(posedge CLK or negedge RESET) begin
    if (~RESET) begin
        busy        <= 1'b0;
        owner       <= {IDXW{1'b0}};
        rr_ptr      <= {IDXW{1'b0}};
        m_req_valid <= 1'b0;
        m_req_wen   <= 1'b0;
        m_req_addr  <= {ADDR_W{1'b0}};
        m_req_wdata <= {DW{1'b0}};
    end else begin
        if (!busy) begin
            if (grant_valid) begin
                busy        <= 1'b1;
                owner       <= grant_idx;
                m_req_valid <= 1'b1;
                m_req_wen   <= s_req_wen[grant_idx];
                m_req_addr  <= s_req_addr[grant_idx*ADDR_W +: ADDR_W];
                m_req_wdata <= s_req_wdata[grant_idx*DW +: DW];
                rr_ptr      <= (grant_idx + 1) % N;   // 下次从下一个开始找，保证公平轮询
            end
        end else begin
            if (m_req_valid && m_req_ready)
                m_req_valid <= 1'b0;
            if (m_resp_valid)
                busy <= 1'b0;
        end
    end
end

endmodule
