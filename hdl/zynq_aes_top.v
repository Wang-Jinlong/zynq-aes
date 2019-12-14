`include "aes.vh"

module zynq_aes_top #
(
        /*
        * Master side parameters
        */
        // Width of master side bus
        parameter integer C_M_AXIS_TDATA_WIDTH = 32,

        /*
        * Slave side parameters
        */
        // Width of slave side bus
        parameter integer C_S_AXIS_TDATA_WIDTH = 32,

        /*
         * Max no. of 32-bit words of payload data,
         * that can be processed in one go.
         * 32 kB by default.
         * Must be a multiple of the AES block size (128 bits).
         */
        parameter integer DATA_FIFO_SIZE = 2048,

	parameter ECB_SUPPORT =  1,
	parameter CBC_SUPPORT =  1,
	parameter CTR_SUPPORT =  1,
	parameter CFB_SUPPORT =  1,
	parameter OFB_SUPPORT =  1,
	parameter PCBC_SUPPORT = 1
)(
        /*
        * Master side ports
        */

        input wire                                   m00_axis_aclk,
        input wire                                   m00_axis_aresetn,
        output wire                                  m00_axis_tvalid,
        output wire [C_M_AXIS_TDATA_WIDTH-1 : 0]     m00_axis_tdata,
        output wire [(C_M_AXIS_TDATA_WIDTH/8)-1 : 0] m00_axis_tstrb,
        output wire                                  m00_axis_tlast,
        input wire                                   m00_axis_tready,

        /*
        * Slave side ports
        */

        input wire                                   s00_axis_aclk,
        input wire                                   s00_axis_aresetn,
        output wire                                  s00_axis_tready,
        input wire [C_S_AXIS_TDATA_WIDTH-1 : 0]      s00_axis_tdata,
        input wire [(C_S_AXIS_TDATA_WIDTH/8)-1 : 0]  s00_axis_tstrb,
        input wire                                   s00_axis_tlast,
        input wire                                   s00_axis_tvalid
);

// returns ceiling of the log base 2 of the input
function integer clogb2 (input integer bit_depth);
        begin
                for(clogb2=0; bit_depth>0; clogb2=clogb2+1)
                        bit_depth = bit_depth >> 1;
        end
endfunction

/*
 * 32kB AES block + 2 x 128-bit slots for key and iv.
 */
localparam OUT_BRAM_DATA_WIDTH = `Nb * `WORD_S;
localparam OUT_BRAM_DEPTH = DATA_FIFO_SIZE + (`KEY_S + `IV_BITS) / OUT_BRAM_DATA_WIDTH;
localparam OUT_BRAM_ADDR_WIDTH = clogb2(OUT_BRAM_DEPTH);

localparam IN_BRAM_DATA_WIDTH = `Nb * `WORD_S;
localparam IN_BRAM_DEPTH = DATA_FIFO_SIZE + (`KEY_S + `IV_BITS) / IN_BRAM_DATA_WIDTH;
localparam IN_BRAM_ADDR_WIDTH = clogb2(IN_BRAM_DEPTH);



// AES controller signals
wire                            in_bus_data_wren;
wire [C_S_AXIS_TDATA_WIDTH-1:0] in_bus_data;
wire                            in_bus_tlast;

wire                            aes_controller_done;
wire                            aes_controller_start;
wire                            aes_controller_skip_key_expansion;
wire                            processing_done;

// output FIFO signals
wire [OUT_BRAM_DATA_WIDTH-1:0]  aes_controller_out_fifo_data;

wire out_fifo_almost_full;
wire out_fifo_full;
wire out_fifo_empty;
wire out_fifo_write_tready;
wire out_fifo_write_tvalid;

// =====================================================================
/*
* AXI streaming slave
*/
axi_stream_slave #(
	.C_S_AXIS_TDATA_WIDTH(C_S_AXIS_TDATA_WIDTH)
) axis_slave_controller (
	.clk(s00_axis_aclk),
	.resetn(s00_axis_aresetn),
	.tready(s00_axis_tready),
	.tvalid(s00_axis_tvalid),
	.tlast(s00_axis_tlast),
	.tdata(s00_axis_tdata),
	.tstrb(s00_axis_tstrb),

	.fifo_busy(controller_in_busy),

	.fifo_wren(in_bus_data_wren),
	.fifo_data(in_bus_data),

	.stream_tlast(in_bus_tlast)
);

// =====================================================================
/*
* AES controller
*/

aes_controller #(
	.IN_FIFO_ADDR_WIDTH(IN_BRAM_ADDR_WIDTH),
	.IN_FIFO_DATA_WIDTH(IN_BRAM_DATA_WIDTH),
	.OUT_FIFO_ADDR_WIDTH(OUT_BRAM_ADDR_WIDTH),
	.OUT_FIFO_DATA_WIDTH(OUT_BRAM_DATA_WIDTH),

	.ECB_SUPPORT(ECB_SUPPORT),
	.CBC_SUPPORT(CBC_SUPPORT),
	.CTR_SUPPORT(CTR_SUPPORT),
	.CFB_SUPPORT(CFB_SUPPORT),
	.OFB_SUPPORT(OFB_SUPPORT),
	.PCBC_SUPPORT(PCBC_SUPPORT)
) controller(
	.clk(s00_axis_aclk),
	.reset(!s00_axis_aresetn),

	.in_bus_data_wren(in_bus_data_wren),
	.in_bus_data(in_bus_data),
	.in_bus_tlast(in_bus_tlast),

	.controller_in_busy(controller_in_busy),

	.out_fifo_data(aes_controller_out_fifo_data),
	.out_fifo_write_tvalid(out_fifo_write_tvalid),
	.out_fifo_write_tready(out_fifo_write_tready),
	.out_fifo_full(out_fifo_full),
	.out_fifo_empty(out_fifo_empty),
	.out_fifo_almost_full(out_fifo_almost_full),

	.processing_done(processing_done)
);

// =====================================================================
/*
* AXI master
*/

aes_axi_stream_master #(
	.C_M_AXIS_TDATA_WIDTH(C_M_AXIS_TDATA_WIDTH),
	.FIFO_SIZE(OUT_BRAM_DEPTH),
	.FIFO_ADDR_WIDTH(OUT_BRAM_ADDR_WIDTH),
	.FIFO_DATA_WIDTH(OUT_BRAM_DATA_WIDTH)
) axi_stream_master_controller (
	.m00_axis_aclk(m00_axis_aclk),
	.m00_axis_aresetn(m00_axis_aresetn),
	.m00_axis_tvalid(m00_axis_tvalid),
	.m00_axis_tdata(m00_axis_tdata),
	.m00_axis_tstrb(m00_axis_tstrb),
	.m00_axis_tlast(m00_axis_tlast),
	.m00_axis_tready(m00_axis_tready),

	.processing_done(processing_done),

	.aes_controller_out_fifo_data(aes_controller_out_fifo_data),

	.out_fifo_write_tvalid(out_fifo_write_tvalid),
	.out_fifo_write_tready(out_fifo_write_tready),
	.out_fifo_full(out_fifo_full),
	.out_fifo_empty(out_fifo_empty),
	.out_fifo_almost_full(out_fifo_almost_full)
);

endmodule
