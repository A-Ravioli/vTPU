// Module: hbm_model_mmap
// Purpose: Simulation-only file-backed HBM for large model images.
// Reads come from +hbm_mmap=<path> on demand; writes are kept in a sparse overlay.
// This avoids allocating multi-GB SystemVerilog arrays for full-model inference sims.
module hbm_model_mmap #(
  parameter int HBM_BYTES = 1048576,
  parameter int DATA_W = 32,
  parameter int READ_LATENCY = vtpu_pkg::VTPU_HBM_READ_LATENCY,
  parameter int WRITE_LATENCY = vtpu_pkg::VTPU_HBM_WRITE_LATENCY,
  parameter int PRELOAD_BYTES = 1048576
)(
  input  logic clk,
  input  logic rst_n,

  input  vtpu_pkg::mem_req_t req,
  output vtpu_pkg::mem_resp_t resp,

  input  logic host_we,
  input  logic [31:0] host_addr,
  input  logic [31:0] host_wdata,
  input  logic [3:0] host_wstrb,
  output logic [31:0] host_rdata,

  output logic access_pulse,
  output logic stall_pulse
);
  localparam int WORD_BYTES = DATA_W / 8;

  vtpu_pkg::mem_resp_t resp_q;
  vtpu_pkg::mem_req_t req_q;
  logic busy_q;
  int unsigned cycles_left_q;
  int unsigned word_addr;
  int unsigned host_word_addr_c;
  int unsigned host_word_addr_q;
  logic [DATA_W-1:0] read_data;
  logic [DATA_W-1:0] overlay [int unsigned];

  string image_path;
  integer fd;
  integer c;
  integer seek_rc;
  integer byte_idx;
  integer preload_limit;
  logic [DATA_W-1:0] preload_word;

  initial begin
    fd = 0;
    if ($value$plusargs("hbm_mmap=%s", image_path) || $value$plusargs("hbm_image=%s", image_path)) begin
      fd = $fopen(image_path, "rb");
      if (fd == 0) begin
        $display("hbm_model_mmap: WARNING cannot open image '%s'", image_path);
      end else begin
        $display("hbm_model_mmap: file-backed HBM image '%s'", image_path);
        preload_limit = (PRELOAD_BYTES < HBM_BYTES) ? PRELOAD_BYTES : HBM_BYTES;
        byte_idx = 0;
        preload_word = '0;
        c = $fgetc(fd);
        while ((c != -1) && (byte_idx < preload_limit)) begin
          preload_word[(byte_idx % WORD_BYTES) * 8 +: 8] = c[7:0];
          if ((byte_idx % WORD_BYTES) == (WORD_BYTES - 1)) begin
            overlay[byte_idx / WORD_BYTES] = preload_word;
            preload_word = '0;
          end
          byte_idx = byte_idx + 1;
          c = $fgetc(fd);
        end
        if ((byte_idx % WORD_BYTES) != 0) begin
          overlay[byte_idx / WORD_BYTES] = preload_word;
        end
        $display("hbm_model_mmap: preloaded %0d bytes into sparse overlay", byte_idx);
      end
    end
  end

  assign resp = resp_q;
  assign stall_pulse = req.valid && !resp_q.ready;

  task automatic read_word(input int unsigned addr, output logic [DATA_W-1:0] data);
    begin
      data = '0;
      if (overlay.exists(addr / WORD_BYTES)) begin
        data = overlay[addr / WORD_BYTES];
      end else if (fd != 0) begin
        seek_rc = $fseek(fd, addr, 0);
        if (seek_rc == 0) begin
          for (int unsigned lane = 0; lane < WORD_BYTES; lane++) begin
            c = $fgetc(fd);
            if (c == -1) begin
              data[lane * 8 +: 8] = 8'h00;
            end else begin
              data[lane * 8 +: 8] = c[7:0];
            end
          end
        end
      end
    end
  endtask

  always_comb begin
    host_rdata = '0;
    host_word_addr_c = host_addr / WORD_BYTES;
    if ((host_addr[1:0] == 2'b00) && (host_addr < HBM_BYTES)) begin
      if (overlay.exists(host_word_addr_c)) begin
        host_rdata = overlay[host_word_addr_c];
      end
    end
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      resp_q <= '{ready: 1'b1, valid: 1'b0, rdata: '0, error: 1'b0, error_code: 8'h00};
      req_q <= '0;
      busy_q <= 1'b0;
      cycles_left_q <= 0;
      access_pulse <= 1'b0;
    end else begin
      resp_q.valid <= 1'b0;
      resp_q.ready <= !busy_q;
      access_pulse <= 1'b0;

      if (host_we) begin
        host_word_addr_q = host_addr / WORD_BYTES;
        if ((host_addr[1:0] == 2'b00) && (host_addr < HBM_BYTES)) begin
          if (overlay.exists(host_word_addr_q)) begin
            read_data = overlay[host_word_addr_q];
          end else begin
            read_word(host_addr, read_data);
          end
          if (host_wstrb[0]) read_data[7:0] = host_wdata[7:0];
          if (host_wstrb[1]) read_data[15:8] = host_wdata[15:8];
          if (host_wstrb[2]) read_data[23:16] = host_wdata[23:16];
          if (host_wstrb[3]) read_data[31:24] = host_wdata[31:24];
          overlay[host_word_addr_q] = read_data;
        end
      end

      if (!busy_q && req.valid) begin
        req_q <= req;
        busy_q <= 1'b1;
        cycles_left_q <= req.write ? WRITE_LATENCY : READ_LATENCY;
        resp_q.ready <= 1'b0;
        access_pulse <= 1'b1;
      end else if (busy_q) begin
        if (cycles_left_q == 0) begin
          busy_q <= 1'b0;
          resp_q.ready <= 1'b1;
          resp_q.valid <= 1'b1;
          resp_q.error <= 1'b0;
          resp_q.error_code <= vtpu_pkg::ERR_NONE;
          resp_q.rdata <= '0;
          word_addr = req_q.addr / WORD_BYTES;
          if (((req_q.addr % WORD_BYTES) != 0) || (req_q.addr >= HBM_BYTES)) begin
            resp_q.error <= 1'b1;
            resp_q.error_code <= vtpu_pkg::ERR_BAD_ADDR;
          end else if (req_q.write) begin
            if (overlay.exists(word_addr)) begin
              read_data = overlay[word_addr];
            end else begin
              read_word(req_q.addr, read_data);
            end
            if (req_q.wstrb[0]) read_data[7:0] = req_q.wdata[7:0];
            if (req_q.wstrb[1]) read_data[15:8] = req_q.wdata[15:8];
            if (req_q.wstrb[2]) read_data[23:16] = req_q.wdata[23:16];
            if (req_q.wstrb[3]) read_data[31:24] = req_q.wdata[31:24];
            overlay[word_addr] = read_data;
          end else begin
            read_word(req_q.addr, read_data);
            resp_q.rdata <= read_data;
          end
        end else begin
          cycles_left_q <= cycles_left_q - 1;
        end
      end
    end
  end
endmodule
