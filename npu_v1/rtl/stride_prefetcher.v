module stride_prefetcher #(
    parameter ADDR_W = 32
)(
    input  wire                  CLK,
    input  wire                  RESET,

    input  wire                  access_valid,
    input  wire [ADDR_W-1:0]     access_addr,

    output reg                   pf_req_valid,
    output reg  [ADDR_W-1:0]     pf_req_addr,
    input  wire                  pf_req_accept
);

reg [ADDR_W-1:0] last_addr;
reg [ADDR_W-1:0] last_stride;
reg [1:0]        conf;          // 0=INIT, 1=TRANSIENT, 2/3=STEADY
reg              seen_first;
reg [ADDR_W-1:0] new_stride; 

always @(posedge CLK or negedge RESET) begin
    if (~RESET) begin
        last_addr    <= {ADDR_W{1'b0}};
        last_stride  <= {ADDR_W{1'b0}};
        conf         <= 2'd0;
        seen_first   <= 1'b0;
        pf_req_valid <= 1'b0;
        pf_req_addr  <= {ADDR_W{1'b0}};
    end else begin
        // 预取请求被cache采纳后清掉，等下一次触发
        if (pf_req_valid && pf_req_accept)
            pf_req_valid <= 1'b0;

        if (access_valid) begin
            if (seen_first) begin
                new_stride = access_addr - last_addr;
                if (new_stride == last_stride && new_stride != {ADDR_W{1'b0}}) begin
                    if (conf != 2'd3) conf <= conf + 2'd1;
                end else begin
                    conf <= 2'd0;
                end
                last_stride <= new_stride;

                // 见过一次以上相同步长（conf>=1）就开始预测，不用等到最高置信度，
                if (conf >= 2'd1) begin
                    pf_req_valid <= 1'b1;
                    pf_req_addr  <= access_addr + new_stride;
                end
            end
            last_addr  <= access_addr;
            seen_first <= 1'b1;
        end
    end
end

endmodule
