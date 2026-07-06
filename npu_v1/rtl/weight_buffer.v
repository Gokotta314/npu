// weight buffer, ref: shared_buffer
module weight_buffer#(parameter num, parameter size_bf16)
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

reg [num*size_bf16-1:0] mem [num-1:0];
always @(posedge CLK)
begin
    if(~RESET)
    Q <= 0;
    else if(~WEN & RETN) begin
        Q <= 0;
        mem[A] <= D;
    end else if(~CEN & RETN) begin
        Q <= mem[A];
    end else begin
        Q <= 0;
    end
end

endmodule
