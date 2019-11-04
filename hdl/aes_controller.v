`include "aes.vh"

module aes_controller #
(
	IN_FIFO_ADDR_WIDTH = 9,
	IN_FIFO_DATA_WIDTH = 128,
	OUT_FIFO_ADDR_WIDTH = 9,
	OUT_FIFO_DATA_WIDTH = 128
)
(
	input                                clk,
	input                                reset,

	input                                axis_slave_done,

	// aes control path
	input [`WORD_S-1:0]                  aes_cmd,

	// input FIFO
	input                                in_fifo_almost_full,
	input [IN_FIFO_DATA_WIDTH-1:0]       in_fifo_data,
	input                                in_fifo_empty,
	input                                in_fifo_full,
	input                                in_fifo_read_tvalid,
	output reg                           in_fifo_read_tready,

	// output FIFO
	input                                out_fifo_almost_full,
	input                                out_fifo_empty,
	input                                out_fifo_full,
	input                                out_fifo_write_tready,
	output reg                           out_fifo_write_tvalid,
	output reg [OUT_FIFO_DATA_WIDTH-1:0] out_fifo_data,

	output reg                           processing_done

);

`include "controller_fc.vh"

localparam [2:0] AES_GET_KEY_128  = 3'b010;
localparam [2:0] AES_GET_KEY_256  = 3'b001;
localparam [2:0] AES_GET_IV = 3'b011;
localparam [2:0] AES_START = 3'b101;
localparam [2:0] AES_WAIT = 3'b110;
localparam [2:0] AES_STORE_BLOCK = 3'b111;

reg [2:0]         state;

wire [`BLK_S-1:0] aes_out_blk;
wire              aes_done;

reg [`WORD_S-1:0] __aes_cmd;
reg [`KEY_S-1:0]  aes_key;
reg [`BLK_S-1:0]  aes_iv;

reg               aes_start;
wire              aes_cipher_mode;
wire              aes_decipher_mode;
wire              aes_key_exp_mode;

wire [`BLK_S-1:0] aes_ecb_in_blk;
wire [`BLK_S-1:0] aes_cbc_in_blk;
wire [`BLK_S-1:0] aes_in_blk;

wire              aes128_mode;
wire              aes256_mode;

wire out_fifo_write_req;
wire in_fifo_read_req;

reg [`BLK_S-1:0] aes_in_blk_reg;

genvar i;

assign aes_cipher_mode = is_encryption(__aes_cmd);
assign aes_start_cipher = aes_start && aes_cipher_mode;

assign aes_decipher_mode = is_decryption(__aes_cmd);
assign aes_start_decipher = aes_start && aes_decipher_mode;

assign aes_key_exp_mode = is_key_expansion(__aes_cmd);
assign aes_start_key_exp = aes_start && aes_key_exp_mode;

assign aes128_mode = is_128bit_key(aes_cmd);
assign aes256_mode = is_256bit_key(aes_cmd);

aes_top aes_mod(
	.clk(clk),
	.reset(reset),
	.en(aes_start),

	.aes128_mode(aes128_mode),
	.aes256_mode(aes256_mode),

	.cipher_mode(aes_cipher_mode),
	.decipher_mode(aes_decipher_mode),
	.key_exp_mode(aes_key_exp_mode),

	.aes_op_in_progress(aes_op_in_progress),

	.aes_key(aes_key),
	.aes_in_blk(aes_in_blk_reg),

	.aes_out_blk(aes_out_blk),
	.en_o(aes_done)
);

assign aes_in_blk = is_CBC_enc(aes_cmd) ?  aes_cbc_in_blk : aes_ecb_in_blk;
assign aes_ecb_in_blk = in_fifo_data;
assign aes_cbc_in_blk = aes_iv ^ aes_ecb_in_blk;

assign out_fifo_write_req = out_fifo_write_tready && out_fifo_write_tvalid;
assign in_fifo_read_req = in_fifo_read_tready && in_fifo_read_tvalid;

always @(posedge clk) begin
	if (reset == 1'b1) begin
		processing_done <= 1'b0;
		__aes_cmd <= {`WORD_S{1'b0}};
		aes_key <= {`KEY_S{1'b0}};
		aes_iv <= 1'b0;
		state <= AES_GET_KEY_128;

		aes_in_blk_reg <= 1'b0;
		in_fifo_read_tready <= 1'b0;
	end
	else begin
		in_fifo_read_tready <= 1'b0;
		aes_start <= 1'b0;

		case (state)
			AES_GET_KEY_128:
			begin
				__aes_cmd <= {`WORD_S{1'b0}};
				in_fifo_read_tready <= 1'b1;

				if (in_fifo_read_req) begin
					state <= AES_START;

					processing_done <= 1'b0;
					in_fifo_read_tready <= 1'b0;

					aes_key[`AES128_KEY_BITS-1 : 0] <= in_fifo_data;
					__aes_cmd <=
						set_key_expansion_bit(__aes_cmd) |
						(aes128_mode ? set_key_128_bit(__aes_cmd) :
						 aes256_mode ? set_key_256_bit(__aes_cmd) :
						 {`WORD_S{1'b0}});

					if (aes256_mode)
						state <= AES_GET_KEY_256;
					else begin
						aes_start <= 1'b1;
						if (is_CBC_op(aes_cmd))
						state <= AES_GET_IV;
					end
				end
			end
			AES_GET_KEY_256:
			begin
				in_fifo_read_tready <= 1'b1;

				if (in_fifo_read_req) begin
					aes_start <= 1'b1;
					state <= AES_START;
					aes_key[`AES256_KEY_BITS-1 : `AES128_KEY_BITS] <= in_fifo_data;
					if (is_CBC_op(aes_cmd))
						state <= AES_GET_IV;
				end
			end
			AES_GET_IV:
			begin
				in_fifo_read_tready <= 1'b1;

				if (in_fifo_read_req) begin
					in_fifo_read_tready <= 1'b0;
					aes_iv <= in_fifo_data;
					state <= AES_START;
				end
			end
			AES_START:
			begin
				state <= AES_START;

				if (!aes_op_in_progress)
					in_fifo_read_tready <= 1'b1;

				if (in_fifo_read_req) begin
					__aes_cmd <= aes_cmd;
					in_fifo_read_tready <= 1'b0;
					aes_in_blk_reg <= aes_in_blk;
					state <= AES_WAIT;
					aes_start <= 1'b1;
				end

				if (axis_slave_done && in_fifo_empty) begin
					processing_done <= 1'b1;
					state <= AES_GET_KEY_128;
				end
			end
			AES_WAIT:
			begin
				state <= AES_WAIT;

				if (aes_done == 1'b1) begin
					out_fifo_data <= aes_out_blk;
					state <= AES_STORE_BLOCK;

					if(is_CBC_enc(aes_cmd)) begin
						aes_iv <= aes_out_blk;
					end

					if(is_CBC_dec(aes_cmd)) begin
						out_fifo_data <= aes_iv ^ aes_out_blk;
						aes_iv <= aes_in_blk_reg;
					end

				end
			end
			AES_STORE_BLOCK:
			begin
				state <= AES_STORE_BLOCK;

				if (out_fifo_write_req) begin
					state <= AES_START;
				end
			end
			default:
				state <= AES_GET_KEY_128;
		endcase
	end
end

always @(posedge clk) begin
	if (reset)
		out_fifo_write_tvalid <= 1'b0;
	else begin
		if (aes_done && (aes_cipher_mode || aes_decipher_mode))
			out_fifo_write_tvalid <= 1'b1;

		if (out_fifo_write_req)
			out_fifo_write_tvalid <= 1'b0;
	end
end
endmodule
