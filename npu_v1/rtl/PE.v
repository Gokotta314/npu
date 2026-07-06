module PE#(parameter size_bf16)(
	// interface to system
    input wire CLK,                         // CLK = 200MHz
    input wire RESET,                       // RESET, Negedge is active
    input wire EN,                          // enable signal for the accelerator, high for active
    input wire SELECTOR,                          // weight select read or use
    input wire W_EN,                         // enable weight to flow
    // interface to PE row .....
    input wire [size_bf16-1:0]active_left,
    output reg [size_bf16-1:0]active_right,

    input wire [size_bf16-1:0]in_sum,
    output reg [size_bf16-1:0]out_sum,

    input wire [size_bf16-1:0]in_weight_above,
    output wire [size_bf16-1:0]out_weight_below
	);

    reg [size_bf16-1:0] weight_1; 
    reg [size_bf16-1:0] weight_2;
    wire [size_bf16-1:0] weight;
    wire [size_bf16-1:0] pro_result;
    wire [size_bf16-1:0] sum_result;

    assign out_weight_below = (SELECTOR)?weight_1 :weight_2;
    assign weight = (SELECTOR)?weight_2 :weight_1;

    //bf16 multiplier
    bf16_mul bf16_mul(
        .iA(active_left),
        .iB(weight),
        .oProd(pro_result)
        );
    //bf16 adder
    bf16_add bf16_add(
        .iA(in_sum),
        .iB(pro_result),
        .oSum(sum_result)
        );

    // registers for systolic dataflow
    always @(negedge RESET or posedge CLK )begin
        if(~RESET) begin
            active_right <= 0;
            weight_1 <= 16'h0000;
            weight_2 <= 16'h0000;
        end
        else begin
            if (EN)begin

			 active_right <= active_left;
			 out_sum <= sum_result;

		       case({SELECTOR,W_EN})
		       2'b11:weight_1 <= in_weight_above;
		       2'b01:weight_2 <= in_weight_above;
		       default:;
                       endcase

            end
            else begin end
        end
    end



endmodule
