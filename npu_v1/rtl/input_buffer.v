// input buffer, ref: shifter_buffer
module input_buffer#(parameter num, parameter size_bf16)
(
    output reg  [num*size_bf16-1:0] Q,
    input  wire         CLK,
    input  wire         RESET, 
    input  wire         CEN,
    input  wire         WEN,
    input  wire [15:0]  A,
    input  wire [num*size_bf16-1:0] D,
    input  wire         RETN
    );
integer i;
integer j;
reg [num*size_bf16-1:0] mem [num*2-1:0];
always @(posedge CLK)
begin
    if(~RESET)begin
        Q <= 0;
        for (i = 0; i < num*2; i = i + 1)
				mem[i] <= 0;
	end
    else if(~WEN & RETN) begin
        Q <= 0;
        //mem[A] <= D;
        for (i=0;i<num;i = i+1)begin
            for(j = size_bf16*i;j<size_bf16*i+size_bf16;j = j+1)begin
                mem[i+A][j] <= D[j];
            end
        end
    end else if(~CEN & RETN) begin
        Q <= mem[A];
    end else begin
        Q <= 0;
    end
end

endmodule
