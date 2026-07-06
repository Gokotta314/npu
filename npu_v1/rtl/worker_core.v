module worker_core #(
    parameter num      = 4,
    parameter size_bf16 = 16,
    parameter ADDR_W    = 32,
    parameter DW         = num*size_bf16,
    parameter NUM_LINES  = 64
)(
    input  wire                 CLK,
    input  wire                 RESET, 

    // ---------------- 来自dispatcher的任务接口----------------
    input  wire                 task_valid,
    output wire                 task_ready,
    input  wire [ADDR_W-1:0]    task_waddr,     // 权重在共享内存里的起始地址
    input  wire [ADDR_W-1:0]    task_iaddr,     // 激活值在共享内存里的起始地址
    input  wire [ADDR_W-1:0]    task_oaddr,     // 结果写回共享内存的起始地址
    output reg                  task_done,      // 单拍脉冲

    // ---------------- 简化AXI4-Lite风格主设备端口----------------
    output wire                 mem_req_valid,
    input  wire                 mem_req_ready,
    output wire                 mem_req_wen,
    output wire [ADDR_W-1:0]    mem_req_addr,
    output wire [DW-1:0]        mem_req_wdata,
    input  wire                 mem_resp_valid,
    input  wire [DW-1:0]        mem_resp_rdata,

    // ---------------- 统计----------------
    output wire [31:0]          hit_count,
    output wire [31:0]          miss_count,
    output wire [31:0]          prefetch_issued_count,
    output wire [31:0]          prefetch_useful_count
);

// ------------------------------------------------------------------
// 顶层任务FSM
// ------------------------------------------------------------------
localparam W_IDLE     = 4'd0;
localparam W_FW_ISSUE = 4'd1;
localparam W_FW_WAIT  = 4'd2;
localparam W_FA_ISSUE = 4'd3;
localparam W_FA_WAIT  = 4'd4;
localparam W_RUN      = 4'd5;
localparam W_WB_ISSUE = 4'd6;
localparam W_WB_WAIT  = 4'd7;
localparam W_DONE     = 4'd8;

reg [3:0] phase;
reg [7:0] fcnt;

reg [ADDR_W-1:0] waddr_r, iaddr_r, oaddr_r;

reg [DW-1:0] weight_stage [0:num-1];
reg [DW-1:0] act_stage    [0:num-1];
reg [DW-1:0] result_stage [0:num-1];

assign task_ready = (phase == W_IDLE);

// ------------------------------------------------------------------
// accelerator 
// ------------------------------------------------------------------
localparam WADDR_INT = 16'd0;          // 内部shared SRAM里权重tile的固定偏移
localparam IADDR_INT = num;             // 内部shared SRAM里激活值tile的固定偏移
localparam OADDR_INT = 2*num;           // 内部shared SRAM偏移
reg                      accel_en;
wire [5:0]                accel_state;
reg  [DW-1:0]             accel_input_data;
wire [DW-1:0]             accel_output_out;

accelerator #(.num(num), .size_bf16(size_bf16)) u_accel (
    .CLK(CLK), .RESET(RESET),
    .EN(accel_en), .NMC_EN(accel_en),
    .IADDR(IADDR_INT[15:0]), .WADDR(WADDR_INT[15:0]), .OADDR(OADDR_INT[15:0]),
    .STATE(accel_state),
    .input_data(accel_input_data),
    .output_out(accel_output_out)
);

localparam AC_IDLE=6'd0, AC_INPUTSW=6'd1, AC_INPUTSA=6'd2, AC_INPUTW=6'd3,
           AC_INPUTA=6'd4, AC_CALCULATE=6'd5, AC_OUTPUT=6'd6, AC_OUTPUTSW=6'd7, AC_RETURN=6'd8;

reg [5:0] accel_state_d;
always @(posedge CLK or negedge RESET) begin
    if (~RESET) accel_state_d <= AC_IDLE;
    else        accel_state_d <= accel_state;
end

wire enter_inputsw  = (accel_state==AC_INPUTSW)  && (accel_state_d!=AC_INPUTSW);
wire enter_inputsa  = (accel_state==AC_INPUTSA)  && (accel_state_d!=AC_INPUTSA);
wire enter_outputsw = (accel_state==AC_OUTPUTSW) && (accel_state_d!=AC_OUTPUTSW);
wire enter_return   = (accel_state==AC_RETURN)   && (accel_state_d!=AC_RETURN);

reg [7:0] local_cnt;
always @(posedge CLK or negedge RESET) begin
    if (~RESET) local_cnt <= 8'd0;
    else if (enter_inputsw || enter_inputsa || enter_outputsw) local_cnt <= 8'd1;
    else if (accel_state==AC_INPUTSW || accel_state==AC_INPUTSA || accel_state==AC_OUTPUTSW)
        local_cnt <= local_cnt + 8'd1;
end
wire [7:0] eff_cnt = (enter_inputsw || enter_inputsa || enter_outputsw) ? 8'd0 : local_cnt;

always @(*) begin
    case (accel_state)
        AC_INPUTSW: accel_input_data = weight_stage[eff_cnt];
        AC_INPUTSA: accel_input_data = act_stage[eff_cnt];
        default:    accel_input_data = {DW{1'b0}};
    endcase
end

integer ri;
always @(posedge CLK or negedge RESET) begin
    if (~RESET) begin
        for (ri = 0; ri < num; ri = ri + 1) result_stage[ri] <= {DW{1'b0}};
    end else if ((accel_state == AC_OUTPUTSW) && (eff_cnt != 8'd0)) begin
        result_stage[eff_cnt - 8'd1] <= accel_output_out;
    end else if (enter_return) begin
        result_stage[num-1] <= accel_output_out;
    end
end

// ------------------------------------------------------------------
// l1_cache（只服务读：取权重/激活值tile）
// ------------------------------------------------------------------
reg               l1_req_valid;
wire              l1_req_ready;
reg  [ADDR_W-1:0] l1_req_addr;
wire              l1_resp_valid;
wire [DW-1:0]     l1_resp_data;

wire              l1_mem_req_valid;
wire              l1_mem_req_wen;
wire [ADDR_W-1:0] l1_mem_req_addr;
wire [DW-1:0]     l1_mem_req_wdata;
wire              l1_mem_req_ready_muxed;
wire              l1_mem_resp_valid_muxed;

l1_cache #(.DW(DW), .ADDR_W(ADDR_W), .NUM_LINES(NUM_LINES)) u_l1cache (
    .CLK(CLK), .RESET(RESET),
    .req_valid(l1_req_valid), .req_ready(l1_req_ready),
    .req_addr(l1_req_addr),
    .resp_valid(l1_resp_valid), .resp_data(l1_resp_data),
    .mem_req_valid(l1_mem_req_valid), .mem_req_ready(l1_mem_req_ready_muxed),
    .mem_req_wen(l1_mem_req_wen), .mem_req_addr(l1_mem_req_addr), .mem_req_wdata(l1_mem_req_wdata),
    .mem_resp_valid(l1_mem_resp_valid_muxed), .mem_resp_rdata(mem_resp_rdata),
    .hit_count(hit_count), .miss_count(miss_count),
    .prefetch_issued_count(prefetch_issued_count), .prefetch_useful_count(prefetch_useful_count)
);

// ------------------------------------------------------------------
// 写回（直接发请求，不经过cache）
// ------------------------------------------------------------------
reg               wb_req_valid_r;
reg  [ADDR_W-1:0] wb_req_addr_r;
reg  [DW-1:0]     wb_req_wdata_r;

// ------------------------------------------------------------------
// 出口端口复用：取数阶段用l1_cache的后端端口，写回阶段用wb直连端口
// ------------------------------------------------------------------
wire use_cache_port = (phase==W_FW_ISSUE)||(phase==W_FW_WAIT)||(phase==W_FA_ISSUE)||(phase==W_FA_WAIT);
wire use_wb_port    = (phase==W_WB_ISSUE)||(phase==W_WB_WAIT);

assign mem_req_valid = use_cache_port ? l1_mem_req_valid : (use_wb_port ? wb_req_valid_r : 1'b0);
assign mem_req_wen   = use_cache_port ? 1'b0             : (use_wb_port ? 1'b1           : 1'b0);
assign mem_req_addr  = use_cache_port ? l1_mem_req_addr  : (use_wb_port ? wb_req_addr_r   : {ADDR_W{1'b0}});
assign mem_req_wdata = use_cache_port ? l1_mem_req_wdata : (use_wb_port ? wb_req_wdata_r  : {DW{1'b0}});

assign l1_mem_req_ready_muxed  = use_cache_port ? mem_req_ready  : 1'b0;
assign l1_mem_resp_valid_muxed = use_cache_port ? mem_resp_valid : 1'b0;
wire   wb_resp_valid           = use_wb_port    ? mem_resp_valid : 1'b0;
wire   wb_req_ready             = use_wb_port    ? mem_req_ready  : 1'b0;

// ------------------------------------------------------------------
// 主FSM
// ------------------------------------------------------------------
always @(posedge CLK or negedge RESET) begin
    if (~RESET) begin
        phase          <= W_IDLE;
        fcnt           <= 8'd0;
        waddr_r        <= {ADDR_W{1'b0}};
        iaddr_r        <= {ADDR_W{1'b0}};
        oaddr_r        <= {ADDR_W{1'b0}};
        task_done      <= 1'b0;
        accel_en       <= 1'b0;
        l1_req_valid   <= 1'b0;
        l1_req_addr    <= {ADDR_W{1'b0}};
        wb_req_valid_r <= 1'b0;
        wb_req_addr_r  <= {ADDR_W{1'b0}};
        wb_req_wdata_r <= {DW{1'b0}};
    end else begin
        task_done <= 1'b0;

        case (phase)
        W_IDLE: begin
            if (task_valid) begin
                waddr_r <= task_waddr;
                iaddr_r <= task_iaddr;
                oaddr_r <= task_oaddr;
                fcnt    <= 8'd0;
                phase   <= W_FW_ISSUE;
            end
        end

        // ---- 取权重tile：num个字，地址waddr_r .. waddr_r+num-1 ----
        W_FW_ISSUE: begin
            l1_req_valid <= 1'b1;
            l1_req_addr  <= waddr_r + fcnt;
            if (l1_req_valid && l1_req_ready) begin
                l1_req_valid <= 1'b0;
                phase        <= W_FW_WAIT;
            end
        end
        W_FW_WAIT: begin
            if (l1_resp_valid) begin
                weight_stage[fcnt] <= l1_resp_data;
                if (fcnt == num-1) begin
                    fcnt  <= 8'd0;
                    phase <= W_FA_ISSUE;
                end else begin
                    fcnt  <= fcnt + 8'd1;
                    phase <= W_FW_ISSUE;
                end
            end
        end

        // ---- 取激活值tile：num个字，地址iaddr_r .. iaddr_r+num-1 ----
        W_FA_ISSUE: begin
            l1_req_valid <= 1'b1;
            l1_req_addr  <= iaddr_r + fcnt;
            if (l1_req_valid && l1_req_ready) begin
                l1_req_valid <= 1'b0;
                phase        <= W_FA_WAIT;
            end
        end
        W_FA_WAIT: begin
            if (l1_resp_valid) begin
                act_stage[fcnt] <= l1_resp_data;
                if (fcnt == num-1) begin
                    fcnt     <= 8'd0;
                    accel_en <= 1'b1;      // staging buffer已备齐，启动accelerator
                    phase    <= W_RUN;
                end else begin
                    fcnt  <= fcnt + 8'd1;
                    phase <= W_FA_ISSUE;
                end
            end
        end

        // ---- 计算 ----
        W_RUN: begin
            if (enter_return) begin
                accel_en <= 1'b0;
                fcnt     <= 8'd0;
                phase    <= W_WB_ISSUE;
            end
        end

        // ---- 写回：num个字，地址oaddr_r .. oaddr_r+num-1 ----
        W_WB_ISSUE: begin
            wb_req_valid_r <= 1'b1;
            wb_req_addr_r  <= oaddr_r + fcnt;
            wb_req_wdata_r <= result_stage[fcnt];
            if (wb_req_valid_r && wb_req_ready) begin
                wb_req_valid_r <= 1'b0;
                phase          <= W_WB_WAIT;
            end
        end
        W_WB_WAIT: begin
            if (wb_resp_valid) begin
                if (fcnt == num-1) begin
                    phase <= W_DONE;
                end else begin
                    fcnt  <= fcnt + 8'd1;
                    phase <= W_WB_ISSUE;
                end
            end
        end

        W_DONE: begin
            task_done <= 1'b1;
            phase     <= W_IDLE;
        end

        default: phase <= W_IDLE;
        endcase
    end
end

endmodule
