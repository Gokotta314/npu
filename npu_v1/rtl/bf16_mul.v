module bf16_mul (
    input      [15:0] iA,
    input      [15:0] iB,
    output     [15:0] oProd
);

    // Extract fields of A and B.
    wire        A_s;
    wire [7:0]  A_e;
    wire [7:0] A_f;
    wire        B_s;
    wire [7:0]  B_e;
    wire [7:0] B_f;
    assign A_s = iA[15];
    assign A_e = iA[14:7];
    assign A_f = {1'b1, iA[6:0]};
    assign B_s = iB[15];
    assign B_e = iB[14:7];
    assign B_f = {1'b1, iB[6:0]};

    // XOR sign bits to determine product sign.
    wire        oProd_s;
    assign oProd_s = A_s ^ B_s;

    // Multiply the fractions of A and B
    wire [15:0] pre_prod_frac;
    assign pre_prod_frac = A_f * B_f;

    // Add exponents of A and B
    wire [8:0]  pre_prod_exp;
    assign pre_prod_exp = A_e + B_e;

    // If top bit of product frac is 0, shift left one
    wire [8:0] pre_oProd_e;
    wire [6:0] oProd_f;
    wire [7:0] oProd_e;
    assign pre_oProd_e = (pre_prod_exp>9'd127) ? (pre_prod_exp-9'd127) : 9'b0;
    assign oProd_e = pre_prod_frac[15] ? (pre_oProd_e + 9'b1) : pre_oProd_e;
    assign oProd_f = pre_prod_frac[15] ? pre_prod_frac[14:8] : pre_prod_frac[13:7];

    //check nan and inf
    wire nan_result;//nan
    wire inf__result;
    assign nan_result = (iA==16'h7fc0) ? 1'b1 : 
                        (iB==16'h7fc0) ? 1'b1 :
                        (iA==16'h0000)&(iB==16'h7f80|iB==16'hff80) ? 1'b1 :
                        (iA==16'h7f80|iA==16'hff80)&(iB==16'h0000) ? 1'b1 : 1'b0;
    assign inf_result = (iA[14:0]==15'h7f80)|(iB[14:0]==15'h7f80)|(pre_oProd_e[8]);

    // Detect underflow
    wire        underflow;
    assign underflow = pre_prod_exp < 9'h80;

    // Detect zero conditions (either product frac doesn't start with 1, or underflow)
    assign oProd = nan_result       ? 16'h7fc0 :
                   (B_e == 8'd0)    ? 16'b0 :
                   (A_e == 8'd0)    ? 16'b0 :

                   inf_result       ? {oProd_s,15'h7f80} : 
                   underflow        ? 16'b0 :
                   {oProd_s, oProd_e, oProd_f};

endmodule
