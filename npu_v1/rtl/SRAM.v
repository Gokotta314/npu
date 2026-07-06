// SRAM (128kB)
module SRAM#(parameter num, parameter size_bf16)
(
    output reg  [num*size_bf16-1:0] Q,
    input  wire         CLK,
    input  wire         RESET,
    input  wire         CEN,    //chip enable
    input  wire         WEN,    //
    input  wire [15:0]  A,
    input  wire [num*size_bf16-1:0] D,      //read data
    input  wire         RETN    //
    );

reg [num*size_bf16-1:0] mem [1024:0];
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

