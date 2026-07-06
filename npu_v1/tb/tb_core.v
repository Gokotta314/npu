`timescale 1ns / 1ps

module test_controller#(num=4, size_bf16=16)();
    reg RESET = 1;
    reg CLK;
    reg EN;
    reg NMC_EN;
    wire [5:0] STATE;
    wire W_EN;
    wire SELECTOR;
    wire share_wen;
    wire share_ren;
    wire share_cen;
    reg [num*size_bf16-1:0] activate[15:0];
    reg [num*size_bf16-1:0] input_data;
    reg [15:0] IADDR = 0 ;               // input address for shared SRAM
    reg [15:0] WADDR = 16  ;              // weight address for shared SRAM
    reg [15:0] OADDR = 31 ;               // output address for shared SRAM
    wire [num*size_bf16-1:0] output_out;

    accelerator accelerator(
        .CLK(CLK),
        .RESET(RESET),
        .EN(EN),
        .NMC_EN(NMC_EN),
        .STATE(STATE),
        //.W_EN(W_EN),
        // .SELECTOR(SELECTOR),
        // .share_wen(share_wen),
        // .share_ren(share_ren),
        // .share_cen(share_cen),
        .IADDR(IADDR),
        .WADDR(WADDR),
        .OADDR(OADDR),
        .input_data(input_data),
        .output_out(output_out)
    );


    integer output_file;
    integer count;
    integer input_id;
    integer index;
    reg [size_bf16-1:0] data[2*num*num-1:0];
    reg [num*size_bf16-1:0] last_output;

    initial begin
        $readmemh("data/single_core_test_vectors.txt", data);

	  output_file = $fopen("data/single_core_test_results.txt", "w");
        last_output = {num*size_bf16{1'bx}};

        CLK <= 1;
        RESET <= 0;
        input_data <= 0;
          #1
        RESET <=1;
        EN <= 1;
        NMC_EN <= 1;
        for (input_id = 0; input_id < 2*num; input_id = input_id +1'd1) begin
                #(1)
            input_data <= pack_bf16_array(input_id);
        end

        #100
       EN <= 0;
	$finish;
    end

    always @(output_out) begin
        if (output_out !== last_output) begin
            $fwrite (output_file, "%h\n", output_out);
            last_output <= output_out;
        end
    end

    always #0.5 CLK = ~CLK;
    
initial begin
	$fsdbDumpfile("tb.fsdb");	    
	$fsdbDumpvars;
	$fsdbDumpMDA();
end


function [num*size_bf16-1:0] pack_bf16_array;
    input integer input_id;
    reg [num*size_bf16-1:0] result;
begin
    result = 0;
    for (index = 0; index < num; index = index + 1'd1) begin
        result = result + ( data[num*input_id + index]<<(size_bf16*index) );
    end
    pack_bf16_array = result;
end
endfunction



endmodule
