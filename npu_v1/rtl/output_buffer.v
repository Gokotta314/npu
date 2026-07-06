// output buffer, ref: shared_buffer
module output_buffer#(parameter num, parameter size_bf16)
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
//reg [12:0] count;
reg [num*size_bf16-1:0] mem [num-1:0];
always @(posedge CLK)
begin
    if(~RESET)
    Q <= 0;
    else if(~WEN & RETN) begin
        Q <= 0;
        //mem[A] <= D;
        for (i=0;i<num;i = i+1)begin
            for(j = size_bf16*i; j < size_bf16*i+size_bf16; j = j+1)begin
                mem[A-i][j] <= D[j];
            end
        end
    end else if(~CEN & RETN) begin
        Q <= mem[A];
    end else begin
        Q <= 0;
    end
end

endmodule
