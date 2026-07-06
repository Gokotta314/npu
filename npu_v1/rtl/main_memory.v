module main_memory #(
    parameter num       = 4,           // 每个数据字里打包的通道数
    parameter size_bf16  = 16,          // 每通道位宽
    parameter ADDR_W     = 16,          // 地址位宽
    parameter DEPTH       = 65536,       // 主存深度
    parameter LATENCY     = 20
)(
    input  wire                          CLK,
    input  wire                          RESET,

    // ---------------- 请求通道（主设备发起） ----------------
    input  wire                          req_valid,
    output wire                          req_ready,  // 恒为1：每拍只进1个请求
    input  wire                          req_wen,    // 1 = 写, 0 = 读
    input  wire [ADDR_W-1:0]             req_addr,
    input  wire [num*size_bf16-1:0]      req_wdata,

    // ---------------- 响应通道 ----------------
    output reg                           resp_valid,
    output reg  [num*size_bf16-1:0]      resp_rdata  // 写请求的响应此位不使用（全0），
                                                       // 靠请求方自己按发出顺序对应是读是写
);

// 流水线寄存器
reg                      pipe_valid [0:LATENCY-1];
reg                      pipe_wen   [0:LATENCY-1];
reg [ADDR_W-1:0]         pipe_addr  [0:LATENCY-1];

// 存储阵列
reg [num*size_bf16-1:0]  mem [0:DEPTH-1];

assign req_ready = 1'b1;

integer i;
always @(posedge CLK or negedge RESET) begin
    if (~RESET) begin
        for (i = 0; i < LATENCY; i = i + 1) begin
            pipe_valid[i] <= 1'b0;
            pipe_wen[i]   <= 1'b0;
            pipe_addr[i]  <= {ADDR_W{1'b0}};
        end
        resp_valid <= 1'b0;
        resp_rdata <= {num*size_bf16{1'b0}};
    end
    else begin
        for (i = LATENCY-1; i > 0; i = i - 1) begin
            pipe_valid[i] <= pipe_valid[i-1];
            pipe_wen[i]   <= pipe_wen[i-1];
            pipe_addr[i]  <= pipe_addr[i-1];
        end

        pipe_valid[0] <= req_valid;
        pipe_wen[0]   <= req_wen;
        pipe_addr[0]  <= req_addr;

        if (req_valid && req_wen) begin
            mem[req_addr] <= req_wdata;
        end

        resp_valid <= pipe_valid[LATENCY-1];
        if (pipe_valid[LATENCY-1] && !pipe_wen[LATENCY-1])
            resp_rdata <= mem[pipe_addr[LATENCY-1]];
        else
            resp_rdata <= {num*size_bf16{1'b0}};
    end
end

endmodule
