`timescale 1ns / 1ps

module test_pe#(num=97, size_bf16=16)();

    reg reset;
    reg clk;

    reg EN;                          // enable signal for the accelerator; high for active
    reg SELECTOR;                    // weight select read or use
    reg W_EN;                         // enable weight to flow
    reg [size_bf16-1:0]active_left;
    reg [size_bf16-1:0]in_sum;
    reg [size_bf16-1:0]in_weight_above;
    wire [size_bf16-1:0]out_sum;
    wire [size_bf16-1:0]active_right;
    wire [size_bf16-1:0]out_weight_below;

    integer count=0;
    reg [size_bf16-1:0] data[2*num:0];
    integer output_file;

    PE #(.size_bf16(size_bf16)) PE(
        .CLK 		(clk),
        .RESET 		(reset),
        .EN			(EN),
        .SELECTOR		(SELECTOR),
        .W_EN		(W_EN),
        .active_left	(active_left),
        .active_right	(active_right),
        .in_sum		(in_sum),
        .out_sum		(out_sum),
        .in_weight_above	(in_weight_above),
        .out_weight_below(out_weight_below)
        );

    initial begin
        $readmemh("data/pe_test_vectors.txt", data);
	  output_file = $fopen("data/pe_test_results.txt", "w");
        clk <= 1;
        reset <= 0;
        #0.5
        reset <= 1;
        EN <= 1;
        SELECTOR <= 0;
        W_EN <= 1;
        in_weight_above <= 16'h3f80;
        #0.5
        SELECTOR <= 1;
        W_EN <= 0;
        in_weight_above <= 16'h3f80;
        for (count = 0; count< num; count = count+1'd1) begin
		#(0.5)
		active_left <= data[2*count];
		in_sum <= data[2*count+1];
		$fwrite(output_file,"%h\n",out_sum);
        end

        W_EN <= 1;
        in_sum<= 0;
        for (count = 0; count< num+1; count = count+1'd1) begin
		in_weight_above <= data[2*(count)+1];
		#(0.5)
            SELECTOR <= ~SELECTOR;
		active_left <= data[2*count];
		$fwrite(output_file,"%h\n",out_sum);
        end
        #100
	$finish;
    end

    always #0.25 clk = ~clk;

initial begin
	$fsdbDumpfile("tb.fsdb");	    
	$fsdbDumpvars;
	$fsdbDumpMDA();
end

endmodule
