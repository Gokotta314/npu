module bf16_add (
    input      [15:0] iA,
    input      [15:0] iB,
    output     [15:0] oSum
);

    wire        A_s;
    wire [7:0]  A_e;
    wire [7:0]  A_f;
    wire        B_s;
    wire [7:0]  B_e;
    wire [7:0]  B_f;
    assign A_s = iA[15];
    assign A_e = iA[14:7];
    assign A_f = {1'b1, iA[6:0]};
    assign B_s = iB[15];
    assign B_e = iB[14:7];
    assign B_f = {1'b1, iB[6:0]};
    wire A_larger;

    //check nan and inf
    wire nan_result;//nan
    wire inf_p_result;//inf
    wire inf_n_result;//-inf
    assign nan_result = (iA==16'h7fc0) ? 1'b1 : 
                        (iB==16'h7fc0) ? 1'b1 :
                        (iA==16'h7f80)&(iB==16'hff80) ? 1'b1 :
                        (iA==16'hff80)&(iB==16'h7f80) ? 1'b1 : 1'b0;
    assign inf_p_result = (iA==16'h7f80)|(iB==16'h7f80);
    assign inf_n_result = (iA==16'hff80)|(iB==16'hff80);

    // Shift fractions of A and B so that they align.
    wire [7:0]  exp_diff_A;
    wire [7:0]  exp_diff_B;
    wire [7:0]  larger_exp;
    wire [23:0] A_f_shifted;
    wire [23:0] B_f_shifted;

    assign exp_diff_A = B_e - A_e; // if B bigger
    assign exp_diff_B = A_e - B_e; // if A bigger

    assign larger_exp = (B_e > A_e) ? B_e : A_e;

    // Determine which of A, B is larger
    assign A_larger =    (A_e > B_e)                   ? 1'b1  :
                         ((A_e == B_e) && (A_f > B_f)) ? 1'b1  :
                         1'b0;
    //align
    assign A_f_shifted = A_larger             ? {1'b0,  A_f, 15'b0} :
                         (exp_diff_A > 8'd23) ? 24'b0 :
                         ({1'b0, A_f, 15'b0} >> exp_diff_A);
    assign B_f_shifted = ~A_larger            ? {1'b0,  B_f, 15'b0} :
                         (exp_diff_B > 8'd23) ? 24'b0 :
                         ({1'b0, B_f, 15'b0} >> exp_diff_B);

    // Calculate sum or difference of shifted fractions.
    wire [23:0] pre_sum;
    assign pre_sum = ((A_s^B_s) &  A_larger) ? A_f_shifted - B_f_shifted :
                     ((A_s^B_s) & ~A_larger) ? B_f_shifted - A_f_shifted :
                     A_f_shifted + B_f_shifted;

    // buffer midway results
    wire         A_e_zero;
    wire         B_e_zero;
    wire     	oSum_s;

    assign A_e_zero = (A_e == 8'b0);
    assign B_e_zero = (B_e == 8'b0);
    assign oSum_s   = A_larger ? A_s : B_s;

    // Convert to positive fraction and a sign bit.
    wire [23:0] pre_frac;
    assign pre_frac = pre_sum;

    // Determine output fraction and exponent change with position of first 1.
    wire [6:0] oSum_f;
    wire [7:0] oSum_e;
    wire [7:0] shft_amt;
    assign shft_amt = pre_frac[23] ? 8'd0  : pre_frac[22] ? 8'd1  :
                      pre_frac[21] ? 8'd2  : pre_frac[20] ? 8'd3  :
                      pre_frac[19] ? 8'd4  : pre_frac[18] ? 8'd5  :
                      pre_frac[17] ? 8'd6  : pre_frac[16] ? 8'd7  :
                      pre_frac[15] ? 8'd8  : pre_frac[14] ? 8'd9  :
                      pre_frac[13] ? 8'd10 : pre_frac[12] ? 8'd11 :
                      pre_frac[11] ? 8'd12 : pre_frac[10] ? 8'd13 :
                      pre_frac[9]  ? 8'd14 : pre_frac[8]  ? 8'd15 :
                      pre_frac[7]  ? 8'd16 : pre_frac[6]  ? 8'd17 :
                      pre_frac[5]  ? 8'd18 : pre_frac[4]  ? 8'd19 :
                      pre_frac[3]  ? 8'd20 : pre_frac[2]  ? 8'd21 :
                      pre_frac[1]  ? 8'd22 : pre_frac[0]  ? 8'd23 :
                      8'd24; // no one bits => result zero

    wire [31:0] pre_frac_shft, uflow_shift;
    // the shift +1 is because high order bit is not stored, but implied
    assign pre_frac_shft = {pre_frac, 8'b0} << (shft_amt+1); //? shft_amt+1
    assign uflow_shift = {pre_frac, 8'b0} << (shft_amt); //? shft_amt for overflow

    //rounding logic
    wire [31:0] pre_frac_rounded;
    wire round_bit = pre_frac_shft[24];  // 舍入位（第25位）
    wire sticky_bit = |pre_frac_shft[23:0]; // 粘滞位（低24位的或）   
    //round to the nearest integer
    wire do_round = round_bit & (sticky_bit | pre_frac_shft[25]);
    wire [7:0] pre_oSum_f;
    assign pre_oSum_f = pre_frac_shft[31:25]+(do_round ? 8'b1 : 8'd0);
    wire [7:0] pre_oSum_e;
    assign pre_oSum_e = larger_exp - shft_amt + 8'b1;
    // check mantissa overflow
    wire mantissa_overflow;
    assign mantissa_overflow = pre_oSum_f[7];

    assign oSum_e = mantissa_overflow ? pre_oSum_e + 8'b1 : pre_oSum_e;
    assign oSum_f = mantissa_overflow ? 7'b0 : pre_oSum_f[6:0];

    // Detect underflow and overflow
    wire underflow;
    wire overflow;
    assign underflow = ~uflow_shift[31]; 
    assign overflow = (oSum_e==8'hff)? 1'b1 : 1'b0;
	 
    assign oSum = nan_result ? 16'h7fc0 :
                  inf_p_result ? 16'h7f80 :
                  inf_n_result ? 16'hff80 :
                  (A_e_zero && B_e_zero)    ? 16'b0 :
                  A_e_zero                     ? iB :
                  B_e_zero                     ? iA :
                  underflow                        ? 16'b0 :
                  overflow                        ? {oSum_s,15'h7f80} :
                  (pre_frac == 0)                  ? 16'b0 :
                  {oSum_s, oSum_e, oSum_f};
endmodule
