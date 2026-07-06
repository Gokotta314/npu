module controller#(parameter num)(
    // interface to system
    input wire CLK,                         // CLK = 200MHz
    input wire RESET,                       // RESET, Negedge is active
    input wire EN,                          // enable signal for the accelerator, high for active
    input wire NMC_EN,				// enable computing
    // parameters giving by testbench (in real implementation should be given by instructions)
    // input wire [9:0] NIN,                   // input channel number
    // input wire [9:0] NOUT,                  // output channel number
    // input wire [15:0] ISIZE,                // input size (8bit for height, 8bit for width, 0 for height=1...)
    // input wire [5:0] IPADDING,              // input padding (3bit for height, 3bit for width, 0 for padding=0...)
    // input wire [7:0] WSIZE,                 // conv kernel size (4bit for height, 4bit for width, 0 for height=1...)
    // input wire [3:0] WSTRIDE,               // conv stride (2bit for height, 2bit for width, 0 for stride=1...)
    // input wire [5:0] OSHIFT,                // right shift bit of the data. 0 for shift=0...
    // input wire [12:0] IADDR,                // input address for shared SRAM
    // input wire [12:0] WADDR,                // weight address for shared SRAM
    // input wire [12:0] OADDR,                // output address for shared SRAM
    output reg [5:0] STATE,                // output state for the tb to check the runtime...
    
    // interface to PE array (control + data manipulation)
    output reg W_EN,
    output reg SELECTOR,
    // interface to buffers (control)
    input wire [15:0] IADDR,                // input address for shared SRAM
    input wire [15:0] WADDR,                // weight address for shared SRAM
    input wire [15:0] OADDR,                // output address for shared SRAM
    //share buffer
    output reg share_wen,
    output reg share_ren,
    output reg share_cen,
    output reg [15:0] share_addr,
    // input wire [127:0] input_data
    // weight buffer
    output reg weight_wen,
    output reg weight_ren,
    output reg weight_cen,
    output reg [15:0] weight_addr,
    // activate buffer
    output reg activate_wen,
    output reg activate_ren,
    output reg activate_cen,
    output reg [15:0] activate_addr,
    // output buffer
    output reg output_wen,
    output reg output_ren,
    output reg output_cen,
    output reg [15:0] output_addr
    );
parameter IDLE = 6'd0;      // idle state
parameter INPUTSW = 6'd1;
parameter INPUTSA = 6'd2;
parameter INPUTW = 6'd3;    // weight (tiled) input from shared buffer to weight buffer
parameter INPUTA = 6'd4;    // activation (tiled) input from shared buffer to input buffer
parameter CALCULATE = 6'd5;
parameter OUTPUT = 6'd6;
parameter OUTPUTSW = 6'd7;
parameter RETURN = 6'd8;
//parameter 
// reg [12:0] input_addr;
// reg [12:0] weight_addr;
// reg [12:0] output_addr;
// reg [12:0] count;
always @(posedge CLK or negedge RESET) begin
    if(~RESET) begin
        // reset
        STATE <= IDLE;
        W_EN <= 0;
        SELECTOR <=0;
        // interface to buffers (control)
        // input_addr <= 0;
        // output_addr <= 0;
        //share buffer
        share_wen <= 1;
        share_ren <= 0;
        share_cen <= 1;
        share_addr <= 0;
        // weight buffer
        weight_wen <= 1;
        weight_ren <= 0;
        weight_cen <= 1;
        weight_addr <= 0;
        // // activate buffer
        activate_wen <= 1;
        activate_ren <= 0;
        activate_cen <= 1;
        activate_addr <= 0;
        // output buffer
        output_wen <= 1;
        output_ren <= 0;
        output_cen <= 1;
        output_addr <= 0;
    end
    else begin
    case({EN,STATE})
    7'b0_xxxxxx:begin
        // reset
        STATE <= IDLE;
        W_EN <= 0;
        SELECTOR <=0;
        //share buffer
        share_wen <= 1;
        share_ren <= 0;
        share_cen <= 1;
        share_addr <= 0;
        // weight buffer
        weight_wen <= 1;
        weight_ren <= 0;
        weight_cen <= 1;
        weight_addr <= 0;
        // // activate buffer
        activate_wen <= 1;
        activate_ren <= 0;
        activate_cen <= 1;
        activate_addr <= 0;
        // output buffer
        output_wen <= 1;
        output_ren <= 0;
        output_cen <= 1;
        output_addr <= 0;
    end
    7'b1_000000:begin //IDLE
        share_wen <= 0;
        share_ren <= 1;
        share_cen <= 1;
        // input_addr <= IADDR;
        weight_addr <= 0;
        // output_addr <= OADDR;
        share_addr <= WADDR;
        if(NMC_EN)begin
            STATE <= INPUTSW;
        end
    end
    7'b1_000001:begin//INPUTSW
            //输入weight进入share buffer
            share_addr <= share_addr +1;
            if(share_addr >= num-1+WADDR)begin
                STATE <= INPUTSA;
                share_addr <= IADDR;
            end
        end
    7'b1_000010:begin//INPUTSA
            //输入activate进入share buffer
            share_addr <= share_addr +1;
            if(share_addr == num-1+IADDR)begin
                STATE <= INPUTW;
                // share change to read
                share_wen <= 1;
                share_ren <= 1;
                share_cen <= 0;
                share_addr <= WADDR;
                weight_addr <= num;
            end
        end
    7'b1_000011:begin//INPUTW
            //从share buffer到weight进入weight buffer
            weight_wen <= 0;
            weight_ren <= 1;
            weight_cen <= 1;
            share_addr <= share_addr +1;
            weight_addr <= weight_addr -1;
            if(share_addr == num+WADDR)begin
                STATE <= INPUTA;
                share_addr <= IADDR;
                weight_addr <= -1;
                activate_addr <= -1;
                //PE open
                SELECTOR = 1;
                W_EN = 1;
            end
        end
     7'b1_000100:begin//INPUTA
            //从share buffer到weight进入input activate buffer
            //as the same time, let the weight flow
            //weight change to read
            weight_wen <= 1;
            weight_ren <= 1;
            weight_cen <= 0;
            activate_wen <= 0;
            activate_ren <= 1;
            activate_cen <= 1;
            share_addr <= share_addr +1;
            activate_addr <= activate_addr +1;
            weight_addr <= weight_addr +1;
            if(share_addr == num+IADDR)begin
                STATE <= CALCULATE;
                //share buffer close
                share_wen <= 1;
                share_ren <= 0;
                share_cen <= 1;
                //weight buffer close
                weight_addr <= 0;
                // activate change to read
                activate_wen <= 1;
                activate_ren <= 1;
                activate_cen <= 0;
                activate_addr <= 0;
            end
        end
        7'b1_000101:begin//CALCULATE
            //weight load over
            W_EN <= 0;
            SELECTOR <= 0;
            //weight and activate
            activate_addr <= activate_addr +1;
            if(activate_addr == num-1)begin
                STATE <= OUTPUT;
                //OUTPUT BUFFER OPEN
                output_addr <= -1;
            end
        end
        7'b1_000110:begin//OUTPUT
            output_wen <= 0;
            output_ren <= 1;
            output_cen <= 1;
            activate_addr <= activate_addr +1;
            output_addr <= output_addr + 1;
            if(activate_addr == 2*num-2)begin;
                //activate change to close
                activate_wen <= 1;
                activate_ren <= 0;
                activate_cen <= 1;
		end
            if(output_addr == num*2-2)begin
                STATE <= OUTPUTSW;
                share_addr <= OADDR-1;
                output_addr <= 0;
                output_wen <= 1;
                output_ren <= 1;
                output_cen <= 0;
            end
        end
        7'b1_000111:begin//OUTPUTSW
            share_wen <= 0;
            share_ren <= 1;
            share_cen <= 1;
            share_addr <= share_addr +1;
            output_addr <= output_addr + 1;
            if(output_addr == num-1)begin
                STATE <= RETURN;
                output_addr <= 0;
                output_wen <= 1;
                output_ren <= 0;
                output_cen <= 1;
            end
        end
        7'b1_001000:begin//RETURN
            STATE <= IDLE;
        end
        default:STATE <= IDLE;
        endcase
    end
end

endmodule
