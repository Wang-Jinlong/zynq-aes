/*
 ** FIFO abstraction over single port BRAM module.
 *
 ** It uses TVALID / TREADY handshake for both the read and write ports and
 ** allows concurrent r/w.
 *
 ** A successful read takes place when both fifo_read_tvalid and
 ** fifo_read_tready are HIGH.
 *
 ** A successful write takes place when both fifo_write_tavlid and
 ** fifo_write_tready are HIGH.
 *
 * @fifo_wdata
 * @fifo_write_tvalid
 * @fifo_write_tready
 * @fifo_read_tready
 * @fifo_read_tvalid
 * @fifo_rdata
 * @fifo_almost_full
 * @fifo_full
 * @fifo_empty 
 */

module fifo #(
	parameter ADDR_WIDTH = 9,
	parameter DATA_WIDTH = 128,
	parameter DEPTH = 512
)(
	input clk,
	input reset,

	// Write port
	input [DATA_WIDTH-1:0] fifo_wdata,
	output fifo_write_tready,
	input fifo_write_tvalid,

	// Read port
	output [DATA_WIDTH-1:0] fifo_rdata,
	output reg fifo_read_tvalid,
	input fifo_read_tready,

	// Control signals
	output fifo_almost_full,
	output fifo_full,
	output fifo_empty
);

wire [ADDR_WIDTH-1:0] read_ptr_next;
wire [ADDR_WIDTH-1:0] write_ptr_next;
reg [ADDR_WIDTH-1:0] write_ptr;
reg [ADDR_WIDTH-1:0] read_ptr;

wire fifo_read_transaction;
wire concurrent_rw;

wire is_last_write;
wire is_last_read;

wire [DATA_WIDTH-1:0] bram_o_data;
wire [DATA_WIDTH-1:0] bram_i_data;
wire [ADDR_WIDTH-1:0] bram_addr;
wire bram_w_e;

reg fifo_has_data;
reg is_full;

reg read_transaction_delay;

block_ram #(
	.ADDR_WIDTH(ADDR_WIDTH),
	.DATA_WIDTH(DATA_WIDTH),
	.DEPTH(DEPTH)
) out_fifo(
	.clk(clk),

	.addr(bram_addr),
	.i_data(bram_i_data),
	.w_e(bram_w_e),

	.o_data(bram_o_data)
);

assign bram_addr = fifo_write_tready ? write_ptr : read_ptr;
assign bram_w_e = fifo_write_tready;
assign bram_i_data = fifo_wdata;
assign fifo_rdata = bram_o_data;

assign is_last_write = (write_ptr == DEPTH - 1);
assign is_last_read = (read_ptr == DEPTH - 1);

assign write_ptr_next = is_last_write ? {ADDR_WIDTH{1'b0}} : (write_ptr + 1'b1);
assign read_ptr_next = is_last_read ? {ADDR_WIDTH{1'b0}} : (read_ptr + 1'b1);


assign fifo_read_transaction = fifo_read_tvalid && fifo_read_tready;
assign fifo_write_tready = fifo_write_tvalid && !fifo_full;

assign fifo_almost_full = (write_ptr_next == read_ptr);
assign fifo_empty = ~fifo_has_data;
assign fifo_full = is_full;

assign concurrent_rw = (fifo_write_tready && fifo_read_transaction);

always @(posedge clk) begin
	if (reset) begin
		write_ptr <= {ADDR_WIDTH{1'b0}};
		read_ptr <= {ADDR_WIDTH{1'b0}};
		fifo_has_data <= 1'b0;
		is_full <= 1'b0;
	end else begin
		if (fifo_write_tready) begin
			write_ptr <= write_ptr_next;

			if (!fifo_has_data)
				fifo_has_data <= 1'b1;

			if (fifo_almost_full) begin
				is_full <= 1'b1;
			end
		end

		if (fifo_read_transaction) begin
			read_ptr <= read_ptr_next;

			if (is_full)
				is_full <= 1'b0;

			if (read_ptr_next == write_ptr && !concurrent_rw)
				fifo_has_data <= 1'b0;
		end
	end
end

always @(posedge clk) begin
	if (reset) begin
		fifo_read_tvalid <= 1'b0;
	end else begin
		if (!fifo_empty && !fifo_read_tvalid && !read_transaction_delay && !fifo_write_tready) begin 
			fifo_read_tvalid <= 1'b1;
		end

		if ((fifo_read_transaction) || fifo_write_tready) begin
			fifo_read_tvalid <= 1'b0;
		end
	end
end

always @(posedge clk) begin
	if (reset)
		read_transaction_delay <= 1'b0;
	else
		read_transaction_delay <= (fifo_read_transaction || fifo_write_tready);
end

`ifdef SIMULATION
always @(posedge clk) begin
	if (concurrent_rw) begin
		$display("Concurrent r/w access!");
	end

	if (fifo_write_tready) begin
		$display("Writing %H to address %H", fifo_wdata, write_ptr);
	end

	if (fifo_read_transaction) begin
		$display("Reading %H from address %H", out_fifo.sram[read_ptr], read_ptr);
	end
end
`endif

endmodule
