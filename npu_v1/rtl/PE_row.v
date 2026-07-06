module PE_row #(parameter num, parameter size_bf16)
	(
	// interface to system
    input wire CLK,                         // CLK = 200MHz
    input wire RESET,                       // RESET, Negedge is active
    input wire EN,                          // enable signal for the accelerator, high for active
	input wire W_EN,
	input wire SELECTOR,
	// interface to PE array .....
	input wire signed[size_bf16-1:0] active_left,
	input wire [num*size_bf16-1:0] in_weight_above,
	output wire [num*size_bf16-1:0]out_weight_below,

	input wire [num*size_bf16-1:0] in_sum,
	output wire [num*size_bf16-1:0]out_sum
	);

wire [num*size_bf16-1:0] active_right;
// generate of every PE
genvar gi;
generate
    for(gi = 0; gi < num; gi = gi + 1)   //16 PE
    begin:label
		if(gi == 0)begin: gen_first_pe
			PE #(.size_bf16(size_bf16))PE_unit(
			.CLK(CLK),
			.RESET(RESET),
			.EN(EN),
			.SELECTOR(SELECTOR),
			.W_EN(W_EN),
    		// .....
			.active_left(active_left),
			.active_right(active_right[size_bf16-1:0]),
			.in_sum(in_sum[size_bf16-1:0]),
			.out_sum(out_sum[size_bf16-1:0]),
			.in_weight_above(in_weight_above[size_bf16-1:0]),
			.out_weight_below(out_weight_below[size_bf16-1:0])
    		);
		end
		else begin: gen_other_pe
			PE #(.size_bf16(size_bf16)) PE_unit(
			.CLK(CLK),
			.RESET(RESET),
			.EN(EN),
			.SELECTOR(SELECTOR),
			.W_EN(W_EN),
    		// .....
			.active_left(active_right[gi*size_bf16-1:(gi-1)*size_bf16]),
			.active_right(active_right[(gi+1)*size_bf16-1:gi*size_bf16]),
			.in_sum(in_sum[(gi+1)*size_bf16-1:gi*size_bf16]),
			.out_sum(out_sum[(gi+1)*size_bf16-1:gi*size_bf16]),
			.in_weight_above(in_weight_above[(gi+1)*size_bf16-1:gi*size_bf16]),
			.out_weight_below(out_weight_below[(gi+1)*size_bf16-1:gi*size_bf16])
    		);
		end
	end
endgenerate

endmodule
