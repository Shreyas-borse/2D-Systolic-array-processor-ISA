module corelet 
(
	input clk,
	input reset,
    
    input seq_begin, 
    output reg seq_done,

// SRAM interface for Activations and Weights (ie AW) to FSM
    input 	logic 	[31:0] 	ACT_q, //from sram to lo
    output 	logic 	[6:0] 	ACT_addr,
    output 	logic 			ACT_cen,
    output 	logic 			ACT_wen,

    input  logic [31:0] W_q, //from sram to lo
    output logic [6:0] W_addr,
    output logic W_cen,
    output logic W_wen,

// SRAM interface for PMEM and output_final (ie OP) TO FSM
    input [127:0] OP_q,
    output [127:0] OP_d,
    output [8:0] OP_addr,
    output OP_cen,
    output OP_wen
);

parameter row = 8;
parameter col = 8;
parameter bw = 4;
parameter psum_bw = 16;


reg [31:0] l0_to_array;
reg l0_rd;
reg l0_wr;
reg l0_full;
reg l0_ready;

logic [31:0] AW_q;
logic AW_mode;
assign AW_q = AW_mode ? W_q : ACT_q ;

logic weight_reset;

l0 #( .bw(bw), .row(8)) u_l0_inst1 (
        .clk(clk),
        .in(AW_q),
        .out(l0_to_array),
        .rd(l0_rd),
        .wr(l0_wr),
        .o_full(l0_full),
        .reset(reset),
        .o_ready(l0_ready)
        );

logic [col*psum_bw -1 : 0] ofifo_in;
logic [col -1 : 0] array_valid_out;

logic [1:0] inst_w, inst_w_next; 
logic [bw-1:0] 			debug_array_weight [0:7][0:7];

mac_array #(.bw(bw), .psum_bw(psum_bw), .row(row), .col(col)) u_mac_array_inst1 
(
  .clk(clk),
  .reset(reset || weight_reset),
  .out_s(ofifo_in),
  .in_w(l0_to_array), // inst[1]:execute, inst[0]: kernel loading
  .inst_w(inst_w),
  .in_n(128'b0),
  .valid(array_valid_out),
  .debug_array_weight(debug_array_weight)  //connect to ofifo valid signal
);

// logic [psum_bw*col - 1: 0] pmem_in;
// logic [col-1 : 0] ofifo_wr;
logic ofifo_full;
logic ofifo_empty;
logic ofifo_valid;

reg [psum_bw*col -1 :0] OFIFO_out_temp;
reg [psum_bw*col -1 :0] sfu_out;

ofifo #(.col(col), .psum_bw(psum_bw), .bw(bw)) u_ofifo_inst1(
        .clk(clk),
        .in(ofifo_in),
        .out(OFIFO_out_temp),
        .rd(ofifo_valid),
        .wr(array_valid_out),
        .o_full(ofifo_full),
        .reset(reset),
        .o_ready(ofifo_ready),
        .o_valid(ofifo_valid)
);

logic signed	[15:0] 	SFU_in	[0:7];
always@* begin
	for(int i=0 ; i<8 ; i++)
		SFU_in[i]	=	$signed(OFIFO_out_temp[16*i +: 16]);
end

SFU u_SFU(
		.clk		(clk),
		.reset		(reset),
		.OFIFO_out	(SFU_in),
		.valid      (ofifo_valid)
	);


//typedef enum logic {IDLE, W_TO_L0, W_TO_ARRAY, A_TO_L0, A_TO_ARRAY, SFU_COMPUTE, OUT_SRAM_FILL } state_coding_t;
enum logic [2:0] {IDLE, W_SRAM_TO_L0, W_L0_TO_ARRAY, ACT_SRAM_TO_L0, ACT_L0_TO_ARRAY, SFU_COMPUTE, OUT_SRAM_FILL} present_state, next_state;

logic [7:0] count, count_next;
logic [3:0] kij_count, kij_count_next;
//logic [5:0] act_count, act_count_next;
logic     l0_wr_next;
logic     l0_rd_next;



// sequence complete from FSM to TB
always @(posedge clk or posedge reset) begin
    if(reset)
        seq_done <=0;
    else 
        seq_done <= (next_state == IDLE && OUT_SRAM_FILL);
    end

always @(posedge clk or posedge reset) begin
    if(reset) begin
        present_state   <= IDLE;
        count           <= 0;
        kij_count       <= 0;
        l0_wr           <= 0;
        l0_rd           <= 0;
        inst_w          <= 0;
    end
    else begin
        present_state   <= next_state        ;
        count           <= count_next        ;
        kij_count       <= kij_count_next    ;
        l0_wr           <= l0_wr_next        ;
        l0_rd           <= l0_rd_next        ;
        inst_w          <= inst_w_next       ;
    end
end

always_comb begin
    // input [31:0] W_q, //from sram to lo
    W_addr		= 	{kij_count,3'b0} + count;
    W_cen 		=	!l0_wr_next;
    W_wen		=	1'b1;
	ACT_addr	=	count;
    ACT_cen 	=	!l0_wr_next;
	ACT_wen		=	1'b1;
	AW_mode		=	(present_state==W_SRAM_TO_L0) || (present_state==W_L0_TO_ARRAY);
	// assign I_ADDR    = AW_ADDR_MUX;    //output  [6:0] 
    // assign I_CEN     = !write_next;    //output        
    // assign I_WEN     = 1'b1;           //output       
end


always@ * begin

    next_state      =   present_state  ;
    count_next      =   count          ;
    kij_count_next  =   kij_count      ;
    l0_wr_next      =   l0_wr          ;
    l0_rd_next      =   l0_rd          ;
    inst_w_next     =   inst_w         ;
    weight_reset    =   0;
    // AW_mode         =   1;

    case(present_state)
        IDLE:
            if(seq_begin) 
            begin
                next_state  =   W_SRAM_TO_L0;
                count_next  =   0;
                kij_count_next = 0;
            end

        W_SRAM_TO_L0:
            if (count > 7) 
            begin
                next_state = W_L0_TO_ARRAY;
                count_next = 0;
                l0_wr_next = 0;
            end
            else
            begin
                // AW_mode    = 1;
                next_state = present_state;
                count_next = count + 1;
                l0_wr_next = 1;
            end

        W_L0_TO_ARRAY:
            if(count > 23)
            begin
                next_state      = ACT_SRAM_TO_L0;
                count_next      = 0;
                inst_w_next     = 0;
                l0_rd_next      = 0;
            end
            else if(count > 7)
            begin
                next_state      = present_state;
                count_next      = count + 1;
                inst_w_next     = 0;
                l0_rd_next      = 0;
            end
            else
            begin
                next_state      = present_state;
                count_next      = count + 1;
                inst_w_next     = 1;
                l0_rd_next      = 1;
            end

        ACT_SRAM_TO_L0:     
            if(count> 35) 
            begin
                next_state      = ACT_L0_TO_ARRAY;
                count_next      = 0;
                l0_wr_next      = 0;
            end
            else 
            begin
                // AW_mode       = 0;
                next_state    = present_state;
                count_next    = count+1;
                l0_wr_next    = 1;
            end

        ACT_L0_TO_ARRAY:
            if(count> 57)
            begin   // +2 over computation for reset of the state
				next_state      = (kij_count == 8) ? SFU_COMPUTE : W_SRAM_TO_L0 ;
				count_next 	    =  0;
				weight_reset	=  0;
                kij_count_next  = kij_count== 8 ? 8 : kij_count + 1;
            end
            else if(count>56)
            begin     //Asserting reset to Mac_array for 1 cycle to clear the weights
				next_state 		= present_state;
				count_next 	= count + 1;
				weight_reset 		= 1;
            end
            else if(count>55)
            begin// 36 + 8 + 8 + 1 + 1 + buffer(2)
                next_state    = present_state;
                count_next    = count + 1;
                inst_w_next   = 0;
                l0_rd_next    = 0;
            end
            else if(count> 35)  
            begin
                next_state    = present_state;
                count_next    = count+1;
                inst_w_next   = 0;
                l0_rd_next    = 0;
            end
            else
            begin
                next_state      = present_state;
                count_next      = count + 1;
                inst_w_next     = 2;
                l0_rd_next      = 1;
            end

        SFU_COMPUTE:
            if(count>143) 
            begin
                next_state      = OUT_SRAM_FILL;
                count_next    = 0;
            end
            else begin
                next_state      = present_state;
                count         = count + 1;
            end

        OUT_SRAM_FILL:
            if(count>15) begin
                next_state      = IDLE;
                count_next      = 0;
            end
            else begin
                next_state = present_state;
                count = count + 1;
            end
    endcase
end
    


endmodule