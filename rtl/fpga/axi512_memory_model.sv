// Module: axi512_memory_model
// Purpose: Small synthesizable-style AXI4 memory model for F2 adapter cocotb sims.
module axi512_memory_model #(
  parameter int MEM_BYTES = 1048576
)(
  input  logic clk,
  input  logic rst_n,

  input  logic [63:0]  s_axi_awaddr,
  input  logic [7:0]   s_axi_awlen,
  input  logic [2:0]   s_axi_awsize,
  input  logic [1:0]   s_axi_awburst,
  input  logic         s_axi_awvalid,
  output logic         s_axi_awready,

  input  logic [511:0] s_axi_wdata,
  input  logic [63:0]  s_axi_wstrb,
  input  logic         s_axi_wlast,
  input  logic         s_axi_wvalid,
  output logic         s_axi_wready,

  output logic [1:0]   s_axi_bresp,
  output logic         s_axi_bvalid,
  input  logic         s_axi_bready,

  input  logic [63:0]  s_axi_araddr,
  input  logic [7:0]   s_axi_arlen,
  input  logic [2:0]   s_axi_arsize,
  input  logic [1:0]   s_axi_arburst,
  input  logic         s_axi_arvalid,
  output logic         s_axi_arready,

  output logic [511:0] s_axi_rdata,
  output logic [1:0]   s_axi_rresp,
  output logic         s_axi_rvalid,
  output logic         s_axi_rlast,
  input  logic         s_axi_rready
);
  logic [7:0] mem [0:MEM_BYTES-1];
  logic [63:0] write_addr_q;
  logic write_addr_seen_q;

  assign s_axi_awready = !write_addr_seen_q;
  assign s_axi_wready = write_addr_seen_q && !s_axi_bvalid;
  assign s_axi_arready = !s_axi_rvalid;
  assign s_axi_bresp = 2'b00;
  assign s_axi_rresp = 2'b00;
  assign s_axi_rlast = 1'b1;

  integer i;
  int unsigned byte_index;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      write_addr_q <= 64'd0;
      write_addr_seen_q <= 1'b0;
      s_axi_bvalid <= 1'b0;
      s_axi_rvalid <= 1'b0;
      s_axi_rdata <= 512'd0;
    end else begin
      if (s_axi_bvalid && s_axi_bready) begin
        s_axi_bvalid <= 1'b0;
      end
      if (s_axi_rvalid && s_axi_rready) begin
        s_axi_rvalid <= 1'b0;
      end

      if (!write_addr_seen_q && s_axi_awvalid && s_axi_awready) begin
        write_addr_q <= s_axi_awaddr;
        write_addr_seen_q <= 1'b1;
      end

      if (write_addr_seen_q && s_axi_wvalid && s_axi_wready) begin
        for (i = 0; i < 64; i = i + 1) begin
          byte_index = int'(write_addr_q[31:0]) + i;
          if (s_axi_wstrb[i] && (byte_index < MEM_BYTES)) begin
            mem[byte_index] <= s_axi_wdata[i * 8 +: 8];
          end
        end
        write_addr_seen_q <= 1'b0;
        s_axi_bvalid <= 1'b1;
      end

      if (!s_axi_rvalid && s_axi_arvalid && s_axi_arready) begin
        for (i = 0; i < 64; i = i + 1) begin
          byte_index = int'(s_axi_araddr[31:0]) + i;
          if (byte_index < MEM_BYTES) begin
            s_axi_rdata[i * 8 +: 8] <= mem[byte_index];
          end else begin
            s_axi_rdata[i * 8 +: 8] <= 8'h00;
          end
        end
        s_axi_rvalid <= 1'b1;
      end
    end
  end
endmodule
